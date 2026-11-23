import XCTest
@testable import PokiSitesBridge

private actor WakePollingTransport: HTTPTransporting {
    private let firstPoll: XCTestExpectation
    private let nextPoll: XCTestExpectation
    private let holdFirstPoll: Bool
    private var firstPollRelease: CheckedContinuation<Void, Never>?
    private var pollCount = 0
    private var activePolls = 0
    private var peakActivePolls = 0

    init(firstPoll: XCTestExpectation, nextPoll: XCTestExpectation, holdFirstPoll: Bool) {
        self.firstPoll = firstPoll
        self.nextPoll = nextPoll
        self.holdFirstPoll = holdFirstPoll
    }

    func send(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        let pollConfig = #"{"wait_ms":0,"delay_ms":10000,"mode":"idle"}"#
        switch request.url?.path {
        case "/api/device/pair":
            let body = #"{"device_id":"dev_1","device_token":"tok","session_generation":1,"label":"lbl","poll_config":\#(pollConfig)}"#
            return (200, Data(body.utf8))
        case "/api/device/heartbeat":
            let body = #"{"session_generation":1,"emergency_stopped":false,"cancel_task_ids":[],"lease_renewed":false,"poll_config":\#(pollConfig)}"#
            return (200, Data(body.utf8))
        case "/api/device/poll":
            pollCount += 1
            let count = pollCount
            activePolls += 1
            peakActivePolls = max(peakActivePolls, activePolls)
            defer { activePolls -= 1 }
            if count == 1 {
                firstPoll.fulfill()
                if holdFirstPoll {
                    await withCheckedContinuation { firstPollRelease = $0 }
                }
            } else if count == 2 {
                nextPoll.fulfill()
            }
            let body = #"{"task":null,"cancel_task_ids":[],"emergency_stopped":false,"session_generation":1,"poll_config":\#(pollConfig)}"#
            return (200, Data(body.utf8))
        default:
            return (404, Data("{}".utf8))
        }
    }

    func releaseFirstPoll() {
        firstPollRelease?.resume()
        firstPollRelease = nil
    }

    func maximumConcurrentPolls() -> Int { peakActivePolls }
}

final class LifecycleAndRetryTests: XCTestCase {
    #if canImport(Network)
    func testNetworkMonitorCanRestart() async {
        let first = expectation(description: "initial network path")
        let second = expectation(description: "network path after restart")
        first.assertForOverFulfill = false
        second.assertForOverFulfill = false
        let monitor = SystemNetworkPathMonitor()
        monitor.start { _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 3)
        monitor.stop()
        monitor.start { _ in second.fulfill() }
        await fulfillment(of: [second], timeout: 3)
        monitor.stop()
    }
    #endif

    func testForegroundWakeInterruptsIdlePollDelay() async throws {
        let first = expectation(description: "background poll completed")
        let next = expectation(description: "poll resumed promptly")
        let transport = WakePollingTransport(firstPoll: first, nextPoll: next, holdFirstPoll: false)
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(heartbeatIntervalSeconds: 60),
            store: InMemoryCredentialStore(),
            executor: MockPokiExecutor(),
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.updateLifecycle(foreground: false)
        await controller.start()
        await fulfillment(of: [first], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        await controller.markWokeFromSuspension()
        await fulfillment(of: [next], timeout: 1)
        let peak = await transport.maximumConcurrentPolls()
        XCTAssertEqual(peak, 1)
        await controller.stop()
    }

    func testForegroundWakeDuringPollPreservesSingleFlight() async throws {
        let first = expectation(description: "background poll started")
        let next = expectation(description: "next poll started after wake")
        let transport = WakePollingTransport(firstPoll: first, nextPoll: next, holdFirstPoll: true)
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(heartbeatIntervalSeconds: 60),
            store: InMemoryCredentialStore(),
            executor: MockPokiExecutor(),
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.updateLifecycle(foreground: false)
        await controller.start()
        await fulfillment(of: [first], timeout: 1)
        await controller.markWokeFromSuspension()
        await transport.releaseFirstPoll()
        await fulfillment(of: [next], timeout: 1)
        let peak = await transport.maximumConcurrentPolls()
        XCTAssertEqual(peak, 1)
        await controller.stop()
    }

    func testNetworkSwitchInterruptsIdlePollDelay() async throws {
        let first = expectation(description: "wifi poll completed")
        let next = expectation(description: "cellular poll resumed promptly")
        let transport = WakePollingTransport(firstPoll: first, nextPoll: next, holdFirstPoll: false)
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(heartbeatIntervalSeconds: 60),
            store: InMemoryCredentialStore(),
            executor: MockPokiExecutor(),
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.updateLifecycle(foreground: false)
        await controller.handleNetworkChange(.wifi)
        await controller.start()
        await fulfillment(of: [first], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        await controller.handleNetworkChange(.cellular)
        await fulfillment(of: [next], timeout: 1)
        let peak = await transport.maximumConcurrentPolls()
        XCTAssertEqual(peak, 1)
        await controller.stop()
    }

    func testNetworkSwitchDuringPollPreservesSingleFlight() async throws {
        let first = expectation(description: "wifi poll started")
        let next = expectation(description: "cellular poll after wifi poll completed")
        let transport = WakePollingTransport(firstPoll: first, nextPoll: next, holdFirstPoll: true)
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(heartbeatIntervalSeconds: 60),
            store: InMemoryCredentialStore(),
            executor: MockPokiExecutor(),
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.updateLifecycle(foreground: false)
        await controller.handleNetworkChange(.wifi)
        await controller.start()
        await fulfillment(of: [first], timeout: 1)
        await controller.handleNetworkChange(.cellular)
        await transport.releaseFirstPoll()
        await fulfillment(of: [next], timeout: 1)
        let peak = await transport.maximumConcurrentPolls()
        XCTAssertEqual(peak, 1)
        await controller.stop()
    }

    func testUnlockInterruptsLockedPollDelay() async throws {
        let first = expectation(description: "locked poll completed")
        let next = expectation(description: "unlocked poll resumed promptly")
        let transport = WakePollingTransport(firstPoll: first, nextPoll: next, holdFirstPoll: false)
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(heartbeatIntervalSeconds: 60),
            store: InMemoryCredentialStore(),
            executor: MockPokiExecutor(),
            transport: transport
        )
        _ = try await controller.pair(sitesURL: "http://127.0.0.1:3000", pairingCode: "1111-2222-3333", deviceName: nil)
        await controller.updateLifecycle(foreground: false)
        await controller.setScreenLocked(true)
        await controller.start()
        await fulfillment(of: [first], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        await controller.setScreenLocked(false)
        await fulfillment(of: [next], timeout: 1)
        let peak = await transport.maximumConcurrentPolls()
        XCTAssertEqual(peak, 1)
        await controller.stop()
    }

    func testAllSevenLifecycleTransitionsAndPollCadence() {
        let store = InMemoryCredentialStore()
        let coordinator = DeviceLifecycleCoordinator(store: store)
        let serverPoll = PollConfigDTO(wait_ms: 10_000, delay_ms: 150, mode: "active")

        // 1. Cold relaunch triggers reset_session once
        XCTAssertTrue(coordinator.consumeResetSessionFlag())
        XCTAssertFalse(coordinator.consumeResetSessionFlag())

        // 2. Foreground active
        coordinator.markForeground()
        XCTAssertEqual(coordinator.current.lifecycle, .foreground)
        XCTAssertEqual(coordinator.effectivePollWaitMs(serverConfig: serverPoll, defaultWaitMs: 10_000), 10_000)

        // 3. Background caps wait
        coordinator.markBackground()
        XCTAssertEqual(coordinator.current.lifecycle, .background)
        XCTAssertEqual(coordinator.effectivePollWaitMs(serverConfig: serverPoll, defaultWaitMs: 10_000), 5_000)

        // 4. Screen locked sets wait_ms = 0
        coordinator.setScreenLocked(true)
        XCTAssertEqual(coordinator.current.lifecycle, .locked)
        XCTAssertEqual(coordinator.effectivePollWaitMs(serverConfig: serverPoll, defaultWaitMs: 10_000), 0)
        coordinator.setScreenLocked(false)
        XCTAssertEqual(coordinator.current.lifecycle, .foreground)

        // 5. Wi-Fi -> Cellular -> Offline handover
        XCTAssertTrue(coordinator.updateNetwork(.wifi))
        XCTAssertTrue(coordinator.updateNetwork(.cellular))
        XCTAssertTrue(coordinator.updateNetwork(.offline))
        XCTAssertEqual(coordinator.effectivePollWaitMs(serverConfig: serverPoll, defaultWaitMs: 10_000), 0)
        XCTAssertEqual(coordinator.effectivePollDelaySeconds(serverConfig: serverPoll), 5.0)
        XCTAssertTrue(coordinator.updateNetwork(.cellular))

        // 6. System suspension -> wake
        coordinator.markSuspended()
        XCTAssertEqual(coordinator.current.lifecycle, .suspended)
        XCTAssertEqual(coordinator.effectivePollDelaySeconds(serverConfig: serverPoll), 15.0)
        coordinator.markWokeFromSuspension()
        XCTAssertEqual(coordinator.current.lifecycle, .foreground)
    }

    func testOutboxPersistsAcrossRestartUntilDelivered() throws {
        let store = InMemoryCredentialStore()
        let coord1 = DeviceLifecycleCoordinator(store: store)
        let pending = ResultRequestDTO(
            task_id: "tsk_offline_1",
            lease_token: "lease_1",
            status: "succeeded",
            summary: "ok",
            raw_text: "app: Notes",
            error_code: nil,
            error_message: nil,
            uncertain_execution: false,
            action_receipts: nil,
            approval_required: nil,
            handoff_required: nil,
            finished_app_return: false,
            observation: nil,
            runner_state: "automationReady"
        )
        coord1.queueOutboxResult(pending)
        XCTAssertEqual(coord1.pendingOutboxCount, 1)

        // Simulated cold restart reading same CredentialStoring
        let coord2 = DeviceLifecycleCoordinator(store: store)
        XCTAssertEqual(coord2.pendingOutboxCount, 1)
        XCTAssertEqual(coord2.takeOutboxBatch().first?.task_id, "tsk_offline_1")
        coord2.markOutboxDelivered(taskId: "tsk_offline_1")
        XCTAssertEqual(coord2.pendingOutboxCount, 0)
    }
}
