import Foundation

public struct PokiToolReply: Sendable, Equatable {
    public var text: String
    public var screenshotJPEG: Data?
    public var isError: Bool

    public init(text: String, screenshotJPEG: Data? = nil, isError: Bool = false) {
        self.text = text
        self.screenshotJPEG = screenshotJPEG
        self.isError = isError
    }
}

public protocol PokiCoreExecuting: Sendable {
    func currentRunnerState() async -> String
    func execute(task: ClaimedTaskDTO) async -> PokiToolReply
    func cancelActiveTask(taskId: String) async
}

/// Maps upstream Poki `RunnerStatus.state` values into the strict `RUNNER_STATES` enum enforced by Sites schemas.
public enum PokiRunnerStateMapper {
    private static let allowed: Set<String> = [
        "unknown",
        "idle",
        "starting",
        "running",
        "automationReady",
        "awaitingAuthorization",
        "declined",
        "failed",
    ]

    public static func normalize(
        _ raw: String,
        awaitingAuthorization: Bool = false,
        declined: Bool = false,
        inProcessReady: Bool = false
    ) -> String {
        if declined { return "declined" }
        if awaitingAuthorization { return "awaitingAuthorization" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "idle":
            return "idle"
        case "standby", "connecting", "pairing", "tunnel", "mounting_ddi", "launching", "waiting_network", "starting":
            return "starting"
        case "running":
            return inProcessReady ? "automationReady" : "running"
        default:
            return allowed.contains(trimmed) ? trimmed : "unknown"
        }
    }
}

/// Bridges Sites tasks into PokiCore's standard MCP `handle(RelayRequest)` JSON-RPC entrypoint,
/// preserving PokiCore's approvals, Live Activity, Humanize, and Dynamic Island safeguards untouched.
public final class PokiCoreJSONRPCAdapter: PokiCoreExecuting, @unchecked Sendable {
    public typealias RPCHandler = @Sendable (_ requestBodyJSON: String, _ connectorHeader: String) async -> (status: Int, body: String)
    public typealias SessionRPCHandler = @Sendable (_ requestBodyJSON: String, _ headers: [String: String]) async -> (status: Int, headers: [String: String], body: String)
    public typealias RunnerStateReader = @Sendable () async -> String

    private let sessionRPCHandler: SessionRPCHandler
    private let stateReader: RunnerStateReader
    private let connectorId: String
    private let enableSessionHandshake: Bool
    private let lock = NSLock()
    private var mcpSessionId: String?

    public var currentSessionId: String? { lock.withLock { mcpSessionId } }

    public init(
        connectorId: String = "sites-bridge",
        stateReader: @escaping RunnerStateReader,
        rpcHandler: @escaping RPCHandler
    ) {
        self.connectorId = connectorId
        self.enableSessionHandshake = false
        self.stateReader = stateReader
        self.sessionRPCHandler = { body, headers in
            let headerVal = headers["x-poki-connector"] ?? connectorId
            let res = await rpcHandler(body, headerVal)
            return (res.status, [:], res.body)
        }
    }

    public init(
        connectorId: String = "chatgpt-dot-sites",
        enableSessionHandshake: Bool = true,
        stateReader: @escaping RunnerStateReader,
        sessionRPCHandler: @escaping SessionRPCHandler
    ) {
        self.connectorId = connectorId
        self.enableSessionHandshake = enableSessionHandshake
        self.stateReader = stateReader
        self.sessionRPCHandler = sessionRPCHandler
    }

    public func currentRunnerState() async -> String {
        PokiRunnerStateMapper.normalize(await stateReader())
    }

    public func execute(task: ClaimedTaskDTO) async -> PokiToolReply {
        let pokiToolName = task.tool_name == "status" ? "status" : (task.tool_name == "do" ? "do" : "look")
        let wantScreenshot = task.payload["want_screenshot"]?.boolValue ?? true
        let cleanArgs = Self.sanitizeArguments(toolName: pokiToolName, payload: task.payload)

        if enableSessionHandshake {
            await ensureInitializedSession()
        }
        guard !Task.isCancelled else {
            return PokiToolReply(text: "cancelled: nothing was sent", isError: true)
        }

        var reqHeaders: [String: String] = ["x-poki-connector": connectorId]
        if let sid = currentSessionId {
            reqHeaders["mcp-session-id"] = sid
        }

        let rpcPayload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string(task.task_id),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string(pokiToolName),
                "arguments": .object(cleanArgs),
            ]),
        ]
        let reqBody = JSONValue.object(rpcPayload).jsonString()
        let (_, resHeaders, body) = await sessionRPCHandler(reqBody, reqHeaders)
        captureSessionId(from: resHeaders)

        var reply = Self.decodeToolReply(jsonText: body)
        if !wantScreenshot {
            reply.screenshotJPEG = nil
        }
        return reply
    }

    public func cancelActiveTask(taskId: String) async {
        // SitesBridgeController cancels the Swift task running execute(task:).
    }

    /// Drops Sites-only fields (`want_screenshot`, etc.) because PokiCore schemas enforce `additionalProperties: false`.
    public static func sanitizeArguments(toolName: String, payload: [String: JSONValue]) -> [String: JSONValue] {
        switch toolName {
        case "status":
            return [:]
        case "look":
            var out: [String: JSONValue] = [:]
            if let v = payload["full"] { out["full"] = v }
            if let v = payload["pane"] { out["pane"] = v }
            return out
        case "do":
            var out: [String: JSONValue] = [
                "actions": payload["actions"] ?? .array([]),
            ]
            if let v = payload["full"] { out["full"] = v }
            if let v = payload["finish"] { out["finish"] = v }
            if let v = payload["app"] { out["app"] = v }
            return out
        default:
            return payload
        }
    }

    private func ensureInitializedSession() async {
        if currentSessionId != nil { return }
        let initPayload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string("init_\(UUID().uuidString.lowercased())"),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2025-06-18"),
                "clientInfo": .object([
                    "name": .string("Dot (ChatGPT Sites)"),
                    "version": .string("1.0.0"),
                ]),
            ]),
        ]
        let (_, headers, _) = await sessionRPCHandler(
            JSONValue.object(initPayload).jsonString(),
            ["x-poki-connector": connectorId]
        )
        captureSessionId(from: headers)
    }

    private func captureSessionId(from headers: [String: String]) {
        guard let sid = headers.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value,
              !sid.isEmpty else {
            return
        }
        lock.withLock { mcpSessionId = sid }
    }

    public static func decodeToolReply(jsonText: String) -> PokiToolReply {
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return PokiToolReply(text: "error: invalid JSON-RPC reply from PokiCore", isError: true)
        }
        if let err = root["error"]?.objectValue {
            let msg = err["message"]?.stringValue ?? "PokiCore JSON-RPC error"
            return PokiToolReply(text: "error: \(msg)", isError: true)
        }
        let result = root["result"]?.objectValue ?? [:]
        let isError = result["isError"]?.boolValue ?? false
        let content = result["content"]?.arrayValue ?? []
        var texts: [String] = []
        var jpeg: Data?
        for item in content {
            guard let obj = item.objectValue else { continue }
            if obj["type"]?.stringValue == "text", let t = obj["text"]?.stringValue {
                texts.append(t)
            } else if obj["type"]?.stringValue == "image",
                      let b64 = obj["data"]?.stringValue,
                      let decoded = Data(base64Encoded: b64) {
                jpeg = decoded
            }
        }
        return PokiToolReply(text: texts.joined(separator: "\n"), screenshotJPEG: jpeg, isError: isError)
    }
}

/// Deterministic mock executor for Swift package unit and controller tests.
public final class MockPokiExecutor: PokiCoreExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var runnerState = "automationReady"
    private var handler: @Sendable (ClaimedTaskDTO) -> PokiToolReply
    public private(set) var executedTaskIds: [String] = []
    public private(set) var cancelledTaskIds: [String] = []

    public init(
        runnerState: String = "automationReady",
        handler: @escaping @Sendable (ClaimedTaskDTO) -> PokiToolReply = { _ in
            PokiToolReply(
                text: "app: Settings   read: 2026-11-22T07:00:00Z (120 ms)\nscreenshot: 402 px wide, 1 px = 1 screen point\nelements (1):\n 1 StaticText \"Wi-Fi\" [16,120,200,32]",
                screenshotJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                isError: false
            )
        }
    ) {
        self.runnerState = runnerState
        self.handler = handler
    }

    public func setRunnerState(_ value: String) {
        lock.withLock { runnerState = value }
    }

    public func currentRunnerState() async -> String {
        PokiRunnerStateMapper.normalize(lock.withLock { runnerState })
    }

    public func execute(task: ClaimedTaskDTO) async -> PokiToolReply {
        lock.withLock { executedTaskIds.append(task.task_id) }
        return handler(task)
    }

    public func cancelActiveTask(taskId: String) async {
        lock.withLock { cancelledTaskIds.append(taskId) }
    }
}
