import Foundation

public enum BridgeConnectionState: String, Sendable, Equatable {
    case unpaired
    case stopped
    case connecting
    case online
    case offline
    case emergencyStopped
    case revoked
}

public struct BridgeSnapshot: Sendable, Equatable {
    public var state: BridgeConnectionState
    public var deviceId: String?
    public var label: String?
    public var sessionGeneration: Int
    public var activeTaskId: String?
    public var lastError: String?
    public var pollMode: String
    public var pendingOutboxCount: Int

    public init(
        state: BridgeConnectionState,
        deviceId: String? = nil,
        label: String? = nil,
        sessionGeneration: Int = 1,
        activeTaskId: String? = nil,
        lastError: String? = nil,
        pollMode: String = "warm",
        pendingOutboxCount: Int = 0
    ) {
        self.state = state
        self.deviceId = deviceId
        self.label = label
        self.sessionGeneration = sessionGeneration
        self.activeTaskId = activeTaskId
        self.lastError = lastError
        self.pollMode = pollMode
        self.pendingOutboxCount = pendingOutboxCount
    }
}

public actor SitesBridgeController {
    private let config: SitesBridgeConfig
    private let store: CredentialStoring
    private let executor: PokiCoreExecuting
    private let transport: HTTPTransporting
    private let lifecycle: DeviceLifecycleCoordinator
    private let networkMonitor: NetworkPathMonitoring?
    private let onAutomationFinish: (@Sendable () async -> Bool)?

    private var signer: SitesRequestSigner?
    private var credentials: StoredDeviceCredentials?
    private var client: SitesBridgeClient?

    private var state: BridgeConnectionState = .unpaired
    private var sessionGeneration = 1
    private var emergencyStopped = false
    private var localStopGeneration = 0
    private var localStopUnconfirmed = false
    private var controlGeneration = 0
    private var activeTask: (taskId: String, leaseToken: String)?
    private var activeExecution: Task<PokiToolReply, Never>?
    private var automationFinishAnchor: (taskId: String, generation: Int)?
    private var pollConfig = PollConfigDTO(wait_ms: 10_000, delay_ms: 2_000, mode: "warm")
    private var lastError: String?

    private var pollLoopTask: Task<Void, Never>?
    private var pollDelay: (id: UUID, task: Task<Void, Never>)?
    private var pollWakeGeneration = 0
    private var heartbeatTask: Task<Void, Never>?
    private var running = false
    private var pendingApproval: PendingApprovalDTO?
    private var pendingHandoff: PendingHandoffDTO?
    private var onStateChange: (@Sendable (BridgeSnapshot) -> Void)?

    public init(
        config: SitesBridgeConfig = SitesBridgeConfig(),
        store: CredentialStoring = KeychainCredentialStore(),
        executor: PokiCoreExecuting,
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        networkMonitor: NetworkPathMonitoring? = nil,
        onAutomationFinish: (@Sendable () async -> Bool)? = nil
    ) {
        self.config = config
        self.store = store
        self.executor = executor
        self.transport = transport
        self.lifecycle = DeviceLifecycleCoordinator(store: store)
        self.networkMonitor = networkMonitor
        self.onAutomationFinish = onAutomationFinish
        if let creds = try? store.loadCredentials(),
           let addr = SitesAddress(creds.sitesOrigin),
           let key = try? store.loadOrCreatePrivateKey() {
            let s = SitesRequestSigner(privateKey: key)
            self.signer = s
            self.credentials = creds
            self.sessionGeneration = creds.sessionGeneration
            self.client = SitesBridgeClient(address: addr, signer: s, transport: transport)
            self.state = .stopped
        }
    }

    public func setOnStateChange(_ handler: (@Sendable (BridgeSnapshot) -> Void)?) {
        onStateChange = handler
    }

    public func snapshot() -> BridgeSnapshot {
        BridgeSnapshot(
            state: state,
            deviceId: credentials?.deviceId,
            label: signer?.label ?? credentials?.label,
            sessionGeneration: sessionGeneration,
            activeTaskId: activeTask?.taskId,
            lastError: lastError,
            pollMode: pollConfig.mode,
            pendingOutboxCount: lifecycle.pendingOutboxCount
        )
    }

    public var isPaired: Bool {
        credentials != nil && state != .unpaired && state != .revoked
    }

    public func pair(
        sitesURL: String,
        pairingCode: String,
        deviceName: String?,
        siwcBypassToken: String? = nil
    ) async throws -> StoredDeviceCredentials {
        guard let address = SitesAddress(sitesURL) else {
            throw SitesClientError.invalidAddress
        }
        let cleanBypass = SitesRequestSigner.normalizeBearerToken(siwcBypassToken)
        let key = try store.loadOrCreatePrivateKey()
        let reqSigner = SitesRequestSigner(privateKey: key)
        let api = SitesBridgeClient(address: address, signer: reqSigner, transport: transport)
        let res = try await api.pair(
            pairingCode: pairingCode,
            deviceName: deviceName,
            config: config,
            siwcBypassToken: cleanBypass
        )
        let saved = StoredDeviceCredentials(
            sitesOrigin: address.origin.absoluteString,
            deviceId: res.device_id,
            deviceToken: res.device_token,
            label: res.label,
            sessionGeneration: res.session_generation,
            siwcBypassToken: cleanBypass
        )
        try store.saveCredentials(saved)
        self.signer = reqSigner
        self.credentials = saved
        self.client = api
        self.sessionGeneration = res.session_generation
        self.automationFinishAnchor = nil
        self.pollConfig = res.poll_config
        self.lastError = nil
        updateState(.stopped)
        return saved
    }

    public func updateSIWCBypassToken(_ token: String?) throws {
        guard var creds = credentials else {
            throw SitesClientError.missingCredentials
        }
        creds.siwcBypassToken = SitesRequestSigner.normalizeBearerToken(token)
        try store.saveCredentials(creds)
        credentials = creds
        lastError = nil
        onStateChange?(snapshot())
    }

    public func start() {
        guard !running, client != nil, credentials != nil else { return }
        running = true
        updateState(.connecting)
        networkMonitor?.start { [weak self] kind in
            Task { await self?.handleNetworkChange(kind) }
        }
        pollLoopTask = Task { [weak self] in await self?.runPollLoop() }
        heartbeatTask = Task { [weak self] in await self?.runHeartbeatLoop() }
    }

    public func stop() {
        controlGeneration += 1
        automationFinishAnchor = nil
        running = false
        activeExecution?.cancel()
        pollDelay?.task.cancel()
        pollDelay = nil
        pollLoopTask?.cancel()
        pollLoopTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        networkMonitor?.stop()
        if state != .unpaired && state != .revoked {
            updateState(.stopped)
        }
    }

    public func unpair() {
        stop()
        localStopGeneration += 1
        localStopUnconfirmed = false
        try? store.deleteCredentials()
        credentials = nil
        client = nil
        signer = nil
        sessionGeneration = 1
        emergencyStopped = false
        lastError = nil
        updateState(.unpaired)
    }

    public func setLocalDDIMounted(_ mounted: Bool) {
        lifecycle.setLocalDDIMounted(mounted)
    }

    public func updateLifecycle(foreground: Bool) {
        if foreground { lifecycle.markForeground() } else { lifecycle.markBackground() }
    }

    public func setScreenLocked(_ locked: Bool) {
        let wasLocked = lifecycle.current.screenLocked
        lifecycle.setScreenLocked(locked)
        if wasLocked && !locked && running {
            pollWakeGeneration += 1
            pollDelay?.task.cancel()
        }
    }

    public func markWokeFromSuspension() async {
        lifecycle.markWokeFromSuspension()
        pollWakeGeneration += 1
        pollDelay?.task.cancel()
        await flushOutboxAndHeartbeat(resetSession: false)
    }

    public func handleNetworkChange(_ kind: DeviceNetworkKind) async {
        let wasOffline = lifecycle.current.network == .offline
        let changed = lifecycle.updateNetwork(kind)
        if changed && kind != .offline && running {
            pollWakeGeneration += 1
            pollDelay?.task.cancel()
            if wasOffline {
                // The poll loop flushes pending results before claiming its next task.
                await sendHeartbeat(resetSession: false)
            } else {
                await flushOutboxAndHeartbeat(resetSession: false)
            }
        }
    }

    public func triggerOwnerEmergencyStop(reason: String = "Stopped by owner on iPhone") async {
        localStopGeneration += 1
        let stopGeneration = localStopGeneration
        localStopUnconfirmed = true
        emergencyStopped = true
        lastError = nil
        updateState(.emergencyStopped)
        if let active = activeTask {
            await cancelTask(active.taskId)
        }
        guard stopGeneration == localStopGeneration else { return }
        guard let client, let creds = credentials else {
            lastError = "Emergency stop could not be confirmed: no device connection."
            updateState(.emergencyStopped)
            return
        }
        do {
            let response = try await client.cancel(
                credentials: creds,
                generation: sessionGeneration,
                payload: CancelRequestDTO(
                    task_id: activeTask?.taskId,
                    lease_token: activeTask?.leaseToken,
                    reason: reason,
                    owner_stop: true
                ),
                timeoutSeconds: config.requestTimeoutSeconds
            )
            guard stopGeneration == localStopGeneration else { return }
            guard response.acknowledged else {
                lastError = "Emergency stop was not confirmed by the server."
                updateState(.emergencyStopped)
                return
            }
            localStopUnconfirmed = false
            emergencyStopped = response.emergency_stopped
            if state != .stopped && state != .revoked {
                updateState(response.emergency_stopped ? .emergencyStopped : .online)
            }
        } catch {
            guard stopGeneration == localStopGeneration else { return }
            lastError = "Emergency stop could not be confirmed: \(error.localizedDescription)"
            if state != .stopped && state != .revoked { updateState(.emergencyStopped) }
        }
    }

    public func runSinglePollCycle() async {
        let stopGeneration = localStopGeneration
        let controlGeneration = self.controlGeneration
        await flushOutbox()
        guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: false),
              let client, let creds = credentials else { return }
        if lifecycle.consumeResetSessionFlag() {
            await sendHeartbeat(resetSession: true)
        }
        let snap = lifecycle.current
        let runner = PokiRunnerStateMapper.normalize(await executor.currentRunnerState())
        let waitMs = lifecycle.effectivePollWaitMs(
            serverConfig: pollConfig,
            defaultWaitMs: config.defaultPollWaitMs
        )
        let req = PollRequestDTO(
            wait_ms: waitMs,
            runner_state: runner,
            network_state: snap.network.rawValue,
            app_lifecycle_state: snap.lifecycle.rawValue,
            screen_locked: snap.screenLocked,
            supports_task_finish: onAutomationFinish == nil ? nil : true
        )
        guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: false) else { return }
        do {
            let res = try await client.poll(
                credentials: creds,
                generation: sessionGeneration,
                payload: req,
                timeoutSeconds: max(config.requestTimeoutSeconds, Double(waitMs) / 1000.0 + 10)
            )
            guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: false) else { return }
            sessionGeneration = res.session_generation
            pollConfig = res.poll_config
            emergencyStopped = res.emergency_stopped
            lastError = nil
            updateState(res.emergency_stopped ? .emergencyStopped : .online)
            await applyCancellationRequests(res.cancel_task_ids, emergencyStopped: res.emergency_stopped)
            if let task = res.task,
               acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: false),
               !emergencyStopped {
                if task.tool_name == "stop" {
                    await finishClaimedAutomation(task, cancelled: res.cancel_task_ids.contains(task.task_id))
                } else {
                    await executeClaimedTask(task)
                }
                if !emergencyStopped {
                    pollConfig = PollConfigDTO(wait_ms: config.defaultPollWaitMs, delay_ms: 150, mode: "active")
                }
            }
        } catch let err as SitesClientError {
            guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: false) else { return }
            handleClientError(err)
        } catch {
            guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: false) else { return }
            lastError = error.localizedDescription
            updateState(.offline)
        }
    }

    private func runPollLoop() async {
        var backoffAttempt = 0
        while running && !Task.isCancelled {
            let beforeState = state
            let wakeGeneration = pollWakeGeneration
            await runSinglePollCycle()
            if !running || Task.isCancelled { break }
            if state == .revoked {
                running = false
                break
            }
            if wakeGeneration != pollWakeGeneration {
                backoffAttempt = 0
                continue
            }
            if state == .offline && beforeState == .offline {
                backoffAttempt = min(5, backoffAttempt + 1)
                let delay = min(config.maxBackoffSeconds, config.minBackoffSeconds * pow(2.0, Double(backoffAttempt - 1)))
                let jitter = delay * Double.random(in: 0.75...1.25)
                await waitForNextPoll(seconds: jitter)
            } else {
                backoffAttempt = 0
                let delay = lifecycle.effectivePollDelaySeconds(serverConfig: pollConfig)
                await waitForNextPoll(seconds: delay)
            }
        }
    }

    private func waitForNextPoll(seconds: TimeInterval) async {
        let id = UUID()
        let task = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        pollDelay = (id, task)
        await task.value
        if pollDelay?.id == id { pollDelay = nil }
    }

    private func runHeartbeatLoop() async {
        while running && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.heartbeatIntervalSeconds))
            if !running || Task.isCancelled { break }
            await flushOutboxAndHeartbeat(resetSession: false)
        }
    }

    private func flushOutboxAndHeartbeat(resetSession: Bool) async {
        await flushOutbox()
        await sendHeartbeat(resetSession: resetSession)
    }

    @discardableResult
    private func sendHeartbeat(resetSession: Bool) async -> HeartbeatResponseDTO? {
        guard let client, let creds = credentials else { return nil }
        let stopGeneration = localStopGeneration
        let controlGeneration = self.controlGeneration
        let startedUnconfirmed = localStopUnconfirmed
        let snap = lifecycle.current
        let runner = PokiRunnerStateMapper.normalize(await executor.currentRunnerState())
        let req = HeartbeatRequestDTO(
            runner_state: runner,
            app_version: config.appVersion,
            ios_version: config.iosVersion,
            network_state: snap.network.rawValue,
            app_lifecycle_state: snap.lifecycle.rawValue,
            battery_level: nil,
            reset_session: resetSession ? true : nil,
            active_task_id: activeTask?.taskId,
            lease_token: activeTask?.leaseToken,
            pending_approval: pendingApproval,
            pending_handoff: pendingHandoff
        )
        do {
            let res = try await client.heartbeat(
                credentials: creds,
                generation: resetSession ? nil : sessionGeneration,
                payload: req,
                timeoutSeconds: config.requestTimeoutSeconds
            )
            guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: startedUnconfirmed) else { return nil }
            sessionGeneration = res.session_generation
            pollConfig = res.poll_config
            emergencyStopped = res.emergency_stopped
            updateStoredGeneration(res.session_generation)
            updateState(res.emergency_stopped ? .emergencyStopped : .online)
            await applyCancellationRequests(res.cancel_task_ids, emergencyStopped: res.emergency_stopped)
            return res
        } catch let err as SitesClientError {
            guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: startedUnconfirmed) else { return nil }
            handleClientError(err)
        } catch {
            guard acceptsStatusResponse(stopGeneration, controlGeneration: controlGeneration, startedUnconfirmed: startedUnconfirmed) else { return nil }
            lastError = error.localizedDescription
        }
        return nil
    }

    public func canApplyOwnerApproval(id: String) async -> Bool {
        guard let task = activeTask, approvalIsCurrent(id, taskId: task.taskId, leaseToken: task.leaseToken) else {
            return false
        }
        let generation = sessionGeneration
        guard let response = await sendHeartbeat(resetSession: false),
              response.session_generation == generation,
              response.lease_renewed,
              !response.emergency_stopped,
              !response.cancel_task_ids.contains(task.taskId) else {
            return false
        }
        return approvalIsCurrent(id, taskId: task.taskId, leaseToken: task.leaseToken)
    }

    private func approvalIsCurrent(_ id: String, taskId: String, leaseToken: String) -> Bool {
        guard activeTask?.taskId == taskId,
              activeTask?.leaseToken == leaseToken,
              let approval = pendingApproval, approval.id == id,
              let execution = activeExecution, !execution.isCancelled,
              !emergencyStopped, !localStopUnconfirmed else {
            return false
        }
        if let expiresAt = approval.expires_at {
            return expiresAt > Int64(Date().timeIntervalSince1970 * 1_000)
        }
        return true
    }

    public func reportPendingApproval(_ approval: PendingApprovalDTO?) async {
        pendingApproval = approval
        guard let approval, let active = activeTask, let client, let creds = credentials else { return }
        let runner = PokiRunnerStateMapper.normalize(await executor.currentRunnerState())
        let interim = ResultRequestDTO(
            task_id: active.taskId,
            lease_token: active.leaseToken,
            status: "awaiting_approval",
            summary: approval.summary,
            raw_text: "approval_required (id \(approval.id)): \(approval.summary)",
            error_code: "APPROVAL_REQUIRED",
            error_message: approval.reason,
            uncertain_execution: nil,
            action_receipts: nil,
            approval_required: approval,
            handoff_required: pendingHandoff,
            finished_app_return: nil,
            observation: nil,
            runner_state: runner
        )
        _ = try? await client.submitResult(
            credentials: creds,
            generation: sessionGeneration,
            payload: interim,
            timeoutSeconds: config.requestTimeoutSeconds
        )
    }

    public func reportPendingHandoff(_ handoff: PendingHandoffDTO?) async {
        pendingHandoff = handoff
        guard let handoff, let active = activeTask, let client, let creds = credentials else { return }
        let runner = PokiRunnerStateMapper.normalize(await executor.currentRunnerState())
        let interim = ResultRequestDTO(
            task_id: active.taskId,
            lease_token: active.leaseToken,
            status: "running",
            summary: handoff.text,
            raw_text: "handoff: waiting \(handoff.kind) — \(handoff.text)",
            error_code: nil,
            error_message: nil,
            uncertain_execution: nil,
            action_receipts: nil,
            approval_required: pendingApproval,
            handoff_required: handoff,
            finished_app_return: nil,
            observation: nil,
            runner_state: runner
        )
        _ = try? await client.submitResult(
            credentials: creds,
            generation: sessionGeneration,
            payload: interim,
            timeoutSeconds: config.requestTimeoutSeconds
        )
    }

    private func executeClaimedTask(_ task: ClaimedTaskDTO) async {
        let generation = sessionGeneration
        let control = controlGeneration
        let stop = localStopGeneration
        automationFinishAnchor = nil
        let clock = ContinuousClock()
        let startedAt = clock.now
        activeTask = (task.task_id, task.lease_token)
        let execution = Task { await executor.execute(task: task) }
        activeExecution = execution
        defer {
            activeExecution = nil
            activeTask = nil
            pendingApproval = nil
            pendingHandoff = nil
        }

        let reply = await execution.value
        let replyAt = clock.now
        let parsed = PokiOutputParser.parse(
            toolName: task.tool_name,
            text: reply.text,
            isError: reply.isError,
            screenshotJPEG: reply.screenshotJPEG
        )
        let parsedAt = clock.now
        let runner = PokiRunnerStateMapper.normalize(await executor.currentRunnerState())
        let runnerStateAt = clock.now
        var observation = pendingApproval == nil && pendingHandoff == nil && !execution.isCancelled
            ? OpeningEntryEvidence.applying(to: parsed, task: task)
            : parsed.observation
        let uploadReadyAt = clock.now
        if task.tool_name == "look" || task.tool_name == "do" {
            let executionMs = Self.milliseconds(startedAt.duration(to: replyAt))
            let parseMs = Self.milliseconds(replyAt.duration(to: parsedAt))
            let runnerStateMs = Self.milliseconds(parsedAt.duration(to: runnerStateAt))
            let observationMs = Self.milliseconds(runnerStateAt.duration(to: uploadReadyAt))
            observation.notes.append(
                "phone_timing_ms: execution=\(executionMs) parse=\(parseMs) runner_state=\(runnerStateMs) observation=\(observationMs)"
            )
        }
        let resultDTO = ResultRequestDTO(
            task_id: task.task_id,
            lease_token: task.lease_token,
            status: parsed.status,
            summary: parsed.summary,
            raw_text: reply.text,
            error_code: parsed.errorCode,
            error_message: parsed.errorMessage,
            uncertain_execution: parsed.uncertainExecution,
            action_receipts: parsed.receipts,
            approval_required: parsed.approvalRequired ?? pendingApproval,
            handoff_required: parsed.handoffRequired ?? pendingHandoff,
            finished_app_return: parsed.finishedAppReturn,
            observation: observation,
            runner_state: runner
        )
        if (task.tool_name == "look" || task.tool_name == "do"), resultDTO.status == "succeeded",
           resultDTO.uncertain_execution != true, resultDTO.approval_required == nil, resultDTO.handoff_required == nil,
           generation == sessionGeneration, !execution.isCancelled,
           acceptsStatusResponse(stop, controlGeneration: control, startedUnconfirmed: false) {
            automationFinishAnchor = (task.task_id, generation)
        }
        await deliverOrQueueResult(resultDTO)
    }

    private func finishClaimedAutomation(_ task: ClaimedTaskDTO, cancelled: Bool) async {
        let matchesAnchor = task.payload["after_task_id"]?.stringValue == automationFinishAnchor?.taskId &&
            automationFinishAnchor?.generation == sessionGeneration
        var requested = false
        if matchesAnchor, !cancelled, activeTask == nil, pendingApproval == nil, pendingHandoff == nil,
           let onAutomationFinish {
            // A finished workflow can release the session once, even if the request is delivered again.
            automationFinishAnchor = nil
            requested = await onAutomationFinish()
        }
        let summary = requested ? "Poki requested automation standby." : "Poki did not request automation standby."
        await deliverOrQueueResult(ResultRequestDTO(
            task_id: task.task_id,
            lease_token: task.lease_token,
            status: requested ? "succeeded" : "cancelled",
            summary: summary,
            raw_text: summary,
            error_code: requested ? nil : "AUTOMATION_FINISH_SKIPPED",
            error_message: requested ? nil : summary,
            uncertain_execution: nil,
            action_receipts: nil,
            approval_required: nil,
            handoff_required: nil,
            finished_app_return: nil,
            observation: nil,
            runner_state: nil
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

    private func cancelTask(_ taskId: String) async {
        if activeTask?.taskId == taskId {
            activeExecution?.cancel()
        }
        await executor.cancelActiveTask(taskId: taskId)
    }

    private func acceptsStatusResponse(
        _ stopGeneration: Int, controlGeneration: Int, startedUnconfirmed: Bool
    ) -> Bool {
        !Task.isCancelled && stopGeneration == localStopGeneration && controlGeneration == self.controlGeneration &&
            !startedUnconfirmed && !localStopUnconfirmed
    }

    private func applyCancellationRequests(_ taskIds: [String], emergencyStopped: Bool) async {
        if emergencyStopped, let activeId = activeTask?.taskId, !taskIds.contains(activeId) {
            await cancelTask(activeId)
        }
        for taskId in taskIds {
            await cancelTask(taskId)
        }
    }

    private func deliverOrQueueResult(_ result: ResultRequestDTO) async {
        guard let client, let creds = credentials else {
            lifecycle.queueOutboxResult(result)
            return
        }
        do {
            _ = try await client.submitResult(
                credentials: creds,
                generation: sessionGeneration,
                payload: result,
                timeoutSeconds: config.requestTimeoutSeconds
            )
            lifecycle.markOutboxDelivered(taskId: result.task_id)
        } catch let err as SitesClientError {
            if case .httpError(400, _, _) = err {
                lifecycle.markOutboxDelivered(taskId: result.task_id)
            } else {
                lifecycle.queueOutboxResult(result)
            }
            handleClientError(err)
        } catch {
            lifecycle.queueOutboxResult(result)
            lastError = error.localizedDescription
            updateState(.offline)
        }
    }

    private func flushOutbox() async {
        let pending = lifecycle.takeOutboxBatch()
        guard !pending.isEmpty, let client, let creds = credentials else { return }
        for item in pending {
            do {
                _ = try await client.submitResult(
                    credentials: creds,
                    generation: sessionGeneration,
                    payload: item,
                    timeoutSeconds: config.requestTimeoutSeconds
                )
                lifecycle.markOutboxDelivered(taskId: item.task_id)
            } catch {
                break
            }
        }
    }

    private func handleClientError(_ err: SitesClientError) {
        switch err {
        case .staleGeneration(let current):
            sessionGeneration = current
            updateStoredGeneration(current)
            lastError = "Re-synchronized generation to \(current)"
        case .unauthorized(let code, let message):
            lastError = "\(code): \(message)"
            if code == "UNKNOWN_OR_REVOKED_DEVICE" {
                updateState(.revoked)
            } else {
                updateState(.offline)
            }
        default:
            lastError = "\(err)"
            updateState(.offline)
        }
    }

    private func updateStoredGeneration(_ gen: Int) {
        guard var creds = credentials else { return }
        creds.sessionGeneration = gen
        credentials = creds
        try? store.saveCredentials(creds)
    }

    private func updateState(_ next: BridgeConnectionState) {
        state = next
        onStateChange?(snapshot())
    }
}
