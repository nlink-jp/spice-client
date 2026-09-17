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
    let tlsPort = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_TLS_PORT"] ?? ""
    let x509 = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_X509_DIR"] ?? ""

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
    func file(_ name: String) throws -> String { try String(contentsOfFile: x509 + "/" + name, encoding: .utf8) }
    /// A `.vv` that requires TLS: the parser prefers `tls-port`, and `ca` carries the
    /// PEM with escaped newlines, as virt-viewer writes it.
    func tlsPlan(ca: String, subject: String? = nil) throws -> ConnectionPlan {
        var text = "[virt-viewer]\ntype=spice\nhost=127.0.0.1\nport=\(port)\ntls-port=\(tlsPort)\npassword=\(ticket)\n"
        text += "ca=" + ca.replacingOccurrences(of: "\n", with: "\\n") + "\n"
        if let subject { text += "host-subject=\(subject)\n" }
        return try ConnectionPlan.parse(Data(text.utf8))
    }
    func refused(_ session: SessionController) async throws {
        try await eventually { session.lifecycle.phase == .closed }
        #expect(session.failure != nil)
        #expect(session.lifecycle.phase == .closed)
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

    @Test func connectsOverTLSWithTheFileCertificateAuthority() async throws {
        let plan = try tlsPlan(ca: try file("ca-cert.pem"))
        #expect(plan.usesTLS)
        let session = SessionController(plan: plan)
        session.start()
        try await connected(session)
        #expect(session.inputAvailable)
        try await closed(session)
        record("connectsOverTLSWithTheFileCertificateAuthority")
    }

    @Test func connectsOverTLSWhenTheHostSubjectMatches() async throws {
        let session = SessionController(plan: try tlsPlan(ca: try file("ca-cert.pem"), subject: try file("subject.txt")))
        session.start()
        try await connected(session)
        try await closed(session)
        record("connectsOverTLSWhenTheHostSubjectMatches")
    }

    @Test func rejectsADecoyAuthorityAndAWrongSubjectAndThePeerSurvives() async throws {
        let decoy = SessionController(plan: try tlsPlan(ca: try file("decoy-ca-cert.pem")))
        decoy.start()
        try await refused(decoy)
        let wrongSubject = SessionController(plan: try tlsPlan(ca: try file("ca-cert.pem"), subject: "O=nlink-jp,CN=someone-else"))
        wrongSubject.start()
        try await refused(wrongSubject)
        let accepted = SessionController(plan: try tlsPlan(ca: try file("ca-cert.pem")))
        accepted.start()
        try await connected(accepted)
        try await closed(accepted)
        record("rejectsADecoyAuthorityAndAWrongSubjectAndThePeerSurvives")
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
