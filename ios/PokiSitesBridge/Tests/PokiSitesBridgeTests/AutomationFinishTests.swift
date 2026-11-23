import XCTest
@testable import PokiSitesBridge

final class AutomationFinishTests: XCTestCase {
    private struct Step: Sendable {
        let id: String
        let after: String?
        let cancelled: Bool

        init(_ id: String, after: String? = nil, cancelled: Bool = false) {
            self.id = id
            self.after = after
            self.cancelled = cancelled
        }
    }

    private actor StandbyRecorder {
        private(set) var count = 0

        func request() -> Bool {
            count += 1
            return true
        }
    }

    func testOnlyLatestCompletedWorkflowCanRequestStandbyOnce() async throws {
        let steps = [
            Step("first"), Step("last"), Step("old-finish", after: "first"),
            Step("cancelled-finish", after: "last", cancelled: true),
            Step("finish", after: "last"), Step("replayed-finish", after: "last"), Step("next"),
        ]
        let executor = MockPokiExecutor()
        let recorder = StandbyRecorder()
        let transport = try await run(steps, executor: executor, recorder: recorder)

        let count = await recorder.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(executor.executedTaskIds, ["first", "last", "next"])
        let results = try finishResults(transport)
        XCTAssertEqual(results.map { $0["status"] as? String }, ["cancelled", "cancelled", "succeeded", "cancelled"])
        XCTAssertTrue(results.allSatisfy { $0["observation"] == nil && $0["action_receipts"] == nil })
        XCTAssertEqual(results[2]["summary"] as? String, "Poki requested automation standby.")
    }

    func testWaitingForApprovalCannotAnchorStandby() async throws {
        let executor = MockPokiExecutor { _ in
            PokiToolReply(text: "not_sent from action 1: approval_required (id approval1)", isError: false)
        }
        let recorder = StandbyRecorder()
        let transport = try await run([Step("payment"), Step("finish", after: "payment")],
                                      executor: executor, recorder: recorder)
        let count = await recorder.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try finishResults(transport).first?["status"] as? String, "cancelled")
    }

    private func run(_ steps: [Step], executor: MockPokiExecutor, recorder: StandbyRecorder) async throws -> MockHTTPTransport {
        let transport = MockHTTPTransport()
        let pollConfig = #"{"wait_ms":0,"delay_ms":0,"mode":"active"}"#
        transport.handlers["/api/device/pair"] = { _, _ in
            (200, Data(#"{"device_id":"dev_1","device_token":"test","session_generation":1,"label":"lbl","poll_config":\#(pollConfig)}"#.utf8))
        }
        transport.handlers["/api/device/poll"] = { _, attempt in
            let step = steps[attempt - 1]
            let tool = step.after == nil ? "do" : "stop"
            let payload = step.after.map { #"{"after_task_id":"\#($0)"}"# } ?? "{}"
            let cancels = step.cancelled ? #"["\#(step.id)"]"# : "[]"
            let task = #"{"task_id":"\#(step.id)","tool_name":"\#(tool)","payload":\#(payload),"lease_token":"test","lease_expires_at":9999999999999,"expires_at":9999999999999}"#
            return (200, Data(#"{"task":\#(task),"cancel_task_ids":\#(cancels),"emergency_stopped":false,"session_generation":1,"poll_config":\#(pollConfig)}"#.utf8))
        }
        transport.handlers["/api/device/result"] = { _, _ in
            (200, Data(#"{"accepted":true,"task_status":"succeeded"}"#.utf8))
        }
        let controller = SitesBridgeController(store: InMemoryCredentialStore(), executor: executor, transport: transport,
                                               onAutomationFinish: { await recorder.request() })
        _ = try await controller.pair(sitesURL: "https://poki-test.chatgpt.site", pairingCode: "ABCD-EFGH-2345", deviceName: nil)
        for _ in steps { await controller.runSinglePollCycle() }
        for poll in transport.requests where poll.path == "/api/device/poll" {
            XCTAssertEqual(try decode(poll.body)["supports_task_finish"] as? Bool, true)
        }
        return transport
    }

    private func finishResults(_ transport: MockHTTPTransport) throws -> [[String: Any]] {
        try transport.requests.filter { $0.path == "/api/device/result" }.map { try decode($0.body) }
            .filter { ($0["task_id"] as? String)?.contains("finish") == true }
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
