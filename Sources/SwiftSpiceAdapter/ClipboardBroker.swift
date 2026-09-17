// SPDX-License-Identifier: MIT
import AppKit
import SwiftSpice

/// One host clipboard authority for all sessions. Gate checks and pasteboard
/// operations run in the same MainActor turn, so revocation cannot interleave.
@MainActor
public final class ClipboardBroker {
    public static let shared = ClipboardBroker()
    private struct Permission { var enabled = false; var generation: UInt64 = 0 }
    private var permissions: [UUID: Permission] = [:]
    private var focused: UUID?
    private var guestWrite: (count: Int, session: UUID)?
    private let read: @MainActor () -> SpicePasteboardSnapshot
    private let write: @MainActor (String) throws(SpiceClipboardError) -> SpicePasteboardSnapshot

    public init(
        read: @escaping @MainActor () -> SpicePasteboardSnapshot = { SpicePasteboardBridge.snapshot() },
        write: @escaping @MainActor (String) throws(SpiceClipboardError) -> SpicePasteboardSnapshot = { try SpicePasteboardBridge.write(text: $0) }
    ) { self.read = read; self.write = write }

    public func setEnabled(_ enabled: Bool, session: UUID) {
        var entry = permissions[session] ?? Permission()
        guard entry.enabled != enabled || permissions[session] == nil else { return }
        entry.enabled = enabled; entry.generation &+= 1
        permissions[session] = entry
    }
    public func setFocused(_ session: UUID?) {
        guard focused != session else { return }
        if let old = focused, var entry = permissions[old] {
            entry.generation &+= 1; permissions[old] = entry
        }
        focused = session
        if let session, var entry = permissions[session] {
            entry.generation &+= 1; permissions[session] = entry
        }
    }
    public func revoke(_ session: UUID) {
        // Keep the tombstone: an old access closure must never see a reused epoch.
        setEnabled(false, session: session)
        if focused == session { setFocused(nil) }
    }
    public func resignFocus(_ session: UUID) {
        if focused == session { setFocused(nil) }
    }
    public func access(for session: UUID) -> SpicePasteboardAccess {
        if permissions[session] == nil { permissions[session] = Permission() }
        return SpicePasteboardAccess(
            authorization: { [weak self] in self?.authorization(session) ?? .init(generation: 0, allowed: false) },
            snapshot: { [weak self] generation in
                guard let self, authorized(session, generation) else { return nil }
                let snapshot = read()
                if let origin = guestWrite, origin.count == snapshot.changeCount, origin.session != session { return nil }
                return snapshot
            },
            write: { [weak self] generation, text throws(SpiceClipboardError) in
                guard let self, authorized(session, generation) else { return nil }
                let result = try write(text)
                guestWrite = (result.changeCount, session)
                return result
            }
        )
    }
    private func authorization(_ session: UUID) -> SpicePasteboardAuthorization {
        let entry = permissions[session] ?? Permission()
        return .init(generation: entry.generation, allowed: entry.enabled && focused == session)
    }
    private func authorized(_ session: UUID, _ generation: UInt64) -> Bool {
        let state = authorization(session)
        return state.allowed && state.generation == generation
    }
}
