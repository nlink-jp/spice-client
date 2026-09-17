import Foundation
import Testing
import AppKit
import ConnectionCore
@testable import SpiceClient

@Test @MainActor func offeredFileCannotCreateSessionUntilApproved() throws {
    let model = ApplicationModel(defaults: UserDefaults(suiteName: "spice-client-test-" + UUID().uuidString)!)
    let plan = try ConnectionPlan.parse(Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5900".utf8))
    model.offer(plan, source: "Synthetic portal")
    #expect(model.sessions.isEmpty)
    let candidate = try #require(model.pending)
    model.cancel(candidate.id)
    model.confirm(candidate.id, clipboard: true)
    #expect(model.sessions.isEmpty)
}
@Test @MainActor func standardEditingAndCloseCommandsExist() {
    let menu = AppDelegate.makeMenu(target: nil)
    let items = menu.items.flatMap { $0.submenu?.items ?? [] }
    for (action, key) in [("paste:", "v"), ("copy:", "c"), ("selectAll:", "a"), ("performClose:", "w")] {
        #expect(items.contains { $0.action == NSSelectorFromString(action) && $0.keyEquivalent == key })
    }
}
@Test func languagesHaveDifferentCompleteMessages() {
    for key in L.strings.keys {
        #expect(!L.text(key, languages: ["en"]).isEmpty)
        #expect(!L.text(key, languages: ["ja"]).isEmpty)
        #expect(L.text(key, languages: ["ja"]) != key)
    }
}

@Test @MainActor func filePickerDoesNotDependOnAnotherAppsUTIRegistration() {
    let picker = ConnectionFilePicker()
    #expect(picker.panel(picker, shouldEnable: URL(fileURLWithPath: "/tmp/fixture.vv")))
    #expect(picker.panel(picker, shouldEnable: URL(fileURLWithPath: "/tmp/fixture.VV")))
    #expect(!picker.panel(picker, shouldEnable: URL(fileURLWithPath: "/tmp/fixture.txt")))
    #expect(picker.panel(picker, shouldEnable: FileManager.default.temporaryDirectory))
}

@Test @MainActor func quitWaitsForAsyncCleanupThenAllowsTermination() async throws {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    var completions = 0
    delegate.replyToTermination = { _ in completions += 1 }
    #expect(delegate.applicationShouldTerminate(app) == .terminateLater)
    #expect(delegate.applicationShouldTerminate(app) == .terminateLater)
    for _ in 0..<100 where completions == 0 { await Task.yield() }
    #expect(completions == 1)
}
