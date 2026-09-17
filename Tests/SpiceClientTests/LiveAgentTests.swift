import Foundation
import Testing
import ConnectionCore
import SwiftSpice
import SwiftSpiceAdapter
@testable import SpiceClient

/// Runs only under `make live-peer` with the agent guest (ADR-0003): a real
/// spice-vdagent behind Xorg, and this application's clipboard broker and resize
/// path driven through SessionController with an in-memory pasteboard. The
/// operator's NSPasteboard is never touched. The gate separately checks the guest
/// log for the tokens this suite records in its receipt.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_AGENT"] != nil))
@MainActor
struct LiveAgentTests {
    let port = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_PORT"] ?? ""
    let ticket = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_TICKET"] ?? ""

    /// The in-memory host pasteboard the broker reads and writes.
    @MainActor final class Pasteboard {
        private(set) var changeCount = 1
        private(set) var text: String?
        private(set) var guestWrites: [String] = []
        func set(_ value: String) { changeCount += 1; text = value }
        var broker: ClipboardBroker {
            ClipboardBroker(read: { [self] in .init(changeCount: changeCount, text: text) },
                            write: { [self] value throws(SpiceClipboardError) in
                                changeCount += 1; text = value; guestWrites.append(value)
                                return .init(changeCount: changeCount, text: value)
                            })
        }
    }
    func plan() throws -> ConnectionPlan {
        try ConnectionPlan.parse(Data("[virt-viewer]\ntype=spice\nhost=127.0.0.1\nport=\(port)\npassword=\(ticket)\n".utf8))
    }
    func eventually(_ predicate: @MainActor () -> Bool, seconds: Double) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(predicate())
    }
    /// Waits for the predicate and records how long it took, so the verification
    /// record carries measured latencies rather than assumed bounds.
    func measure(_ label: String, seconds: Double, _ predicate: @MainActor () -> Bool) async throws {
        let start = ContinuousClock.now
        try await eventually(predicate, seconds: seconds)
        record("latency \(label) \(start.duration(to: .now).components.seconds * 1000 + start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)")
    }
    /// Copies `text` and waits for the guest's answer, copying again when the first
    /// announcement is lost. Immediately after a session enables sharing, the guest's
    /// vdagent may still be negotiating for this connection and drop the grab; a
    /// second copy is what an operator would do, and it is delivered. Only the
    /// opening exchange uses this: the revocation cases below must land first time,
    /// because a retry there would create a new pasteboard change and prove nothing.
    func deliver(_ text: String, to board: Pasteboard, expecting answer: String, attempts: Int = 3) async throws {
        for attempt in 1...attempts {
            board.set(text)
            let deadline = ContinuousClock.now + .seconds(5)
            while !board.guestWrites.contains(answer) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if board.guestWrites.contains(answer) {
                record("attempts \(attempt)")
                return
            }
        }
        #expect(board.guestWrites.contains(answer))
    }

    func record(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_RECEIPT"] else { return }
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    static func token() -> String { UUID().uuidString.lowercased().prefix(8).description }
    static func hostText(_ token: String) -> String { "spice-client host clipboard " + token }
    static func guestText(_ token: String) -> String { "spice-client guest clipboard " + token }

    /// Connects and waits for the agent: resizingAvailable is the session's own
    /// signal that the guest agent is connected and negotiates monitors.
    func connectWithAgent(_ board: Pasteboard) async throws -> SessionController {
        let session = SessionController(plan: try plan(), broker: board.broker)
        session.start()
        try await eventually({ session.lifecycle.phase == .connected || session.failure != nil }, seconds: 30)
        #expect(session.failure == nil)
        try await eventually({ session.resizingAvailable }, seconds: 20)
        #expect(!session.agentUnavailable)
        return session
    }
    func closed(_ session: SessionController) async throws {
        session.disconnect()
        try await eventually({ session.lifecycle.phase == .closed }, seconds: 10)
    }

    @Test func clipboardFollowsSharingAndFocusInBothDirections() async throws {
        let board = Pasteboard()
        let session = try await connectWithAgent(board)
        session.setDiagnostics(true)
        session.shareClipboard = true
        session.focus(true)
        // Sharing on and focused: the guest sees the host text and answers.
        let a = Self.token()
        let openedAt = ContinuousClock.now
        try await deliver(Self.hostText(a), to: board, expecting: Self.guestText(a))
        record("latency host-to-guest-and-back \(openedAt.duration(to: .now).components.seconds * 1000 + openedAt.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)")
        record("delivered \(a)")
        // Sharing off revokes the authorization before the next host text exists, so
        // no poll can read it. Re-enabling offers the current pasteboard, as ADR-0001
        // intends, so a newer text replaces the withheld one in the same MainActor
        // turn that re-enables sharing: the withheld text is never announced at all.
        session.shareClipboard = false
        let b = Self.token()
        board.set(Self.hostText(b))
        let c = Self.token()
        board.set(Self.hostText(c))
        session.shareClipboard = true
        try await measure("resume-after-sharing-off", seconds: 10) { board.guestWrites.contains(Self.guestText(c)) }
        record("withheld \(b)")
        record("delivered \(c)")
        // Focus lost: sharing stays on but the window is not the focused one.
        session.focus(false)
        let d = Self.token()
        board.set(Self.hostText(d))
        let e = Self.token()
        board.set(Self.hostText(e))
        session.focus(true)
        try await measure("resume-after-focus-loss", seconds: 10) { board.guestWrites.contains(Self.guestText(e)) }
        record("withheld \(d)")
        record("delivered \(e)")
        #expect(!board.guestWrites.contains(Self.guestText(b)))
        #expect(!board.guestWrites.contains(Self.guestText(d)))
        for token in [a, b, c, d, e] { #expect(!session.summary.contains(token)) }
        #expect(!session.summary.contains(ticket))
        // R7: the guest holds the X selection with its last answer; closing must not wait on it.
        try await closed(session)
        record("clipboardFollowsSharingAndFocusInBothDirections")
    }

    @Test func resizeRequestReachesTheGuestTwiceOnOneAgentConnection() async throws {
        let board = Pasteboard()
        let session = try await connectWithAgent(board)
        // The client cannot observe the outcome here: with virtio-gpu, QEMU does not
        // republish the primary surface at the guest's new screen size (measured
        // 2026-09-18), and qemu-system-aarch64 offers no QXL device. The guest log is
        // the observation, and the gate walks it in order, so the mode the guest
        // booted with cannot satisfy the second request.
        session.resize(width: 1024, height: 768)
        record("mode 1024x768")
        // Space the two requests: SessionController debounces by 150 ms and the guest
        // applies modes from a 0.5 s poll. Too short fails the gate's ordered check
        // rather than passing it.
        try await Task.sleep(for: .seconds(5))
        // A second request on the same agent connection. Nothing acknowledges the
        // first under virtio-gpu, so before ADR-0004 the reply-gated sender latched
        // here and this mode never reached the guest.
        session.resize(width: 1280, height: 800)
        record("mode 1280x800")
        try await Task.sleep(for: .seconds(5))
        #expect(session.resizingAvailable)
        try await closed(session)
        record("resizeRequestReachesTheGuestTwiceOnOneAgentConnection")
    }
}
