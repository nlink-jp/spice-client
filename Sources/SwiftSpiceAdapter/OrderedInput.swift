// SPDX-License-Identifier: MIT
// Edge ordering and motion coalescing informed by Maspice; see NOTICE.md.
import SwiftSpice

@MainActor
public final class OrderedInput {
    private let send: @Sendable (SpiceClientInput) async throws -> Void
    private let failure: @MainActor () -> Void
    private var queue: [SpiceClientInput] = []
    private var head = 0
    private var task: Task<Void, Never>?
    private var keys: Set<UInt32> = []
    private var buttons: [SpiceMouseButton] = []
    private var stopped = false
    public private(set) var submitted = 0
    public private(set) var coalesced = 0
    public private(set) var sent = 0
    public var pending: Int { queue.count - head }

    public init(send: @escaping @Sendable (SpiceClientInput) async throws -> Void,
                failure: @escaping @MainActor () -> Void) {
        self.send = send; self.failure = failure
    }
    public func submit(_ input: SpiceClientInput) {
        guard !stopped else { return }
        submitted += 1
        switch input {
        case .keyDown(let code): keys.insert(code)
        case .keyUp(let code): keys.remove(code)
        case .mousePress(let button): if !buttons.contains(button) { buttons.append(button) }
        case .mouseRelease(let button): buttons.removeAll { $0 == button }
        default: break
        }
        if pending > 0, let last = queue.last {
            switch (last, input) {
            case let (.mouseMotion(x, y), .mouseMotion(dx, dy)):
                queue[queue.count - 1] = .mouseMotion(dx: Self.add(x, dx), dy: Self.add(y, dy))
                coalesced += 1; return
            case (.mousePosition, .mousePosition):
                queue[queue.count - 1] = input; coalesced += 1; return
            default: break
            }
        }
        // Never drop a key edge silently. End the stalled connection instead.
        guard pending < 4096 else { stop(); failure(); return }
        queue.append(input)
        guard task == nil else { return }
        task = Task { [weak self] in
            await Task.yield()
            await self?.drain()
        }
    }
    public func chord(_ codes: [UInt32]) {
        for code in codes { submit(.keyDown(scanCode: code)) }
        for code in codes.reversed() { submit(.keyUp(scanCode: code)) }
    }
    public func releaseAll() {
        let releasedButtons = buttons, releasedKeys = keys.sorted()
        for button in releasedButtons { submit(.mouseRelease(button)) }
        for key in releasedKeys { submit(.keyUp(scanCode: key)) }
    }
    /// Synchronous stop is deliberately separate from waiting for transport.
    /// The session owner closes transport before awaiting finish().
    public func stop() {
        stopped = true; task?.cancel()
        queue.removeAll(); head = 0; keys.removeAll(); buttons.removeAll()
    }
    public func finish() async { await task?.value }
    private func drain() async {
        defer { task = nil }
        while !stopped && !Task.isCancelled && head < queue.count {
            let input = queue[head]; head += 1
            do { try await send(input) }
            catch {
                if !stopped { stop(); failure() }
                return
            }
            guard !stopped else { return }
            sent += 1
            if head > 256 { queue.removeFirst(head); head = 0 }
        }
        if !stopped { queue.removeAll(keepingCapacity: true); head = 0 }
    }
    private static func add(_ a: Int32, _ b: Int32) -> Int32 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b >= 0 ? .max : .min) : value
    }
}
