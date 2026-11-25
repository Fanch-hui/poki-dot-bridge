import Foundation
import XCTest
@testable import PokiSitesBridge

private final class SimulatedPokiCoreExecutor: PokiCoreExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var appName = "Home Screen"
    private var shopPage = 0

    func currentRunnerState() async -> String {
        "automationReady"
    }

    func execute(task: ClaimedTaskDTO) async -> PokiToolReply {
        let jpegB64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
        let jpeg = Data(base64Encoded: jpegB64)!

        let adapter = PokiCoreJSONRPCAdapter(
            connectorId: "live-wire-test",
            stateReader: { "automationReady" },
            rpcHandler: { [weak self] body, _ in
                guard let self else { return (500, "{}") }
                let data = Data(body.utf8)
                let root = try! JSONDecoder().decode([String: JSONValue].self, from: data)
                let id = root["id"]?.stringValue ?? "1"
                let params = root["params"]?.objectValue ?? [:]
                let tool = params["name"]?.stringValue ?? "look"
                let args = params["arguments"]?.objectValue ?? [:]

                let actions = tool == "do" ? args["actions"]?.arrayValue ?? [] : []
                let text = self.lock.withLock { self.screen(after: actions) }
                let replyObj: [String: JSONValue] = [
                    "jsonrpc": .string("2.0"),
                    "id": .string(id),
                    "result": .object([
                        "content": .array([
                            .object(["type": .string("text"), "text": .string(text)]),
                            .object([
                                "type": .string("image"),
                                "data": .string(jpeg.base64EncodedString()),
                                "mimeType": .string("image/jpeg"),
                            ]),
                        ]),
                        "isError": .bool(false),
                    ]),
                ]
                return (200, JSONValue.object(replyObj).jsonString())
            }
        )
        return await adapter.execute(task: task)
    }

    private func screen(after actions: [JSONValue]) -> String {
        if let launch = actions.first?.objectValue?["launch"]?.stringValue {
            appName = launch
            shopPage = 0
        }
        var lines = ["app: \(appName)   read: 2026-11-22T08:00:00Z (42 ms)",
                     "viewport: 402x874 points", "screen_changed: true"]
        if appName != "DemoShop" {
            return (lines + ["elements (2):", "1 Button \"Wi-Fi\" [16,120,370,44]",
                             "2 StaticText \"\(appName) Ready\" [16,180,260,32]"]).joined(separator: "\n")
        }
        lines.append("bundle_id: com.example.shop")
        if let first = actions.first?.objectValue {
            switch (shopPage, first["tap"]?.intValue, first["type"]?.stringValue, first["ref"]?.intValue) {
            case (0, 3, nil, nil):
                shopPage = 1
                lines += ["did: tap Shop (sent, 10 ms)", "did: wait_until: \"点菜\" appeared after 15 ms (sent, 15 ms)"]
            case (1, 17, nil, nil):
                shopPage = 2
                lines += ["did: tap Search (sent, 10 ms)", "did: wait_until: \"请输入商品名\" appeared after 15 ms (sent, 15 ms)"]
            case (2, nil, "tea", 29):
                shopPage = 3
                lines += ["did: type query (sent, 10 ms)", "did: wait_until: result \"Tea result\" appeared after 15 ms (sent, 15 ms)"]
            default:
                break
            }
        }
        let pages = [
            ["3 Cell \"Shop\" [16,250,370,44]"],
            ["11 StaticText \"点菜\" [16,140,200,32]", "17 Button \"搜索\" [300,100,84,44]"],
            ["29 TextField \"请输入商品名\" [16,100,290,44]"],
            ["41 Cell \"Tea result\" [16,140,370,44]"],
        ]
        return (lines + ["elements (\(pages[shopPage].count)):"] + pages[shopPage]).joined(separator: "\n")
    }

    func cancelActiveTask(taskId: String) async {}
}

final class LiveServerWireTests: XCTestCase {
    func testSwiftControllerPairsPollsAndExecutesOverRealHTTPLoopback() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["POKI_LIVE_TEST_URL"],
              let code = env["POKI_LIVE_TEST_CODE"] else {
            throw XCTSkip("POKI_LIVE_TEST_URL / POKI_LIVE_TEST_CODE not set; run via scripts/test-swift-live-wire.ts")
        }

        let store = InMemoryCredentialStore()
        let executor = SimulatedPokiCoreExecutor()
        let controller = SitesBridgeController(
            config: SitesBridgeConfig(appVersion: "1.0.13", defaultPollWaitMs: 1_500, heartbeatIntervalSeconds: 2),
            store: store,
            executor: executor,
            transport: URLSessionHTTPTransport(),
            onAutomationFinish: { true }
        )

        let creds = try await controller.pair(
            sitesURL: url,
            pairingCode: code,
            deviceName: "Swift Live Wire iPhone",
            siwcBypassToken: env["POKI_LIVE_TEST_SIWC"]
        )
        XCTAssertFalse(creds.deviceId.isEmpty)
        XCTAssertFalse(creds.deviceToken.isEmpty)

        await controller.start()
        let durationNs = UInt64((Double(env["POKI_LIVE_TEST_SECONDS"] ?? "6") ?? 6.0) * 1_000_000_000)
        try await Task.sleep(nanoseconds: durationNs)
        await controller.stop()

        let finalSnap = await controller.snapshot()
        XCTAssertNotEqual(finalSnap.state, .unpaired)
        XCTAssertEqual(finalSnap.pendingOutboxCount, 0)
    }
}
