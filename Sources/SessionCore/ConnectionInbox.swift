// SPDX-License-Identifier: MIT
import Foundation
import ConnectionCore

public struct ConnectionCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let plan: ConnectionPlan
    public let source: String
    public init(plan: ConnectionPlan, source: String) {
        id = UUID(); self.plan = plan; self.source = source
    }
}

/// Native UI alone consumes this one-shot approval. Web callbacks can only offer.
@MainActor
public final class ConnectionInbox {
    public private(set) var pending: ConnectionCandidate?
    public init() {}
    @discardableResult
    public func offer(_ candidate: ConnectionCandidate) -> Bool {
        guard pending == nil else { return false }
        pending = candidate
        return true
    }
    public func approve(id: UUID) -> ConnectionCandidate? {
        guard pending?.id == id else { return nil }
        defer { pending = nil }
        return pending
    }
    public func cancel(id: UUID) {
        if pending?.id == id { pending = nil }
    }
}

public struct SessionLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, connecting, connected, stopping, closed }
    public private(set) var phase: Phase = .idle
    public private(set) var generation: UInt64 = 0
    public init() {}
    public mutating func start() -> UInt64? {
        guard phase == .idle else { return nil }
        generation &+= 1; phase = .connecting
        return generation
    }
    public mutating func connected(generation: UInt64) -> Bool {
        guard self.generation == generation, phase == .connecting else { return false }
        phase = .connected
        return true
    }
    public mutating func retry() -> UInt64? {
        guard phase == .connecting || phase == .connected else { return nil }
        generation &+= 1; phase = .connecting
        return generation
    }
    public mutating func stop() -> Bool {
        guard phase != .stopping, phase != .closed else { return false }
        generation &+= 1; phase = .stopping
        return true
    }
    public mutating func didStop() { if phase == .stopping { phase = .closed } }
}
