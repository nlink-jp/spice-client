import Foundation
import Testing
import SwiftSpice
import SwiftSpiceAdapter
import SessionCore

private actor InputProbe {
    var inputs: [SpiceClientInput] = []
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    let blocks: Bool
    init(blocks: Bool = false) { self.blocks = blocks }
    func send(_ input: SpiceClientInput) async {
        inputs.append(input)
        if blocks { await withCheckedContinuation { continuation = $0; waiting = true } }
    }
    func closeTransport() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func coalescingPreservesKeyAndButtonEdges() async throws {
    let probe = InputProbe()
    var failed = false
    let input = OrderedInput(send: { await probe.send($0) }, failure: { failed = true })
    input.submit(.mouseMotion(dx: 1, dy: 2)); input.submit(.mouseMotion(dx: 3, dy: 4))
    input.chord([0x1d, 0x38, 0x153])
    input.submit(.keyDown(scanCode: 30)); input.releaseAll()
    await input.finish()
    let sent = await probe.inputs
    #expect(sent.count == 9)
    if case .mouseMotion(let x, let y) = sent.first { #expect(x == 4 && y == 6) }
    else { Issue.record("Motion not preserved") }
    let keys = sent.compactMap { event -> String? in
        switch event {
        case .keyDown(let code): "down\(code)"
        case .keyUp(let code): "up\(code)"
        default: nil
        }
    }
    #expect(keys == ["down29", "down56", "down339", "up339", "up56", "up29", "down30", "up30"])
    #expect(input.coalesced == 1 && !failed)
}

@Test @MainActor func stalledInputStopsBeforeTransportUnblocksAndBoundsQueue() async throws {
    let probe = InputProbe(blocks: true)
    var failures = 0
    let input = OrderedInput(send: { await probe.send($0) }, failure: { failures += 1 })
    input.submit(.keyDown(scanCode: 1))
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await probe.waiting) && ContinuousClock.now < deadline { await Task.yield() }
    #expect(await probe.waiting)
    for _ in 0..<4097 { input.submit(.keyUp(scanCode: 1)) }
    #expect(failures == 1 && input.pending == 0)
    // A transport operation which ignores cancellation is released by closure,
    // then the owner joins the ordered writer. No queued edge escapes the stop.
    await probe.closeTransport()
    await input.finish()
    #expect(await probe.inputs.count == 1)
}

@Test func retryInvalidatesOldCompletionAndCanStillBeStopped() throws {
    var lifecycle = SessionLifecycle()
    let started = lifecycle.start()
    let first = try #require(started)
    let initialCompletion = lifecycle.connected(generation: first)
    #expect(initialCompletion)
    let retried = lifecycle.retry()
    let second = try #require(retried)
    #expect(lifecycle.phase == .connecting && second != first)
    let staleCompletion = lifecycle.connected(generation: first)
    #expect(!staleCompletion)
    let completion = lifecycle.connected(generation: second)
    #expect(completion)
    let stopped = lifecycle.stop()
    #expect(stopped)
    let prohibited = lifecycle.retry()
    #expect(prohibited == nil)
}
