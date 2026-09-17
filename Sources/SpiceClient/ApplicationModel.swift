import AppKit
import SwiftUI
import Observation
import WebKit
import ConnectionCore
import SessionCore
import SwiftSpiceAdapter

@MainActor @Observable
final class ApplicationModel {
    var pending: ConnectionCandidate?
    var message: String?
    var portalURL: String { didSet { defaults.set(portalURL, forKey: "portalURL") } }
    var trashAfterConnection: Bool { didSet { defaults.set(trashAfterConnection, forKey: "trashAfterConnection") } }
    var sessions: [SessionController] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let filePicker = ConnectionFilePicker()
    @ObservationIgnored private let inbox = ConnectionInbox()
    @ObservationIgnored private var files: [UUID: ConnectionFile] = [:]
    @ObservationIgnored private var reads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var maintenance: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var openSession: (@MainActor (SessionController) -> Void)?
    @ObservationIgnored var openPortalWindow: (@MainActor (PortalController) -> Void)?
    @ObservationIgnored var onCandidate: (@MainActor () -> Void)?
    @ObservationIgnored private var portal: PortalController?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        portalURL = defaults.string(forKey: "portalURL") ?? ""
        trashAfterConnection = defaults.bool(forKey: "trashAfterConnection")
    }
    func chooseFile() {
        if let url = filePicker.choose() { receive(url) }
    }
    func receive(_ url: URL) {
        guard pending == nil, reads.isEmpty else { message = L.text("busy"); return }
        let identifier = UUID()
        reads[identifier] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try ConnectionFile.read(url) } }.value
            guard let self else { return }
            defer { reads.removeValue(forKey: identifier) }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let file): offer(file.plan, source: url.lastPathComponent, file: file)
            case .failure(let error): message = Self.errorMessage(error)
            }
        }
    }
    func offer(_ plan: ConnectionPlan, source: String, file: ConnectionFile? = nil) {
        do { _ = try SessionController.endpoint(plan) }
        catch { message = Self.errorMessage(error); return }
        let candidate = ConnectionCandidate(plan: plan, source: source)
        guard inbox.offer(candidate) else { message = L.text("busy"); return }
        if let file { files[candidate.id] = file }
        pending = candidate
        onCandidate?()
    }
    func confirm(_ id: UUID, clipboard: Bool) {
        guard let candidate = inbox.approve(id: id) else { return }
        let file = files.removeValue(forKey: id)
        pending = nil
        portal?.allowNextCandidate()
        let controller = SessionController(plan: candidate.plan)
        controller.shareClipboard = clipboard
        if trashAfterConnection, candidate.plan.deleteFileHint != false, let file {
            controller.onConnected = { [weak self] in
                self?.performMaintenance { [weak self] in
                    let result = await Task.detached(priority: .utility) { Result { try file.moveToTrash() } }.value
                    if case .failure(let error) = result {
                        self?.message = L.text("trashFailed")
                        if let recovery = error as? FileRecoveryRequired {
                            NSWorkspace.shared.activateFileViewerSelecting([recovery.url])
                        }
                    }
                }
            }
        }
        sessions.append(controller)
        openSession?(controller)
        controller.start()
    }
    func cancel(_ id: UUID) { inbox.cancel(id: id); files.removeValue(forKey: id); pending = nil; portal?.allowNextCandidate() }
    func openPortal() {
        guard let url = URL(string: portalURL), PortalOrigin(url) != nil else { message = L.text("portalFailed"); return }
        portal?.close()
        do {
            let controller = try PortalController(url: url, offer: { [weak self] plan, source in
                self?.offer(plan, source: source)
            }, report: { [weak self] message in self?.message = message })
            portal = controller; openPortalWindow?(controller)
        } catch { message = L.text("portalFailed") }
    }
    func clearPortalData() {
        portal?.close(); portal = nil
        performMaintenance { [self] in
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            message = L.text("cleared")
        }
    }
    private func performMaintenance(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        maintenance[id] = Task { [weak self] in
            await operation()
            self?.maintenance.removeValue(forKey: id)
        }
    }
    func waitForShutdown() async {
        for session in sessions { await session.waitForDisconnection() }
        for task in maintenance.values { await task.value }
    }
    func closeSession(_ controller: SessionController) {
        controller.disconnect()
        // Retain only while teardown runs; its immutable ticket leaves with it.
        Task { [weak self, controller] in
            await controller.waitForDisconnection()
            self?.sessions.removeAll { $0.id == controller.id }
        }
    }
    func stop() {
        portal?.close(); portal = nil
        reads.values.forEach { $0.cancel() }; reads.removeAll()
        if let pending { cancel(pending.id) }
        sessions.forEach { $0.disconnect() }
    }
    static func errorMessage(_ error: Error) -> String {
        switch error {
        case ConnectionError.invalidPort: L.text("invalidPort")
        case ConnectionError.tlsRequired: L.text("tlsRequired")
        case ConnectionError.invalidCertificate: L.text("certificate")
        case is ConnectionError: L.text("invalidFile")
        default: L.text("fileFailed")
        }
    }
}
