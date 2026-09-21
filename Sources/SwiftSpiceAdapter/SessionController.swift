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
    /// One entry per drop (ADR-0005). Finished groups stay until the session ends,
    /// so a failure the operator has not read yet does not vanish.
    public private(set) var transfers: [FileTransferGroup] = []
    public private(set) var transferRefusal: FileTransferRefusal?
    public private(set) var guestAcceptsFiles = false
    public private(set) var diagnosticsEnabled = false
    public private(set) var usedFallback = false
    public var shareClipboard = false {
        didSet { broker.setEnabled(shareClipboard && lifecycle.phase == .connected, session: id) }
    }
    @ObservationIgnored private let broker: ClipboardBroker
    @ObservationIgnored private var desiredSize: (width: Int, height: Int)?
    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var transferWatchdog: Task<Void, Never>?
    /// This application's bounds, not the dependency's defaults (ADR-0005 §2).
    @ObservationIgnored public static let maximumConcurrentTransfers = 4
    @ObservationIgnored public static let maximumTransferBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    /// Small enough to fit the agent's token window. A message costs one token per
    /// 2 KiB wire fragment; QEMU grants 10 tokens and returns them 5 at a time, so
    /// the dependency's 16,000-byte default needs 8 and deadlocks at 7 after the
    /// second chunk (measured 2026-09-18 against QEMU 8.2). 4,000 bytes needs 2.
    @ObservationIgnored public static let transferChunkBytes = 4_000
    /// A transfer that has not moved for this long has stopped: the guest never
    /// answered, a terminal event was evicted, or a cancellation is unacknowledged.
    @ObservationIgnored public static let defaultTransferStallTimeout: Duration = .seconds(60)
    /// The stall timeout this session applies. Only the live-peer tests change it,
    /// so that a stall shows in seconds rather than a minute.
    @ObservationIgnored public var transferStallTimeout: Duration = SessionController.defaultTransferStallTimeout
    /// Shutdown waits this long for the agent, then proceeds; its drain is not
    /// bounded upstream and a blocking read is not cancellable (ADR-0005 §2).
    @ObservationIgnored public static let agentStopDeadline: Duration = .seconds(5)
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
    /// The operator dropped these on this session's window, or picked them from the
    /// Session menu. Both go through the same rule, which reads nothing when it refuses.
    public func send(_ urls: [URL], isRegularFile: (URL) -> Bool = FileDropPolicy.isRegularFile) {
        switch FileDropPolicy.decide(urls: urls, phase: lifecycle.phase,
                                     agentAvailable: run?.agent != nil && !agentUnavailable,
                                     guestAcceptsFiles: guestAcceptsFiles,
                                     isRegularFile: isRegularFile) {
        case let .send(accepted):
            transferRefusal = nil
            transfers.append(FileTransferGroup(urls: accepted))
            pumpTransfers()
        case let .refused(reason):
            transferRefusal = reason
        }
    }

    public func cancelTransfers(group id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        for item in transfers[index].items where !item.state.isFinished {
            // The row is cancelled now; the dependency keeps the job, and its slot
            // (holdsBackendSlot), until the guest answers the cancellation.
            finishTransfer(item.id, .cancelled)
            if let remote = item.remote, let agent = run?.agent {
                Task { await agent.cancelFileTransfer(remote) }
            }
        }
        pumpTransfers()
    }

    /// Starts queued transfers up to the concurrency bound; called again whenever one
    /// reaches a terminal state so a freed slot is used.
    private func pumpTransfers() {
        guard lifecycle.phase == .connected, let run, let agent = run.agent, !run.retiring else { return }
        var active = FileTransferRules.slotsInUse(transfers)
        for (group, item) in indices(where: { $0.state == .queued }) {
            guard active < Self.maximumConcurrentTransfers else { return }
            active += 1
            transfers[group].items[item].state = .sending
            transfers[group].items[item].lastChange = .now
            let id = transfers[group].items[item].id
            let url = transfers[group].items[item].url
            run.tasks.append(Task { [weak self, weak run] in
                do {
                    let remote = try await agent.sendFile(at: url)
                    guard let self, let run, self.run === run, !run.retiring else { return }
                    self.assign(remote, to: id, agent: agent)
                } catch {
                    guard let self, let run, self.run === run else { return }
                    if let refusal = error as? SpiceFileTransferError, case .tooManyConcurrentTransfers = refusal {
                        // Not a failure: the dependency's count and ours disagree
                        // for a moment. Back in the queue; the watchdog's next pump
                        // starts it once a slot frees.
                        self.requeue(id)
                        return
                    }
                    self.finishTransfer(id, .failed(String(describing: error)))
                    self.pumpTransfers()
                }
            })
        }
    }

    private func indices(where predicate: (FileTransferItem) -> Bool) -> [(Int, Int)] {
        transfers.indices.flatMap { group in
            transfers[group].items.indices.compactMap { predicate(transfers[group].items[$0]) ? (group, $0) : nil }
        }
    }
    private func locate(_ id: UUID) -> (Int, Int)? { indices(where: { $0.id == id }).first }
    private func locate(remote: SpiceFileTransferID) -> (Int, Int)? { indices(where: { $0.remote == remote }).first }

    private func assign(_ remote: SpiceFileTransferID, to id: UUID, agent: SpiceAgentManager) {
        guard let (group, item) = locate(id) else { return }
        // From here the dependency holds a job for this item, whatever the row
        // says, until its terminal event arrives.
        transfers[group].items[item].remote = remote
        transfers[group].items[item].holdsBackendSlot = true
        // A cancel between starting and acceptance still wins.
        guard !transfers[group].items[item].state.isFinished else {
            Task { await agent.cancelFileTransfer(remote) }
            applyBufferedTransferEvents(for: remote)
            return
        }
        transfers[group].items[item].lastChange = .now
        applyBufferedTransferEvents(for: remote)
    }

    private func requeue(_ id: UUID) {
        guard let (group, item) = locate(id), transfers[group].items[item].state == .sending else { return }
        transfers[group].items[item].state = .queued
        transfers[group].items[item].lastChange = .now
    }

    private func finishTransfer(_ id: UUID, _ state: FileTransferItem.State) {
        guard let (group, item) = locate(id), !transfers[group].items[item].state.isFinished else { return }
        transfers[group].items[item].state = state
        transfers[group].items[item].lastChange = .now
    }

    @ObservationIgnored private var bufferedTransferEvents: [SpiceFileTransferID: [SpiceFileTransferEvent]] = [:]
    @ObservationIgnored private var unattributedTransferFailures = 0

    /// Events can arrive before `sendFile` returns the id they name, so an event for
    /// an unknown id is held until the id is assigned rather than dropped.
    private func handle(_ event: SpiceFileTransferEvent) {
        let remote: SpiceFileTransferID?
        switch event {
        case let .queued(id, _, _): remote = id
        case let .awaitingGuestApproval(id): remote = id
        case let .progress(id, _, _): remote = id
        case let .completed(id): remote = id
        case let .cancelled(id): remote = id
        case let .failed(id, _): remote = id
        }
        guard let remote else {
            // A failure for an id we never issued: the guest talking about nothing.
            unattributedTransferFailures += 1
            return
        }
        guard let (group, item) = locate(remote: remote) else {
            bufferedTransferEvents[remote, default: []].append(event)
            return
        }
        transfers[group].items[item].lastChange = .now
        switch event {
        case let .queued(_, _, totalBytes):
            transfers[group].items[item].totalBytes = totalBytes
        case .awaitingGuestApproval:
            break
        case let .progress(_, sentBytes, totalBytes):
            transfers[group].items[item].sentBytes = sentBytes
            transfers[group].items[item].totalBytes = totalBytes
        case .completed:
            transfers[group].items[item].sentBytes = transfers[group].items[item].totalBytes
            transfers[group].items[item].state = .completed
            transfers[group].items[item].holdsBackendSlot = false
            pumpTransfers()
        case .cancelled:
            if !transfers[group].items[item].state.isFinished { transfers[group].items[item].state = .cancelled }
            transfers[group].items[item].holdsBackendSlot = false
            pumpTransfers()
        case let .failed(_, error):
            // A row already finished (cancelled, or failed as stalled) keeps what
            // it says; the dependency's own failure only frees the slot.
            if !transfers[group].items[item].state.isFinished {
                transfers[group].items[item].state = .failed(error.description)
            }
            transfers[group].items[item].holdsBackendSlot = false
            pumpTransfers()
        }
    }

    private func applyBufferedTransferEvents(for remote: SpiceFileTransferID) {
        guard let events = bufferedTransferEvents.removeValue(forKey: remote) else { return }
        for event in events { handle(event) }
    }

    /// Fails transfers that have stopped moving, so a stuck row cannot hold a slot
    /// forever when the guest never answers or a terminal event was evicted.
    private func startTransferWatchdog() {
        transferWatchdog?.cancel()
        transferWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                for id in FileTransferRules.stalled(self.transfers, now: .now, timeout: self.transferStallTimeout) {
                    guard let (group, item) = self.locate(id) else { continue }
                    self.transfers[group].items[item].state = .failed("stalled")
                    self.transfers[group].items[item].lastChange = .now
                    // Tell the dependency too, or it keeps the job, and its slot,
                    // for as long as the connection lives.
                    if let remote = self.transfers[group].items[item].remote, let agent = self.run?.agent {
                        Task { await agent.cancelFileTransfer(remote) }
                    }
                }
                self.pumpTransfers()
            }
        }
    }

    /// Every transfer belongs to the connection that started it. The MJPEG retry
    /// builds a new agent, so nothing may survive into it.
    private func endTransfers(_ state: FileTransferItem.State) {
        FileTransferRules.retire(&transfers, as: state, now: .now)
        bufferedTransferEvents.removeAll()
        transferWatchdog?.cancel(); transferWatchdog = nil
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
                let audio = await run.audio?.statistics()
                guard !Task.isCancelled, self.run === run else { return }
                self.summary = "input_submitted=\(run.input?.submitted ?? 0)\ninput_sent=\(run.input?.sent ?? 0)\n" +
                    "input_coalesced=\(run.input?.coalesced ?? 0)\ninput_pending=\(run.input?.pending ?? 0)\n" +
                    "frames_presented=\(stats.metalPresentedFrames)\ngpu_errors=\(stats.gpuErrors)\n" +
                    "mjpeg_frames=\(stats.mjpegDecodedFrames)\nagent_clipboard_failures=\(agent?.clipboardFailures ?? 0)\n" +
                    "audio_packets=\(audio?.scheduledPackets ?? 0)\naudio_frames=\(audio?.scheduledFrames ?? 0)\n" +
                    "files_sent=\(self.transferCount { $0 == .completed })\nfiles_failed=\(self.transferCount { if case .failed = $0 { true } else { false } })\n" +
                    "files_unattributed_failures=\(self.unattributedTransferFailures)\nbytes_sent=\(self.transfers.reduce(0) { $0 + $1.sentBytes })\n" +
                    "mjpeg_fallback=\(self.usedFallback)\n"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    public func disconnect() {
        guard lifecycle.stop() else { return }
        broker.revoke(id)
        endTransfers(.cancelled)
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
        if let agent = run.agent { await stop(agent, within: agentStopDeadline) }
        await run.audio?.stop()
        for task in run.tasks { await task.value }
        run.tasks.removeAll()
    }

    /// Waits for the agent to stop, then proceeds regardless. Its drain has no
    /// deadline upstream and holds across uncancellable blocking reads, so a source
    /// on a stalled mount would otherwise block quit for ever (ADR-0005 §2).
    private static func stop(_ agent: SpiceAgentManager, within deadline: Duration) async {
        let once = Resumption()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await agent.stop(); await once.resume(continuation) }
            Task { try? await Task.sleep(for: deadline); await once.resume(continuation) }
        }
    }
    private actor Resumption {
        private var resumed = false
        func resume(_ continuation: CheckedContinuation<Void, Never>) {
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
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
                    pasteboardAccess: broker.access(for: id),
                    maximumConcurrentFileTransfers: Self.maximumConcurrentTransfers,
                    maximumFileBytes: Self.maximumTransferBytes,
                    fileTransferChunkBytes: Self.transferChunkBytes)
                run.agent = manager
                run.tasks.append(Task { [weak self, weak run] in
                    for await event in manager.fileTransferEvents {
                        guard !Task.isCancelled, let self, let run, self.run === run else { return }
                        self.handle(event)
                    }
                })
                run.tasks.append(Task { [weak self, weak run] in
                    for await support in manager.displayConfigurationSupportEvents {
                        guard !Task.isCancelled, let self, let run, self.run === run else { return }
                        self.resizingAvailable = support.agentConnected && support.supportsMonitorConfiguration
                        self.guestAcceptsFiles = support.agentConnected
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
                startTransferWatchdog()
                onConnected?(); onConnected = nil
                if diagnosticsEnabled { setDiagnostics(true) }
            } catch let error as SpiceError { if !Task.isCancelled { handle(error, run: run) } }
            catch { if !Task.isCancelled, self.run === run { failure = .certificate; disconnect() } }
        })
    }

    private func transferCount(_ match: (FileTransferItem.State) -> Bool) -> Int {
        transfers.reduce(0) { $0 + $1.items.filter { match($0.state) }.count }
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
                self.endTransfers(.failed("connection restarted"))
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
