import AppKit
import SwiftUI
import Metal
import Synchronization
import SwiftSpiceAdapter

@main
enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") { print(AppInfo.versionLine); return }
        if CommandLine.arguments.contains("--resource-check") {
            do { try verifyResources(); print("Bundled Metal libraries loaded.") }
            catch { fputs("Bundled Metal library check failed.\n", stderr); exit(1) }
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
            if !files.isEmpty, let url = existing.bundleURL {
                let completion = Mutex<Int?>(nil)
                NSWorkspace.shared.open(files, withApplicationAt: url, configuration: .init()) { _, error in
                    completion.withLock { $0 = error == nil ? 0 : 1 }
                }
                let deadline = Date(timeIntervalSinceNow: 10)
                while completion.withLock({ $0 }) == nil && Date() < deadline {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                }
                guard completion.withLock({ $0 }) == 0 else {
                    fputs("Could not forward the connection file to the running application.\n", stderr)
                    exit(1)
                }
            }
            existing.activate(options: [])
            return
        }
        if CommandLine.arguments.contains("--smoke-test") { fputs("Smoke: initializing application\n", stderr) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    static func verifyResources() throws {
        guard let resources = Bundle.main.resourceURL, let device = MTLCreateSystemDefaultDevice() else { throw PortalError.invalidResponse }
        for name in ["SwiftSpice_SwiftSpice", "SwiftSpice_SpiceMetalCompositor"] {
            let bundle = resources.appendingPathComponent(name + ".bundle")
            let candidates = [bundle.appendingPathComponent("SpiceVideoCompositor.metallib"),
                              bundle.appendingPathComponent("Contents/Resources/SpiceVideoCompositor.metallib")]
            guard let library = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw PortalError.invalidResponse }
            _ = try device.makeLibrary(URL: library)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ApplicationModel()
    private var launcher: NSWindow?
    private var settings: NSWindow?
    private var portals: [NSWindow: PortalController] = [:]
    private var sessions: [NSWindow: SessionController] = [:]
    private var terminating = false
    var replyToTermination: @MainActor (NSApplication) -> Void = { $0.reply(toApplicationShouldTerminate: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu(target: self)
        model.openSession = { [weak self] controller in self?.showSession(controller) }
        model.openPortalWindow = { [weak self] portal in self?.showPortal(portal) }
        model.onCandidate = { [weak self] in self?.showLauncher() }
        showLauncher()
        for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("-") && path.lowercased().hasSuffix(".vv") {
            model.receive(URL(fileURLWithPath: path))
        }
        if CommandLine.arguments.contains("--smoke-test") {
            fputs("Smoke: launcher ready\n", stderr)
            // Deliver quit as an AppKit run-loop event, not from a dispatch/Swift
            // task which occupies the executor during AppKit's modal quit loop.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.6)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        showLauncher()
        for url in urls { model.receive(url) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showLauncher(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        if CommandLine.arguments.contains("--smoke-test") { fputs("Smoke: closing application\n", stderr) }
        terminating = true
        model.stop()
        Task {
            await model.waitForShutdown()
            if CommandLine.arguments.contains("--smoke-test") { fputs("Smoke: teardown complete\n", stderr) }
            replyToTermination(sender)
        }
        return .terminateLater
    }
    private func makeWindow<V: View>(_ title: String, content: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: .init(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        window.center(); return window
    }
    @objc func showLauncher() {
        if launcher == nil { launcher = makeWindow("Spice Client", content: LauncherView(model: model), size: .init(width: 520, height: 380)) }
        launcher?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func chooseFile() { showLauncher(); model.chooseFile() }
    @objc func showSettings() {
        if settings == nil { settings = makeWindow(L.text("settings"), content: SettingsView(model: model), size: .init(width: 550, height: 260)) }
        settings?.makeKeyAndOrderFront(nil)
    }
    @objc func secureAttention() { if let window = NSApp.keyWindow { sessions[window]?.secureAttention() } }
    @objc func releaseInput() {
        if let window = NSApp.keyWindow { releaseCapture(window); sessions[window]?.releaseInput() }
    }
    @objc func disconnect() { if let window = NSApp.keyWindow { sessions[window]?.disconnect() } }
    private func showSession(_ controller: SessionController) {
        let window = makeWindow(controller.plan.title ?? "Spice Client", content: SessionView(controller: controller), size: .init(width: 1024, height: 720))
        sessions[window] = controller
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        if controller.plan.fullscreen { window.toggleFullScreen(nil) }
    }
    private func showPortal(_ portal: PortalController) {
        for (window, old) in Array(portals) { old.close(); window.close() }
        let window = makeWindow("Ravada", content: PortalWebView(controller: portal), size: .init(width: 1100, height: 760))
        portals[window] = portal; window.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let session = sessions[window] { session.focus(true) }
        else { for session in sessions.values { session.focus(false) } }
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        releaseCapture(window); sessions[window]?.focus(false)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        releaseCapture(window)
        if let controller = sessions.removeValue(forKey: window) { model.closeSession(controller) }
        if let portal = portals.removeValue(forKey: window) { portal.close() }
    }
    private func releaseCapture(_ window: NSWindow) {
        let selector = NSSelectorFromString("releaseSpicePointerCapture:")
        var views = window.contentView.map { [$0] } ?? []
        while let view = views.popLast() {
            if view.responds(to: selector) { _ = NSApp.sendAction(selector, to: view, from: nil) }
            views.append(contentsOf: view.subviews)
        }
    }
    static func makeMenu(target: AnyObject?) -> NSMenu {
        let main = NSMenu()
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: name); item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ object: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = object; menu.addItem(item)
        }
        let app = submenu("Spice Client")
        add(app, L.text("about"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app, L.text("settings"), #selector(showSettings), ",", target)
        app.addItem(.separator()); add(app, L.text("quit"), #selector(NSApplication.terminate(_:)), "q")
        let file = submenu(L.text("menuFile"))
        add(file, L.text("open"), #selector(chooseFile), "o", target)
        add(file, L.text("close"), #selector(NSWindow.performClose(_:)), "w")
        let edit = submenu(L.text("menuEdit"))
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            add(edit, L.text(title), NSSelectorFromString(selector), key)
        }
        let session = submenu(L.text("menuSession"))
        add(session, L.text("cad"), #selector(secureAttention), "", target)
        add(session, L.text("release"), #selector(releaseInput), "", target)
        add(session, L.text("disconnect"), #selector(disconnect), "", target)
        add(session, L.text("fullscreen"), #selector(NSWindow.toggleFullScreen(_:)))
        let window = submenu(L.text("menuWindow"))
        add(window, "Spice Client", #selector(showLauncher), "", target)
        add(window, L.text("minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        return main
    }
}
