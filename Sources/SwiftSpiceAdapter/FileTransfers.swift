// SPDX-License-Identifier: MIT
import Foundation
import SessionCore
import SwiftSpice

/// Why a drop or a picker selection cannot become a transfer. Each case is a
/// message the operator can act on, not a diagnostic.
public enum FileTransferRefusal: String, Sendable, Equatable {
    case empty, connectionFile, notConnected, agentUnavailable, guestRefuses, noRegularFiles
}

public enum FileDropDecision: Sendable, Equatable {
    case send([URL])
    case refused(FileTransferRefusal)
}

/// The rule that decides what a drop on a session window means. It is pure, and
/// the drop handler, the menu command and the tests all go through it, so the
/// rule cannot differ between the surface and its test (ADR-0005 §1).
public enum FileDropPolicy {
    public static func decide(
        urls: [URL],
        phase: SessionLifecycle.Phase,
        agentAvailable: Bool,
        guestAcceptsFiles: Bool,
        isRegularFile: (URL) -> Bool
    ) -> FileDropDecision {
        guard !urls.isEmpty else { return .refused(.empty) }
        // A connection file carries a ticket. It is never sent to a guest, whatever
        // the session's state, and the whole drop is refused rather than filtered:
        // a partial send would leave the operator guessing which files went.
        guard !urls.contains(where: { $0.pathExtension.lowercased() == "vv" }) else {
            return .refused(.connectionFile)
        }
        guard phase == .connected else { return .refused(.notConnected) }
        guard agentAvailable else { return .refused(.agentUnavailable) }
        guard guestAcceptsFiles else { return .refused(.guestRefuses) }
        let regular = urls.filter(isRegularFile)
        guard !regular.isEmpty else { return .refused(.noRegularFiles) }
        return .send(regular)
    }

    /// The default predicate: a regular file, following the URL as given. The
    /// backend re-opens by path and applies its own check; see ADR-0005 §5.
    public static func isRegularFile(_ url: URL) -> Bool {
        url.isFileURL && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}

public struct FileTransferItem: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case queued, sending, completed, cancelled
        case failed(String)
        public var isFinished: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            case .queued, .sending: false
            }
        }
    }
    public let id = UUID()
    public let url: URL
    public let name: String
    public var totalBytes: UInt64 = 0
    public var sentBytes: UInt64 = 0
    public var state: State = .queued
    /// Assigned when the backend accepts the transfer; events arrive keyed by it,
    /// and some arrive before `sendFile` has returned it.
    public var remote: SpiceFileTransferID?
    public var lastChange: ContinuousClock.Instant = .now
}

/// One drop is one row: a count, aggregate progress, one cancel (ADR-0005 §3).
public struct FileTransferGroup: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var items: [FileTransferItem]
    public init(urls: [URL]) {
        items = urls.map { FileTransferItem(url: $0, name: $0.lastPathComponent) }
    }
    public var isFinished: Bool { items.allSatisfy { $0.state.isFinished } }
    public var completed: Int { items.filter { $0.state == .completed }.count }
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.totalBytes } }
    public var sentBytes: UInt64 { items.reduce(0) { $0 + $1.sentBytes } }
    public var failures: [FileTransferFailure] {
        items.compactMap { item in
            guard case let .failed(reason) = item.state else { return nil }
            return FileTransferFailure(name: item.name, reason: reason)
        }
    }
}

public struct FileTransferFailure: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let name: String
    public let reason: String
}
