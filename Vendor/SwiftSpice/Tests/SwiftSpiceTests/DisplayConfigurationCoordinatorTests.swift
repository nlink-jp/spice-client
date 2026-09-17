import Testing
@testable import SwiftSpice

@Suite("Dynamic resolution request coalescing")
struct DisplayConfigurationCoordinatorTests {
    private let start = ContinuousClock.now
    private var withinWindow: ContinuousClock.Instant {
        start.advanced(by: DisplayConfigurationCoordinator.acknowledgementTimeout - .milliseconds(1))
    }
    private var afterWindow: ContinuousClock.Instant {
        start.advanced(by: DisplayConfigurationCoordinator.acknowledgementTimeout + .milliseconds(1))
    }

    @Test func keepsOnlyLatestResizeWhileWaitingForReply() throws {
        var coordinator = DisplayConfigurationCoordinator()
        let first = SpiceDisplayConfiguration(width: 1_024, height: 768)
        let intermediate = SpiceDisplayConfiguration(width: 1_280, height: 800)
        let latest = SpiceDisplayConfiguration(width: 1_440, height: 900)

        coordinator.queue(first)
        #expect(coordinator.nextToSend(now: start) == first)
        coordinator.didSend(first, at: start)
        coordinator.queue(intermediate)
        coordinator.queue(latest)

        #expect(coordinator.nextToSend(now: withinWindow) == nil)
        #expect(coordinator.didReceiveReply() == first)
        #expect(coordinator.nextToSend(now: withinWindow) == latest)
    }

    /// A peer that never replies must not latch the sender: with virtio-gpu QEMU
    /// consumes the monitors configuration and sends no reply, which used to drop
    /// every resize after the first one for the life of the agent connection.
    @Test func unacknowledgedRequestReleasesTheWindowAfterItsTimeout() {
        var coordinator = DisplayConfigurationCoordinator()
        let first = SpiceDisplayConfiguration(width: 1_024, height: 768)
        let latest = SpiceDisplayConfiguration(width: 1_280, height: 800)

        coordinator.queue(first)
        coordinator.didSend(first, at: start)
        coordinator.queue(latest)

        #expect(coordinator.nextToSend(now: withinWindow) == nil)
        #expect(coordinator.nextToSend(now: afterWindow) == latest)

        coordinator.didSend(latest, at: afterWindow)
        #expect(coordinator.inFlight == latest)
        #expect(coordinator.nextToSend(now: afterWindow) == nil)
    }

    /// An expired window alone sends nothing: liveness must not turn into a
    /// resend loop of a configuration the guest already has.
    @Test func expiredWindowWithNothingQueuedSendsNothing() {
        var coordinator = DisplayConfigurationCoordinator()
        let only = SpiceDisplayConfiguration(width: 1_024, height: 768)

        coordinator.queue(only)
        coordinator.didSend(only, at: start)

        #expect(coordinator.nextToSend(now: afterWindow) == nil)
        #expect(coordinator.inFlight == only)
    }

    @Test func reconnectRequeuesInFlightRequestUnlessNewerRequestExists() {
        var firstCoordinator = DisplayConfigurationCoordinator()
        let first = SpiceDisplayConfiguration(width: 800, height: 600)
        firstCoordinator.queue(first)
        firstCoordinator.didSend(first, at: start)
        firstCoordinator.disconnected()
        #expect(firstCoordinator.nextToSend(now: start) == first)

        var latestCoordinator = DisplayConfigurationCoordinator()
        let latest = SpiceDisplayConfiguration(width: 1_920, height: 1_080)
        latestCoordinator.queue(first)
        latestCoordinator.didSend(first, at: start)
        latestCoordinator.queue(latest)
        latestCoordinator.disconnected()
        #expect(latestCoordinator.nextToSend(now: start) == latest)
    }

    @Test func publicManagerRejectsInvalidOrUnstartedRequests() async {
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)

        await #expect(throws: SpiceDisplayConfigurationError.invalidDimensions(
            width: 0,
            height: 600
        )) {
            try await manager.requestResolution(width: 0, height: 600)
        }
        await #expect(throws: SpiceDisplayConfigurationError.agentManagerNotRunning) {
            try await manager.requestResolution(width: 800, height: 600)
        }
    }
}
