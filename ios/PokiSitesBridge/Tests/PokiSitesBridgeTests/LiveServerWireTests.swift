import Foundation
import XCTest
@testable import PokiSitesBridge

private final class SimulatedPokiCoreExecutor: PokiCoreExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var appName = "Home Screen"

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

                if tool == "do",
                   let actions = args["actions"]?.arrayValue,
                   let first = actions.first?.objectValue,
                   let launchTarget = first["launch"]?.stringValue {
                    self.lock.withLock { self.appName = launchTarget }
                }

                let currentApp = self.lock.withLock { self.appName }
                let text = """
                app: \(currentApp)   read: 2026-11-22T08:00:00Z (42 ms)
                screenshot: 402 px wide, 1 px = 1 screen point
                screen_changed: true (the elements changed)
                elements (2):
                +1 Button "Wi-Fi = On" [16,120,370,44]
                2 StaticText "\(currentApp) Ready" [16,180,260,32]
                """
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
            config: SitesBridgeConfig(defaultPollWaitMs: 1_500, heartbeatIntervalSeconds: 2),
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
