import XCTest
@testable import PokiSitesBridge

final class MockHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    var requests: [(path: String, headers: [String: String], body: String)] = []
    var handlers: [String: (URLRequest, Int) -> (Int, Data)] = [:]
    private var counts: [String: Int] = [:]

    func send(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        let path = request.url?.path ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let headers = request.allHTTPHeaderFields ?? [:]
        let count: Int = lock.withLock {
            requests.append((path, headers, body))
            let next = (counts[path] ?? 0) + 1
            counts[path] = next
            return next
        }
        if let handler = lock.withLock({ handlers[path] }) {
            return handler(request, count)
        }
        return (404, Data("{}".utf8))
    }
}

private actor ReconnectHTTPTransport: HTTPTransporting {
    private let secondOfflinePoll: XCTestExpectation
    private let recoveredPoll: XCTestExpectation
    private let pollAfterRecovery: XCTestExpectation
    private let recoveryHeartbeatStarted: XCTestExpectation
    private var thirdPollContinuation: CheckedContinuation<Void, Never>?
    private var heartbeatContinuation: CheckedContinuation<Void, Never>?
    private var heartbeatReleased = false
    private var heartbeatCount = 0
    private var resultDeliveryAvailable = false
    private var deliveredResultCount = 0
    private var pollCount = 0
    private var activePolls = 0
    private var peakActivePolls = 0

    init(
        secondOfflinePoll: XCTestExpectation,
        recoveredPoll: XCTestExpectation,
        pollAfterRecovery: XCTestExpectation,
        recoveryHeartbeatStarted: XCTestExpectation
    ) {
        self.secondOfflinePoll = secondOfflinePoll
        self.recoveredPoll = recoveredPoll
        self.pollAfterRecovery = pollAfterRecovery
        self.recoveryHeartbeatStarted = recoveryHeartbeatStarted
    }

    func send(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        switch request.url?.path {
        case "/api/device/pair":
            return (200, Data("{\"device_id\":\"dev_1\",\"device_token\":\"tok\",\"session_generation\":1,\"label\":\"lbl\",\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        case "/api/device/heartbeat":
            heartbeatCount += 1
            if heartbeatCount == 2 {
                recoveryHeartbeatStarted.fulfill()
                if !heartbeatReleased {
                    await withCheckedContinuation { heartbeatContinuation = $0 }
                }
            }
            return (200, Data("{\"session_generation\":1,\"emergency_stopped\":false,\"cancel_task_ids\":[],\"lease_renewed\":false,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        case "/api/device/poll":
            return await poll()
        case "/api/device/result":
            guard resultDeliveryAvailable else {
                return (503, Data("{\"error\":{\"code\":\"OFFLINE\",\"message\":\"offline\"}}".utf8))
            }
            deliveredResultCount += 1
            return (200, Data("{\"accepted\":true,\"task_status\":\"succeeded\",\"observation_id\":null}".utf8))
        default:
            return (404, Data("{}".utf8))
        }
    }

    private func poll() async -> (statusCode: Int, data: Data) {
        pollCount += 1
        let attempt = pollCount
        activePolls += 1
        peakActivePolls = max(peakActivePolls, activePolls)
        defer { activePolls -= 1 }

        if attempt <= 2 {
            if attempt == 2 { secondOfflinePoll.fulfill() }
            return (503, Data("{\"error\":{\"code\":\"OFFLINE\",\"message\":\"offline\"}}".utf8))
        }
        if attempt == 3 {
            recoveredPoll.fulfill()
            await withCheckedContinuation { thirdPollContinuation = $0 }
        } else if attempt == 4 {
            pollAfterRecovery.fulfill()
        }
        return (200, Data("{\"task\":null,\"cancel_task_ids\":[],\"emergency_stopped\":false,\"session_generation\":1,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":10000,\"mode\":\"warm\"}}".utf8))
    }

    func releaseThirdPoll() {
        thirdPollContinuation?.resume()
        thirdPollContinuation = nil
    }

    func restoreResultDelivery() {
        resultDeliveryAvailable = true
    }

    func releaseHeartbeat() {
        heartbeatReleased = true
        heartbeatContinuation?.resume()
        heartbeatContinuation = nil
    }

    func pollStats() -> (count: Int, peakActive: Int, deliveredResults: Int) {
        (pollCount, peakActivePolls, deliveredResultCount)
    }
}

final class BridgeControllerTests: XCTestCase {
    func testNetworkRecoveryWakesBackoffWithoutOverlappingPolls() async throws {
        let secondOfflinePoll = expectation(description: "second offline poll")
        let recoveredPoll = expectation(description: "poll after network recovery")
        let pollAfterRecovery = expectation(description: "poll after recovery during an active poll")
        let recoveryHeartbeatStarted = expectation(description: "slow recovery heartbeat started")
        let transport = ReconnectHTTPTransport(
            secondOfflinePoll: secondOfflinePoll,
            recoveredPoll: recoveredPoll,
            pollAfterRecovery: pollAfterRecovery,
            recoveryHeartbeatStarted: recoveryHeartbeatStarted
        )
        let store = InMemoryCredentialStore()
        try store.saveOutbox([ResultRequestDTO(
            task_id: "tsk_offline", lease_token: "lease", status: "succeeded", summary: "ok",
            raw_text: "app: Settings", error_code: nil, error_message: nil,
            uncertain_execution: false, action_receipts: nil, approval_required: nil,
            handoff_required: nil, finished_app_return: false, observation: nil,
            runner_state: "automationReady"
        )])
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(heartbeatIntervalSeconds: 60, minBackoffSeconds: 8, maxBackoffSeconds: 8),
            store: store,
            executor: MockPokiExecutor(),
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.handleNetworkChange(.wifi)
        await controller.start()
        await fulfillment(of: [secondOfflinePoll], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))

        await controller.handleNetworkChange(.offline)
        await transport.restoreResultDelivery()
        let recovery = Task { await controller.handleNetworkChange(.wifi) }
        await fulfillment(of: [recoveryHeartbeatStarted, recoveredPoll], timeout: 2)
        await transport.releaseHeartbeat()
        await recovery.value

        await controller.handleNetworkChange(.offline)
        await controller.handleNetworkChange(.cellular)
        let duringPoll = await transport.pollStats()
        XCTAssertEqual(duringPoll.count, 3)
        XCTAssertEqual(duringPoll.peakActive, 1)
        XCTAssertEqual(duringPoll.deliveredResults, 1)

        await transport.releaseThirdPoll()
        await fulfillment(of: [pollAfterRecovery], timeout: 1)
        let finalStats = await transport.pollStats()
        XCTAssertEqual(finalStats.peakActive, 1)
        await controller.stop()
    }

    func testPairPollExecuteResultAndOwnerEmergencyStop() async throws {
        let transport = MockHTTPTransport()
        let store = InMemoryCredentialStore()
        let executor = MockPokiExecutor()
        let encoder = JSONEncoder()

        transport.handlers["/api/device/pair"] = { _, _ in
            let body = """
            {"device_id":"dev_1","device_token":"tok_abc","session_generation":1,"label":"lbl","poll_config":{"wait_ms":100,"delay_ms":50,"mode":"active"}}
            """
            return (200, Data(body.utf8))
        }
        transport.handlers["/api/device/heartbeat"] = { _, _ in
            let body = """
            {"session_generation":2,"emergency_stopped":false,"cancel_task_ids":[],"lease_renewed":false,"poll_config":{"wait_ms":100,"delay_ms":50,"mode":"active"}}
            """
            return (200, Data(body.utf8))
        }
        transport.handlers["/api/device/poll"] = { _, attempt in
            if attempt == 1 {
                let body = """
                {"task":{"task_id":"tsk_1","tool_name":"look","payload":{"full":false},"observation_id":null,"lease_token":"l_1","lease_expires_at":9999999999999,"expires_at":9999999999999},"cancel_task_ids":[],"emergency_stopped":false,"session_generation":2,"poll_config":{"wait_ms":100,"delay_ms":50,"mode":"active"}}
                """
                return (200, Data(body.utf8))
            }
            let body = """
            {"task":null,"cancel_task_ids":["tsk_2"],"emergency_stopped":false,"session_generation":2,"poll_config":{"wait_ms":100,"delay_ms":50,"mode":"active"}}
            """
            return (200, Data(body.utf8))
        }
        transport.handlers["/api/device/result"] = { _, _ in
            let body = """
            {"accepted":true,"task_status":"succeeded","observation_id":"obs_1"}
            """
            return (200, Data(body.utf8))
        }
        transport.handlers["/api/device/cancel"] = { _, _ in
            let body = """
            {"acknowledged":true,"emergency_stopped":true,"cancelled_count":1}
            """
            return (200, Data(body.utf8))
        }
        _ = encoder

        let controller = SitesBridgeController(
            config: SitesBridgeConfig(),
            store: store,
            executor: executor,
            transport: transport
        )

        let creds = try await controller.pair(
            sitesURL: "https://poki-test.chatgpt.site",
            pairingCode: "ABCD-EFGH-2345",
            deviceName: "Test iPhone",
            siwcBypassToken: "bypass_tok"
        )
        XCTAssertEqual(creds.deviceId, "dev_1")

        await controller.runSinglePollCycle()
        let snap1 = await controller.snapshot()
        XCTAssertEqual(snap1.state, .online)
        XCTAssertEqual(snap1.sessionGeneration, 2)
        XCTAssertEqual(executor.executedTaskIds, ["tsk_1"])

        await controller.runSinglePollCycle()
        XCTAssertEqual(executor.cancelledTaskIds, ["tsk_2"])

        await controller.triggerOwnerEmergencyStop(reason: "User tapped Stop")
        let snap2 = await controller.snapshot()
        XCTAssertEqual(snap2.state, .emergencyStopped)

        let paths = transport.requests.map(\.path)
        XCTAssertTrue(paths.contains("/api/device/pair"))
        XCTAssertTrue(paths.contains("/api/device/heartbeat"))
        XCTAssertTrue(paths.contains("/api/device/poll"))
        XCTAssertTrue(paths.contains("/api/device/result"))
        XCTAssertTrue(paths.contains("/api/device/cancel"))
        let resultBody = try XCTUnwrap(transport.requests.first { $0.path == "/api/device/result" }?.body)
        let result = try JSONDecoder().decode(ResultRequestDTO.self, from: Data(resultBody.utf8))
        let timing = try XCTUnwrap(result.observation?.notes.first { $0.hasPrefix("phone_timing_ms: ") })
        XCTAssertNotNil(timing.range(of: #"^phone_timing_ms: execution=\d+ parse=\d+ runner_state=\d+ observation=\d+$"#, options: .regularExpression))
        let pollHeaders = transport.requests.first { $0.path == "/api/device/poll" }?.headers ?? [:]
        XCTAssertEqual(pollHeaders["OAI-Sites-Authorization"], "Bearer bypass_tok")
        XCTAssertEqual(pollHeaders["Authorization"], "Bearer tok_abc")
    }

    func testStaleGeneration409RecoversAutomatically() async throws {
        let transport = MockHTTPTransport()
        let store = InMemoryCredentialStore()
        let executor = MockPokiExecutor()

        transport.handlers["/api/device/pair"] = { _, _ in
            (200, Data("{\"device_id\":\"dev_1\",\"device_token\":\"tok\",\"session_generation\":1,\"label\":\"lbl\",\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/heartbeat"] = { _, _ in
            (200, Data("{\"session_generation\":1,\"emergency_stopped\":false,\"cancel_task_ids\":[],\"lease_renewed\":false,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/poll"] = { _, _ in
            (409, Data("{\"error\":{\"code\":\"STALE_GENERATION\",\"message\":\"mismatch\",\"current_generation\":7}}".utf8))
        }

        let controller = SitesBridgeController(
            store: store,
            executor: executor,
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.runSinglePollCycle()
        let snap = await controller.snapshot()
        XCTAssertEqual(snap.sessionGeneration, 7)
    }

    func testTokenRotationRedirectHandlingAndLiveApprovalReport() async throws {
        let transport = MockHTTPTransport()
        let store = InMemoryCredentialStore()

        let slowExecutor = MockPokiExecutor(runnerState: "standby") { _ in
            PokiToolReply(text: "app: Settings\nscreenshot: 402 px wide", isError: false)
        }
        transport.handlers["/api/device/pair"] = { _, _ in
            (200, Data("{\"device_id\":\"dev_r\",\"device_token\":\"tok_r\",\"session_generation\":1,\"label\":\"lbl\",\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/heartbeat"] = { _, _ in
            (200, Data("{\"session_generation\":1,\"emergency_stopped\":false,\"cancel_task_ids\":[],\"lease_renewed\":false,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/poll"] = { _, _ in
            (302, Data())
        }

        let controller = SitesBridgeController(store: store, executor: slowExecutor, transport: transport)
        _ = try await controller.pair(
            sitesURL: "https://poki-test.chatgpt.site",
            pairingCode: "1111-2222-3333",
            deviceName: "   Test iPhone   ",
            siwcBypassToken: "Bearer old_tok"
        )
        await controller.runSinglePollCycle()
        let errSnap = await controller.snapshot()
        XCTAssertTrue(errSnap.lastError?.contains("SITES_AUTH_REQUIRED") == true)

        try await controller.updateSIWCBypassToken("Bearer new_tok")
        transport.handlers["/api/device/poll"] = { _, _ in
            (200, Data("{\"task\":null,\"cancel_task_ids\":[],\"emergency_stopped\":false,\"session_generation\":1,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        await controller.runSinglePollCycle()
        let okSnap = await controller.snapshot()
        XCTAssertEqual(okSnap.state, .online)
        let lastPollHeaders = transport.requests.last { $0.path == "/api/device/poll" }?.headers ?? [:]
        XCTAssertEqual(lastPollHeaders["OAI-Sites-Authorization"], "Bearer new_tok")
        let firstPollBody = transport.requests.first { $0.path == "/api/device/poll" }?.body ?? ""
        XCTAssertTrue(firstPollBody.contains("\"runner_state\":\"starting\""))
    }

    func testHeartbeatCancellationStopsInFlightCallAndKeepsSentReceipt() async throws {
        try await assertHeartbeatCancelsInFlight(emergencyStop: false)
    }

    func testHeartbeatEmergencyFlagStopsInFlightCallWithoutTaskIds() async throws {
        try await assertHeartbeatCancelsInFlight(emergencyStop: true)
    }

    private func assertHeartbeatCancelsInFlight(emergencyStop: Bool) async throws {
        let started = expectation(description: "Poki call started")
        let cancelled = expectation(description: "Poki call received cancellation")
        let executor = WaitingPokiExecutor(started: started, cancelled: cancelled)
        let transport = MockHTTPTransport()
        transport.handlers["/api/device/pair"] = { _, _ in
            (200, Data("{\"device_id\":\"dev_1\",\"device_token\":\"tok\",\"session_generation\":1,\"label\":\"lbl\",\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/poll"] = { _, _ in
            (200, Data("{\"task\":{\"task_id\":\"tsk_1\",\"tool_name\":\"do\",\"payload\":{\"actions\":[]},\"observation_id\":null,\"lease_token\":\"lease_1\",\"lease_expires_at\":9999999999999,\"expires_at\":9999999999999},\"cancel_task_ids\":[],\"emergency_stopped\":false,\"session_generation\":1,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/heartbeat"] = { _, _ in
            let emergency = emergencyStop ? "true" : "false"
            let cancelledIds = emergencyStop ? "[]" : "[\"tsk_1\"]"
            let body = "{\"session_generation\":1,\"emergency_stopped\":\(emergency),\"cancel_task_ids\":\(cancelledIds),\"lease_renewed\":false,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}"
            return (200, Data(body.utf8))
        }
        transport.handlers["/api/device/result"] = { _, _ in
            (200, Data("{\"accepted\":true,\"task_status\":\"cancelled\",\"observation_id\":null}".utf8))
        }
        let controller = SitesBridgeController(
            store: InMemoryCredentialStore(), executor: executor, transport: transport
        )
        _ = try await controller.pair(
            sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil
        )
        let cycle = Task { await controller.runSinglePollCycle() }
        await fulfillment(of: [started], timeout: 2)

        await controller.markWokeFromSuspension()
        await fulfillment(of: [cancelled], timeout: 2)
        await controller.stop()
        await cycle.value

        let body = try XCTUnwrap(transport.requests.last(where: { $0.path == "/api/device/result" })?.body)
        let result = try JSONDecoder().decode([String: JSONValue].self, from: Data(body.utf8))
        XCTAssertEqual(result["status"], .string("cancelled"))
        XCTAssertEqual(result["action_receipts"]?.arrayValue?.first?.objectValue?["status"], .string("sent"))
        XCTAssertTrue(result["raw_text"]?.stringValue?.contains("cancelled") == true)
    }

    func testOldRepliesCannotUndoEmergencyStopAndFreshResumeWorks() async throws {
        try await assertOldRepliesRespectEmergencyStop(stopSucceeds: true)
    }

    func testUnconfirmedEmergencyStopStaysActive() async throws {
        try await assertOldRepliesRespectEmergencyStop(stopSucceeds: false)
    }

    func testOldPollCannotStartTaskAfterControlStops() async throws {
        let pollStarted = expectation(description: "old poll started")
        let transport = OutOfOrderStopTransport(
            pollStarted: pollStarted,
            heartbeatStarted: XCTestExpectation(description: "unused heartbeat"),
            pendingHeartbeatStarted: XCTestExpectation(description: "unused pending heartbeat"),
            stopStarted: XCTestExpectation(description: "unused emergency stop"),
            stopSucceeds: true
        )
        let executor = MockPokiExecutor()
        let controller = SitesBridgeController(
            store: InMemoryCredentialStore(), executor: executor, transport: transport
        )
        _ = try await controller.pair(
            sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil
        )
        let poll = Task { await controller.runSinglePollCycle() }
        await fulfillment(of: [pollStarted], timeout: 2)
        await controller.stop()
        await transport.releasePoll()
        await poll.value
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertTrue(executor.executedTaskIds.isEmpty)
    }

    private func assertOldRepliesRespectEmergencyStop(stopSucceeds: Bool) async throws {
        let pollStarted = expectation(description: "old poll started")
        let heartbeatStarted = expectation(description: "old heartbeat started")
        let pendingHeartbeatStarted = expectation(description: "heartbeat while stop is unconfirmed")
        let stopStarted = expectation(description: "emergency stop started")
        let transport = OutOfOrderStopTransport(
            pollStarted: pollStarted, heartbeatStarted: heartbeatStarted,
            pendingHeartbeatStarted: pendingHeartbeatStarted, stopStarted: stopStarted,
            stopSucceeds: stopSucceeds
        )
        let executor = MockPokiExecutor()
        let controller = SitesBridgeController(
            store: InMemoryCredentialStore(), executor: executor, transport: transport
        )
        _ = try await controller.pair(
            sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil
        )
        let poll = Task { await controller.runSinglePollCycle() }
        await fulfillment(of: [pollStarted], timeout: 2)
        let oldHeartbeat = Task { await controller.markWokeFromSuspension() }
        await fulfillment(of: [heartbeatStarted], timeout: 2)

        let stop = Task { await controller.triggerOwnerEmergencyStop() }
        await fulfillment(of: [stopStarted], timeout: 2)
        let pendingHeartbeat = Task { await controller.markWokeFromSuspension() }
        await fulfillment(of: [pendingHeartbeatStarted], timeout: 2)
        await transport.releasePoll()
        await poll.value
        let afterPoll = await controller.snapshot()
        XCTAssertEqual(afterPoll.state, .emergencyStopped)
        XCTAssertTrue(executor.executedTaskIds.isEmpty)

        await transport.releaseStop()
        await stop.value
        await transport.releaseHeartbeat()
        await oldHeartbeat.value
        await transport.releasePendingHeartbeat()
        await pendingHeartbeat.value
        let afterOldHeartbeat = await controller.snapshot()
        XCTAssertEqual(afterOldHeartbeat.state, .emergencyStopped)

        await controller.markWokeFromSuspension()
        let afterFreshHeartbeat = await controller.snapshot()
        if stopSucceeds {
            XCTAssertEqual(afterFreshHeartbeat.state, .online)
        } else {
            XCTAssertEqual(afterFreshHeartbeat.state, .emergencyStopped)
            XCTAssertNotNil(afterFreshHeartbeat.lastError)
        }
    }

    func testOwnerApprovalDeniedWhenImmediateHeartbeatReportsCancellation() async throws {
        try await assertOwnerApproval(mode: "cancelled", expected: false)
    }

    func testOwnerApprovalAllowsCurrentRenewedLease() async throws {
        try await assertOwnerApproval(mode: "allowed", expected: true)
    }

    func testOwnerApprovalDeniedWhenHeartbeatFails() async throws {
        try await assertOwnerApproval(mode: "offline", expected: false)
    }

    private func assertOwnerApproval(mode: String, expected: Bool) async throws {
        let started = expectation(description: "Poki call started")
        let cancelled = expectation(description: "Poki call stopped")
        let executor = WaitingPokiExecutor(started: started, cancelled: cancelled)
        let transport = MockHTTPTransport()
        transport.handlers["/api/device/pair"] = { _, _ in
            (200, Data("{\"device_id\":\"dev_1\",\"device_token\":\"tok\",\"session_generation\":1,\"label\":\"lbl\",\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/poll"] = { _, _ in
            (200, Data("{\"task\":{\"task_id\":\"tsk_1\",\"tool_name\":\"do\",\"payload\":{\"actions\":[]},\"observation_id\":null,\"lease_token\":\"lease_1\",\"lease_expires_at\":9999999999999,\"expires_at\":9999999999999},\"cancel_task_ids\":[],\"emergency_stopped\":false,\"session_generation\":1,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        }
        transport.handlers["/api/device/heartbeat"] = { request, _ in
            let body = (try? JSONDecoder().decode([String: JSONValue].self, from: request.httpBody ?? Data())) ?? [:]
            let checksTask = body["active_task_id"]?.stringValue == "tsk_1"
            if checksTask && mode == "offline" {
                return (503, Data("{\"error\":{\"code\":\"OFFLINE\",\"message\":\"offline\"}}".utf8))
            }
            let cancelIds = checksTask && mode == "cancelled" ? "[\"tsk_1\"]" : "[]"
            let renewed = checksTask ? "true" : "false"
            let response = "{\"session_generation\":1,\"emergency_stopped\":false,\"cancel_task_ids\":\(cancelIds),\"lease_renewed\":\(renewed),\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}"
            return (200, Data(response.utf8))
        }
        transport.handlers["/api/device/result"] = { _, _ in
            (200, Data("{\"accepted\":true,\"task_status\":\"awaiting_approval\",\"observation_id\":null}".utf8))
        }
        let controller = SitesBridgeController(
            store: InMemoryCredentialStore(), executor: executor, transport: transport
        )
        _ = try await controller.pair(
            sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil
        )
        let cycle = Task { await controller.runSinglePollCycle() }
        await fulfillment(of: [started], timeout: 2)
        await controller.reportPendingApproval(PendingApprovalDTO(
            id: "approval_1", app: "Example", summary: "Confirm", reason: "Payment", expires_at: nil
        ))
        let wrongApproval = await controller.canApplyOwnerApproval(id: "different")
        XCTAssertFalse(wrongApproval)
        let accepted = await controller.canApplyOwnerApproval(id: "approval_1")
        XCTAssertEqual(accepted, expected)
        await controller.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        await cycle.value
    }
}

private actor OutOfOrderStopTransport: HTTPTransporting {
    private let pollStarted: XCTestExpectation
    private let heartbeatStarted: XCTestExpectation
    private let pendingHeartbeatStarted: XCTestExpectation
    private let stopStarted: XCTestExpectation
    private let stopSucceeds: Bool
    private var pollWaiter: CheckedContinuation<Void, Never>?
    private var heartbeatWaiter: CheckedContinuation<Void, Never>?
    private var pendingHeartbeatWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var heartbeatCount = 0

    init(
        pollStarted: XCTestExpectation, heartbeatStarted: XCTestExpectation, pendingHeartbeatStarted: XCTestExpectation,
        stopStarted: XCTestExpectation, stopSucceeds: Bool
    ) {
        self.pollStarted = pollStarted
        self.heartbeatStarted = heartbeatStarted
        self.pendingHeartbeatStarted = pendingHeartbeatStarted
        self.stopStarted = stopStarted
        self.stopSucceeds = stopSucceeds
    }

    func send(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        switch request.url?.path {
        case "/api/device/pair":
            return (200, Data("{\"device_id\":\"dev_1\",\"device_token\":\"tok\",\"session_generation\":1,\"label\":\"lbl\",\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        case "/api/device/poll":
            pollStarted.fulfill()
            await withCheckedContinuation { pollWaiter = $0 }
            return (200, Data("{\"task\":{\"task_id\":\"old_task\",\"tool_name\":\"do\",\"payload\":{\"actions\":[]},\"observation_id\":null,\"lease_token\":\"lease\",\"lease_expires_at\":9999999999999,\"expires_at\":9999999999999},\"cancel_task_ids\":[],\"emergency_stopped\":false,\"session_generation\":1,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        case "/api/device/heartbeat":
            heartbeatCount += 1
            if heartbeatCount == 2 {
                heartbeatStarted.fulfill()
                await withCheckedContinuation { heartbeatWaiter = $0 }
            } else if heartbeatCount == 3 {
                pendingHeartbeatStarted.fulfill()
                await withCheckedContinuation { pendingHeartbeatWaiter = $0 }
            }
            return (200, Data("{\"session_generation\":1,\"emergency_stopped\":false,\"cancel_task_ids\":[],\"lease_renewed\":false,\"poll_config\":{\"wait_ms\":100,\"delay_ms\":50,\"mode\":\"active\"}}".utf8))
        case "/api/device/cancel":
            stopStarted.fulfill()
            await withCheckedContinuation { stopWaiter = $0 }
            if stopSucceeds {
                return (200, Data("{\"acknowledged\":true,\"emergency_stopped\":true,\"cancelled_count\":1}".utf8))
            }
            return (503, Data("{\"error\":{\"code\":\"OFFLINE\",\"message\":\"offline\"}}".utf8))
        default:
            return (404, Data("{}".utf8))
        }
    }

    func releasePoll() { pollWaiter?.resume(); pollWaiter = nil }
    func releaseHeartbeat() { heartbeatWaiter?.resume(); heartbeatWaiter = nil }
    func releasePendingHeartbeat() { pendingHeartbeatWaiter?.resume(); pendingHeartbeatWaiter = nil }
    func releaseStop() { stopWaiter?.resume(); stopWaiter = nil }
}

private actor WaitingPokiExecutor: PokiCoreExecuting {
    private let started: XCTestExpectation
    private let cancelled: XCTestExpectation

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func currentRunnerState() async -> String { "automationReady" }

    func execute(task: ClaimedTaskDTO) async -> PokiToolReply {
        started.fulfill()
        do {
            try await Task.sleep(for: .seconds(30))
            return PokiToolReply(text: "unexpected completion")
        } catch {
            cancelled.fulfill()
            return PokiToolReply(
                text: "app: Example\ndid: swipe up (sent, 30 ms)\nerror: cancelled before action 2",
                screenshotJPEG: Data([0xFF, 0xD8]),
                isError: true
            )
        }
    }

    func cancelActiveTask(taskId: String) async {}
}
