// Local spice-client patch: injectable host boundary; upstream defaults preserved.
import Foundation

public struct SpicePasteboardAuthorization: Sendable, Equatable {
    public let generation: UInt64
    public let allowed: Bool
    public init(generation: UInt64, allowed: Bool) {
        self.generation = generation; self.allowed = allowed
    }
}

/// The consumer owns permission on MainActor. Every actual access must validate
/// the supplied generation before touching the pasteboard. nil means denied,
/// not an empty clipboard. Calls already submitted to transport are in flight.
public struct SpicePasteboardAccess: Sendable {
    public let authorization: @MainActor @Sendable () -> SpicePasteboardAuthorization
    public let snapshot: @MainActor @Sendable (UInt64) -> SpicePasteboardSnapshot?
    public let write: @MainActor @Sendable (UInt64, String) throws(SpiceClipboardError) -> SpicePasteboardSnapshot?

    public init(
        authorization: @escaping @MainActor @Sendable () -> SpicePasteboardAuthorization,
        snapshot: @escaping @MainActor @Sendable (UInt64) -> SpicePasteboardSnapshot?,
        write: @escaping @MainActor @Sendable (UInt64, String) throws(SpiceClipboardError) -> SpicePasteboardSnapshot?
    ) {
        self.authorization = authorization; self.snapshot = snapshot; self.write = write
    }
}
