import Foundation
import Testing
import ConnectionCore
import SwiftSpice
import SwiftSpiceAdapter
@testable import SpiceClient

/// Runs only under `make live-peer` (ADR-0002): a real spice-server in QEMU under
/// Podman, a minimal Alpine guest, and this application's own connection path.
/// The gate separately requires the injected key in the guest log and this
/// suite's receipt, because a suite disabled by its environment skips silently.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_PORT"] != nil))
@MainActor
struct LivePeerTests {
    let port = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_PORT"] ?? ""
    let ticket = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_TICKET"] ?? ""

    /// Counts distinct frame revisions through a visible subscription, the way a
    /// window would; SessionController's `frames_presented` counts Metal draws
    /// and stays zero without a view.
    @MainActor final class FrameObserver {
        private(set) var frames = 0
        private var task: Task<Void, Never>?
        private let subscription: SpiceDesktopSubscription
        init(_ desktop: SpiceDesktopSource) {
            subscription = desktop.subscribe()
            subscription.setDemand(.visible)
            task = Task { [subscription] in
                var last: SpiceFrameRevision?
                for await snapshot in subscription.updates {
                    if let update = snapshot.frame, update.revision != last { last = update.revision; self.frames += 1 }
                }
            }
        }
        func stop() { subscription.cancel(); task?.cancel() }
    }

    func plan(password: String) throws -> ConnectionPlan {
        // Parsed in memory, as the loopback suite does; nothing is written to disk.
        try ConnectionPlan.parse(Data("[virt-viewer]\ntype=spice\nhost=127.0.0.1\nport=\(port)\npassword=\(password)\n".utf8))
    }
    func eventually(_ predicate: @MainActor () -> Bool, seconds: Double = 30) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(predicate())
    }
    static func counter(_ name: String, in summary: String) -> Int? {
        summary.split(separator: "\n").first { $0.hasPrefix(name + "=") }.flatMap { Int($0.dropFirst(name.count + 1)) }
    }
    func connected(_ session: SessionController) async throws {
        try await eventually { session.lifecycle.phase == .connected || session.failure != nil }
        #expect(session.failure == nil)
    }
    func closed(_ session: SessionController) async throws {
        session.disconnect()
        try await eventually({ session.lifecycle.phase == .closed }, seconds: 10)
        #expect(!session.inputAvailable)
    }
    func record(_ test: String) {
        guard let path = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_RECEIPT"] else { return }
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + test + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func connectsPresentsRealFramesDeliversInputAndReconnects() async throws {
        let first = SessionController(plan: try plan(password: ticket))
        first.start()
        try await connected(first)
        #expect(first.inputAvailable)
        let observer = FrameObserver(try #require(first.desktop))
        defer { observer.stop() }
        try await eventually { observer.frames > 0 }
        first.setDiagnostics(true)
        first.submit(.keyDown(scanCode: 0x1e))
        first.submit(.keyUp(scanCode: 0x1e))
        try await eventually { (Self.counter("input_sent", in: first.summary) ?? 0) >= 2 }
        #expect(!first.summary.contains(ticket))
        #expect(!first.summary.contains("127.0.0.1"))
        try await closed(first)
        let second = SessionController(plan: try plan(password: ticket))
        second.start()
        try await connected(second)
        try await closed(second)
        record("connectsPresentsRealFramesDeliversInputAndReconnects")
    }

    @Test func wrongTicketFailsAuthenticationAndThePeerSurvives() async throws {
        let rejected = SessionController(plan: try plan(password: "not-" + ticket))
        rejected.start()
        try await eventually { rejected.lifecycle.phase == .closed }
        #expect(rejected.failure == .authentication)
        let accepted = SessionController(plan: try plan(password: ticket))
        accepted.start()
        try await connected(accepted)
        try await closed(accepted)
        record("wrongTicketFailsAuthenticationAndThePeerSurvives")
    }
}
