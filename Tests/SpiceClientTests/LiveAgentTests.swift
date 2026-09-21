import CryptoKit
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

    static func counter(_ name: String, in summary: String) -> Int? {
        summary.split(separator: "\n").first { $0.hasPrefix(name + "=") }.flatMap { Int($0.dropFirst(name.count + 1)) }
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

    /// A file the operator dropped reaches the guest intact: the test records the
    /// name and digest, and the gate requires the guest to report the same bytes.
    @Test func sendsAFileTheGuestReceivesIntact() async throws {
        let board = Pasteboard()
        let session = try await connectWithAgent(board)
        session.setDiagnostics(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "spice-client-" + UUID().uuidString.prefix(8) + ".bin"
        let url = directory.appendingPathComponent(name)
        // Several chunks worth, so progress is a sequence rather than one event.
        let bytes = Data((0..<64_000).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        session.send([url])
        #expect(session.transferRefusal == nil)
        try await eventually({ session.transfers.first?.completed == 1 }, seconds: 60)
        #expect(session.transfers.first?.failures.isEmpty == true)
        try await eventually({ (Self.counter("files_sent", in: session.summary) ?? 0) >= 1 }, seconds: 10)
        #expect((Self.counter("bytes_sent", in: session.summary) ?? 0) == 64_000)
        // The summary carries counts, never the name or the path (ADR-0001 §6).
        #expect(!session.summary.contains(name))
        #expect(!session.summary.contains(directory.path))

        // A connection file is refused on a session window whatever its state.
        let ticket = directory.appendingPathComponent("console.vv")
        try Data("[virt-viewer]\n".utf8).write(to: ticket)
        session.send([ticket])
        #expect(session.transferRefusal == .connectionFile)

        record("file " + name + " " + digest)
        try await closed(session)
        record("sendsAFileTheGuestReceivesIntact")
    }

    /// Writes a file of `size` bytes whose content depends on `seed`, and returns
    /// its URL with the digest the gate compares against the guest's copy.
    func makeFile(_ size: Int, seed: Int, in directory: URL) throws -> (url: URL, digest: String) {
        let url = directory.appendingPathComponent("spice-client-" + UUID().uuidString.prefix(8) + ".bin")
        let bytes = Data((0..<size).map { UInt8(($0 &* 31 &+ seed) % 251) })
        try bytes.write(to: url)
        return (url, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// More files than the four slots: the ones waiting for a slot must wait, not be
    /// failed as "stalled" by a watchdog that counted their time in the queue.
    /// The stall timeout is shortened so the first four outlast it; each of them
    /// reports progress chunk by chunk, so none of them stalls.
    @Test func sendsMoreFilesThanSlotsAndNoneWaitingIsFailedAsStalled() async throws {
        let board = Pasteboard()
        let session = try await connectWithAgent(board)
        session.transferStallTimeout = .seconds(2)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (1...6).map { try makeFile(1_000_000, seed: $0, in: directory) }

        let start = ContinuousClock.now
        session.send(files.map(\.url))
        #expect(session.transferRefusal == nil)
        try await eventually({ session.transfers.first?.isFinished == true }, seconds: 300)
        let elapsed = start.duration(to: .now).components.seconds
        let group = try #require(session.transfers.first)
        record("latency six-files-6MB \(elapsed * 1000)")
        #expect(group.failures.isEmpty, "\(group.failures.map { $0.name + ": " + $0.reason })")
        #expect(group.completed == files.count)
        for file in files where group.completed == files.count {
            record("file " + file.url.lastPathComponent + " " + file.digest)
        }
        try await closed(session)
        record("sendsMoreFilesThanSlotsAndNoneWaitingIsFailedAsStalled")
    }

    /// Cancelling a transfer in flight must not strand the rest. The dependency
    /// keeps a cancelled job, and its slot, until the guest answers; before the fix
    /// the application freed the slot at once, the next start hit the dependency's
    /// limit, and every waiting file failed in turn.
    @Test func cancellingOneTransferLeavesTheQueueMoving() async throws {
        let board = Pasteboard()
        let session = try await connectWithAgent(board)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = try makeFile(8_000_000, seed: 99, in: directory)
        session.send([big.url])
        try await eventually({ (session.transfers.first?.sentBytes ?? 0) > 0 }, seconds: 60)
        let rest = try (1...5).map { try makeFile(200_000, seed: 10 + $0, in: directory) }
        session.send(rest.map(\.url))
        let cancelled = try #require(session.transfers.first)
        session.cancelTransfers(group: cancelled.id)

        try await eventually({ session.transfers.count == 2 && session.transfers[1].isFinished }, seconds: 300)
        let group = session.transfers[1]
        #expect(session.transfers[0].items.first?.state == .cancelled)
        #expect(group.failures.isEmpty, "\(group.failures.map { $0.name + ": " + $0.reason })")
        #expect(group.completed == rest.count)
        // Whether spice-vdagent answers a client's cancellation decides whether the
        // slot comes back before the connection ends. Recorded, not asserted.
        record("cancel-ack " + ((session.transfers[0].items.first?.holdsBackendSlot ?? true) ? "none" : "received"))
        for file in rest where group.completed == rest.count {
            record("file " + file.url.lastPathComponent + " " + file.digest)
        }
        try await closed(session)
        record("cancellingOneTransferLeavesTheQueueMoving")
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
