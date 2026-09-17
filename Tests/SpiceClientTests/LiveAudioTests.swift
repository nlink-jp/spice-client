import Foundation
import Testing
import ConnectionCore
import SwiftSpice
import SwiftSpiceAdapter
@testable import SpiceClient

/// Runs only in the live peer gate's audio phase (ADR-0002), against a peer that
/// has the playback device and takes exactly one connection: the playback channel
/// makes QEMU's spice server crash under repeated connect/disconnect, so the
/// churn-heavy suites use a peer without it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_AUDIO"] != nil))
@MainActor
struct LiveAudioTests {
    let port = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_PORT"] ?? ""
    let ticket = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_TICKET"] ?? ""

    func plan() throws -> ConnectionPlan {
        try ConnectionPlan.parse(Data("[virt-viewer]\ntype=spice\nhost=127.0.0.1\nport=\(port)\npassword=\(ticket)\n".utf8))
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
    }
    func record(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["SPICE_CLIENT_LIVE_PEER_RECEIPT"] else { return }
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Audio playback, end to end: the guest plays a silent PCM stream, so the path
    /// is exercised without the machine running the test making any sound. The sink's
    /// counters are incremented where packets are scheduled, not in a render callback,
    /// so they move without an output device.
    @Test func receivesAudioPlaybackFromTheGuest() async throws {
        let session = SessionController(plan: try plan())
        session.start()
        try await connected(session)
        #expect(!session.audioUnavailable)
        session.setDiagnostics(true)
        try await eventually({ (Self.counter("audio_packets", in: session.summary) ?? 0) > 0 }, seconds: 20)
        #expect((Self.counter("audio_frames", in: session.summary) ?? 0) > 0)
        try await closed(session)
        record("receivesAudioPlaybackFromTheGuest")
    }

}
