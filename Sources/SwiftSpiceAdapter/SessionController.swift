// SPDX-License-Identifier: MIT
import Foundation
import Observation
import Security
import ConnectionCore
import SessionCore
import SwiftSpice

public enum SessionFailure: String, Sendable {
    case connection, authentication, protocolViolation, video, input, certificate
}

@MainActor
@Observable
public final class SessionController {
    public let id = UUID()
    public let plan: ConnectionPlan
    public private(set) var lifecycle = SessionLifecycle()
    public private(set) var failure: SessionFailure?
    public private(set) var desktop: SpiceDesktopSource?
    public private(set) var inputAvailable = false
    public private(set) var resizingAvailable = false
    public private(set) var audioUnavailable = false
    public private(set) var agentUnavailable = false
    public private(set) var summary = ""
    public private(set) var diagnosticsEnabled = false
    public private(set) var usedFallback = false
    public var shareClipboard = false {
        didSet { broker.setEnabled(shareClipboard && lifecycle.phase == .connected, session: id) }
    }
    @ObservationIgnored private let broker: ClipboardBroker
    @ObservationIgnored private var desiredSize: (width: Int, height: Int)?
    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored public var onConnected: (@MainActor () -> Void)?

    @MainActor
    private final class Run {
        let session = SpiceSession()
        var input: OrderedInput?
        var audio: SpiceAudioPlaybackSink?
        var agent: SpiceAgentManager?
        var tasks: [Task<Void, Never>] = []
        var diagnostics: Task<Void, Never>?
        var resize: Task<Void, Never>?
        var retiring = false
    }

    public init(plan: ConnectionPlan, broker: ClipboardBroker = .shared) {
        self.plan = plan; self.broker = broker
        broker.setEnabled(false, session: id)
    }
    public func start() {
        guard lifecycle.start() != nil else { return }
        beginAttempt(policy: .h264AndMJPEG)
    }
    public func focus(_ focused: Bool) {
        if focused { broker.setFocused(id) }
        else {
            // Do not erase another window's newer focus event.
            broker.resignFocus(id)
            run?.input?.releaseAll()
        }
    }
    public func submit(_ input: SpiceClientInput) {
        guard lifecycle.phase == .connected else { return }
        run?.input?.submit(input)
    }
    public func secureAttention() { run?.input?.chord([0x1d, 0x38, 0x153]) }
    public func releaseInput() { run?.input?.releaseAll() }
    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        desiredSize = (width, height)
        guard resizingAvailable, let run, let agent = run.agent else { return }
        run.resize?.cancel()
        run.resize = Task { [weak self, weak run] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                try await agent.requestResolution(width: width, height: height)
            } catch {
                guard !Task.isCancelled, let self, let run, self.run === run else { return }
                self.resizingAvailable = false
            }
        }
    }
    public func setDiagnostics(_ enabled: Bool) {
        diagnosticsEnabled = enabled
        run?.diagnostics?.cancel(); run?.diagnostics = nil
        guard enabled, let run else { return }
        run.diagnostics = Task { [weak self, weak run] in
            while !Task.isCancelled, let self, let run, self.run === run {
                let stats = await run.session.diagnosticsSnapshot()
                let agent = await run.agent?.diagnosticsSnapshot()
                guard !Task.isCancelled, self.run === run else { return }
                self.summary = "Spice Client 0.1.0\n" +
                    "input_submitted=\(run.input?.submitted ?? 0)\ninput_sent=\(run.input?.sent ?? 0)\n" +
                    "input_coalesced=\(run.input?.coalesced ?? 0)\ninput_pending=\(run.input?.pending ?? 0)\n" +
                    "frames_presented=\(stats.metalPresentedFrames)\ngpu_errors=\(stats.gpuErrors)\n" +
                    "mjpeg_frames=\(stats.mjpegDecodedFrames)\nagent_clipboard_failures=\(agent?.clipboardFailures ?? 0)\n" +
                    "mjpeg_fallback=\(self.usedFallback)\n"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    public func disconnect() {
        guard lifecycle.stop() else { return }
        broker.revoke(id)
        inputAvailable = false; resizingAvailable = false
        let retired = run; run = nil
        retired?.retiring = true
        retired?.input?.releaseAll() // best effort; no drain wait before closure
        retired?.input?.stop()
        retired?.tasks.forEach { $0.cancel() }
        retired?.resize?.cancel(); retired?.diagnostics?.cancel()
        diagnosticsEnabled = false
        shutdownTask = Task { [self] in
            if let retired { await Self.close(retired) }
            lifecycle.didStop()
            shutdownTask = nil
        }
    }
    public func waitForDisconnection() async { await shutdownTask?.value }

    /// Close transport first: stalled input or agent operations cannot gate it.
    private static func close(_ run: Run) async {
        await run.session.disconnect()
        await run.input?.finish()
        await run.agent?.stop()
        await run.audio?.stop()
        for task in run.tasks { await task.value }
        run.tasks.removeAll()
    }

    private func beginAttempt(policy: SpiceVideoCodecPolicy) {
        let run = Run()
        self.run = run
        desktop = run.session.desktop
        run.tasks.append(Task { [weak self, weak run] in
            guard let run else { return }
            for await event in run.session.events {
                guard !Task.isCancelled, let self, self.run === run, !run.retiring else { return }
                switch event {
                case .failed(let error): self.handle(error, run: run)
                case .disconnected: self.disconnect()
                default: break
                }
            }
        })
        run.tasks.append(Task { [weak self, weak run] in
            guard let self, let run else { return }
            do {
                let info = try await run.session.connect(endpoint: Self.endpoint(plan, policy: policy),
                    credentials: SpiceCredentials(password: plan.password ?? ""))
                guard self.run === run, !run.retiring, !Task.isCancelled else { return }
                inputAvailable = info.channels.contains { $0.type == 3 && $0.id == 0 }
                if inputAvailable {
                    let session = run.session
                    run.input = OrderedInput(send: { try await session.send($0) }, failure: { [weak self] in
                        self?.failure = .input; self?.disconnect()
                    })
                }
                let manager = SpiceAgentManager(pasteboardSynchronizationEnabled: true,
                    pasteboardAccess: broker.access(for: id))
                run.agent = manager
                run.tasks.append(Task { [weak self, weak run] in
                    for await support in manager.displayConfigurationSupportEvents {
                        guard !Task.isCancelled, let self, let run, self.run === run else { return }
                        self.resizingAvailable = support.agentConnected && support.supportsMonitorConfiguration
                        if let size = self.desiredSize { self.resize(width: size.width, height: size.height) }
                    }
                })
                do { try await manager.start(session: run.session) }
                catch { agentUnavailable = true }
                guard self.run === run, !run.retiring, !Task.isCancelled else { return }
                if info.channels.contains(where: { $0.type == 5 && $0.id == 0 }) {
                    let sink = SpiceAudioPlaybackSink(); run.audio = sink
                    do { try await sink.start(session: run.session) } catch { audioUnavailable = true }
                }
                guard self.run === run, !run.retiring, !Task.isCancelled else { return }
                _ = lifecycle.connected(generation: lifecycle.generation)
                broker.setEnabled(shareClipboard, session: id)
                onConnected?(); onConnected = nil
                if diagnosticsEnabled { setDiagnostics(true) }
            } catch let error as SpiceError { if !Task.isCancelled { handle(error, run: run) } }
            catch { if !Task.isCancelled, self.run === run { failure = .certificate; disconnect() } }
        })
    }

    private func handle(_ error: SpiceError, run: Run) {
        guard self.run === run, !run.retiring else { return }
        if case .videoCodecUnavailable = error, !usedFallback {
            run.retiring = true
            // This task belongs to shutdownTask, never to the run it joins.
            shutdownTask = Task { [weak self] in
                let stats = await run.session.diagnosticsSnapshot()
                guard let self, self.run === run, self.lifecycle.phase != .stopping else { return }
                if stats.advancedVideoPresentedFrames > 0 { self.failure = .video; self.disconnect(); return }
                self.usedFallback = true
                self.broker.setEnabled(false, session: self.id)
                _ = self.lifecycle.retry()
                self.inputAvailable = false; self.resizingAvailable = false
                run.input?.stop(); run.tasks.forEach { $0.cancel() }
                run.resize?.cancel(); run.diagnostics?.cancel()
                await Self.close(run)
                guard self.run === run, self.lifecycle.phase != .stopping else { return }
                self.shutdownTask = nil
                self.beginAttempt(policy: .mjpegOnly)
            }
        } else {
            switch error {
            case .authenticationFailed: failure = .authentication
            case .protocolError: failure = .protocolViolation
            case .videoCodecUnavailable: failure = .video
            default: failure = .connection
            }
            disconnect()
        }
    }
    public static func endpoint(_ plan: ConnectionPlan, policy: SpiceVideoCodecPolicy = .h264AndMJPEG) throws -> SpiceEndpoint {
        let tls: TLSTrustPolicy?
        switch plan.security {
        case .plain: tls = nil
        case .systemTLS: tls = .system
        case let .certificateAuthority(pem, subject):
            let pieces = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
            guard !pieces.isEmpty, pieces.allSatisfy({ part in
                guard let end = part.range(of: "-----END CERTIFICATE-----"),
                      let data = Data(base64Encoded: String(part[..<end.lowerBound]).filter { !$0.isWhitespace }) else { return false }
                return SecCertificateCreateWithData(nil, data as CFData) != nil
            }) else { throw ConnectionError.invalidCertificate }
            tls = subject.map { .virtViewerCertificateAuthority(certificates: [Data(pem.utf8)], expectedSubject: $0) }
                ?? .customCertificateAuthority(certificates: [Data(pem.utf8)])
        }
        return SpiceEndpoint(host: plan.host, port: plan.port, tlsPolicy: tls, videoCodecPolicy: policy)
    }
}
