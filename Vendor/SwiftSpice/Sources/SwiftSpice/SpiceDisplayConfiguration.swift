import Foundation

public struct SpiceMonitorConfiguration: Sendable, Equatable {
    public let id: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(
        id: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func disabled(id: Int) -> Self {
        Self(id: id, x: 0, y: 0, width: 0, height: 0)
    }

    public var isEnabled: Bool {
        width > 0 && height > 0
    }
}

public struct SpiceDisplayConfiguration: Sendable, Equatable {
    public let monitors: [SpiceMonitorConfiguration]

    public init(monitors: [SpiceMonitorConfiguration]) {
        self.monitors = monitors
    }

    public init(width: Int, height: Int) {
        monitors = [.init(id: 0, x: 0, y: 0, width: width, height: height)]
    }
}

public struct SpiceDisplayConfigurationSupport: Sendable, Equatable {
    public let agentConnected: Bool
    public let hasExplicitPeerCapabilities: Bool
    public let supportsMonitorConfiguration: Bool
    public let supportsSparseMonitors: Bool
    public let supportsMonitorPositions: Bool

    public init(
        agentConnected: Bool,
        hasExplicitPeerCapabilities: Bool,
        supportsMonitorConfiguration: Bool,
        supportsSparseMonitors: Bool,
        supportsMonitorPositions: Bool
    ) {
        self.agentConnected = agentConnected
        self.hasExplicitPeerCapabilities = hasExplicitPeerCapabilities
        self.supportsMonitorConfiguration = supportsMonitorConfiguration
        self.supportsSparseMonitors = supportsSparseMonitors
        self.supportsMonitorPositions = supportsMonitorPositions
    }
}

public enum SpiceDisplayConfigurationError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case agentManagerNotRunning
    case invalidDimensions(width: Int, height: Int)
    case invalidLayout(String)
    case unsupportedByAgent
    case invalidAgentReply(String)
    case transport(SpiceError)

    public var description: String {
        switch self {
        case .agentManagerNotRunning:
            "SPICE Agent manager is not running"
        case let .invalidDimensions(width, height):
            "invalid display dimensions \(width)x\(height)"
        case let .invalidLayout(reason):
            "invalid display layout: \(reason)"
        case .unsupportedByAgent:
            "guest agent does not support monitor configuration"
        case let .invalidAgentReply(reason):
            "invalid monitor configuration reply: \(reason)"
        case let .transport(error):
            "monitor configuration transport failed: \(error)"
        }
    }
}

public enum SpiceDisplayConfigurationEvent: Sendable, Equatable {
    case queued(SpiceDisplayConfiguration)
    case sent(SpiceDisplayConfiguration)
    case acknowledged(SpiceDisplayConfiguration)
    case rejected(SpiceDisplayConfiguration)
    case unsupported(SpiceDisplayConfiguration)
    case failed(SpiceDisplayConfiguration, SpiceDisplayConfigurationError)
    case protocolFailure(SpiceDisplayConfigurationError)
}

package struct DisplayConfigurationCoordinator: Sendable {
    /// How long a sent configuration keeps the send window closed while it is
    /// unacknowledged.
    ///
    /// The window exists so that a drag does not flood the guest agent: while one
    /// configuration is in flight only the latest is kept. A reply is not
    /// guaranteed, though. With virtio-gpu, QEMU consumes
    /// `VD_AGENT_MONITORS_CONFIG` in its own `client_monitors_config` handler and
    /// sends no `VD_AGENT_REPLY`, so a window that only a reply can close latches
    /// for the life of the agent connection: the first resize is delivered and
    /// every later one is silently dropped while the session still advertises
    /// monitor configuration (measured against QEMU 8.2.2 and 10.0.13,
    /// 2026-09-18). Bounding the wait keeps the coalescing and restores liveness.
    package static let acknowledgementTimeout: Duration = .seconds(2)

    private(set) package var desired: SpiceDisplayConfiguration?
    private(set) package var inFlight: SpiceDisplayConfiguration?
    private(set) package var inFlightExpiry: ContinuousClock.Instant?

    package mutating func queue(_ configuration: SpiceDisplayConfiguration) {
        desired = configuration
    }

    /// The configuration to send now: the latest queued one, unless a sent
    /// configuration is still inside its acknowledgement window.
    package func nextToSend(now: ContinuousClock.Instant) -> SpiceDisplayConfiguration? {
        guard let desired else {
            return nil
        }
        if let inFlightExpiry, now < inFlightExpiry {
            return nil
        }
        return desired
    }

    package mutating func didSend(
        _ configuration: SpiceDisplayConfiguration,
        at instant: ContinuousClock.Instant
    ) {
        guard nextToSend(now: instant) == configuration else {
            return
        }
        desired = nil
        inFlight = configuration
        inFlightExpiry = instant.advanced(by: Self.acknowledgementTimeout)
    }

    package mutating func didReceiveReply() -> SpiceDisplayConfiguration? {
        defer {
            inFlight = nil
            inFlightExpiry = nil
        }
        return inFlight
    }

    package mutating func disconnected() {
        if desired == nil {
            desired = inFlight
        }
        inFlight = nil
        inFlightExpiry = nil
    }

    package mutating func discardDesired() {
        desired = nil
    }

    package mutating func reset() {
        desired = nil
        inFlight = nil
        inFlightExpiry = nil
    }
}
