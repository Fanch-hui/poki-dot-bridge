import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

public struct PollConfigDTO: Sendable, Equatable, Codable {
    public var wait_ms: Int
    public var delay_ms: Int
    public var mode: String

    public init(wait_ms: Int, delay_ms: Int, mode: String) {
        self.wait_ms = wait_ms
        self.delay_ms = delay_ms
        self.mode = mode
    }
}

public struct PairRequestDTO: Sendable, Encodable {
    public var pairing_code: String
    public var label: String
    public var public_key_b64: String
    public var proof_sig_b64: String
    public var timestamp: Int
    public var nonce: String
    public var device_name: String?
    public var app_version: String?
    public var ios_version: String?
    public var capabilities: [String: JSONValue]?
}

public struct PairResponseDTO: Sendable, Decodable, Equatable {
    public var device_id: String
    public var device_token: String
    public var session_generation: Int
    public var label: String
    public var poll_config: PollConfigDTO
}

public struct PollRequestDTO: Sendable, Encodable {
    public var wait_ms: Int
    public var runner_state: String
    public var network_state: String
    public var app_lifecycle_state: String
    public var screen_locked: Bool
    public var supports_task_finish: Bool? = nil
}

public struct ClaimedTaskDTO: Sendable, Decodable, Equatable {
    public var task_id: String
    public var tool_name: String
    public var payload: [String: JSONValue]
    public var observation_id: String?
    public var lease_token: String
    public var lease_expires_at: Int64
    public var expires_at: Int64
}

public struct PollResponseDTO: Sendable, Decodable, Equatable {
    public var task: ClaimedTaskDTO?
    public var cancel_task_ids: [String]
    public var emergency_stopped: Bool
    public var session_generation: Int
    public var poll_config: PollConfigDTO
}

public struct ScreenElementDTO: Sendable, Codable, Equatable {
    public var ref: Int
    public var type: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var frame: [Double]
    public var flags: [String]?
    public var from_picture: Bool?
    public var change: String?
}

public struct ActionReceiptDTO: Sendable, Codable, Equatable {
    public var index: Int
    public var kind: String
    public var status: String
    public var detail: String?
}

public struct PendingApprovalDTO: Sendable, Codable, Equatable {
    public var id: String
    public var app: String?
    public var summary: String
    public var reason: String
    public var expires_at: Int64?

    public init(id: String, app: String? = nil, summary: String, reason: String, expires_at: Int64? = nil) {
        self.id = id
        self.app = app
        self.summary = summary
        self.reason = reason
        self.expires_at = expires_at
    }
}

public struct PendingHandoffDTO: Sendable, Codable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var app: String?
    public var requested_at: Int64?

    public init(id: String, kind: String, text: String, app: String? = nil, requested_at: Int64? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.app = app
        self.requested_at = requested_at
    }
}

public struct ObservationPayloadDTO: Sendable, Codable, Equatable {
    public var observation_id: String?
    public var app_bundle_id: String?
    public var app_name: String?
    public var screen_width: Double?
    public var screen_height: Double?
    public var coordinate_unit: String
    public var screen_locked: Bool
    public var screen_changed: Bool?
    public var screen_hash: String?
    public var elements: [ScreenElementDTO]
    public var visible_text: String
    public var raw_text: String
    public var notes: [String]
    public var screenshot_base64: String?
    public var screenshot_mime: String

    public init(
        observation_id: String? = nil,
        app_bundle_id: String? = nil,
        app_name: String? = nil,
        screen_width: Double? = nil,
        screen_height: Double? = nil,
        coordinate_unit: String = "points",
        screen_locked: Bool = false,
        screen_changed: Bool? = nil,
        screen_hash: String? = nil,
        elements: [ScreenElementDTO] = [],
        visible_text: String = "",
        raw_text: String = "",
        notes: [String] = [],
        screenshot_base64: String? = nil,
        screenshot_mime: String = "image/jpeg"
    ) {
        self.observation_id = observation_id
        self.app_bundle_id = app_bundle_id
        self.app_name = app_name
        self.screen_width = screen_width
        self.screen_height = screen_height
        self.coordinate_unit = coordinate_unit
        self.screen_locked = screen_locked
        self.screen_changed = screen_changed
        self.screen_hash = screen_hash
        self.elements = elements
        self.visible_text = visible_text
        self.raw_text = raw_text
        self.notes = notes
        self.screenshot_base64 = screenshot_base64
        self.screenshot_mime = screenshot_mime
    }
}

public struct ResultRequestDTO: Sendable, Codable, Equatable {
    public var task_id: String
    public var lease_token: String
    public var status: String
    public var summary: String
    public var raw_text: String
    public var error_code: String?
    public var error_message: String?
    public var uncertain_execution: Bool?
    public var action_receipts: [ActionReceiptDTO]?
    public var approval_required: PendingApprovalDTO?
    public var handoff_required: PendingHandoffDTO?
    public var finished_app_return: Bool?
    public var observation: ObservationPayloadDTO?
    public var runner_state: String?
}

public struct ResultResponseDTO: Sendable, Decodable, Equatable {
    public var accepted: Bool
    public var task_status: String
    public var observation_id: String?
}

public struct HeartbeatRequestDTO: Sendable, Encodable {
    public var runner_state: String?
    public var app_version: String?
    public var ios_version: String?
    public var network_state: String?
    public var app_lifecycle_state: String?
    public var battery_level: Double?
    public var reset_session: Bool?
    public var active_task_id: String?
    public var lease_token: String?
    public var pending_approval: PendingApprovalDTO?
    public var pending_handoff: PendingHandoffDTO?
}

public struct HeartbeatResponseDTO: Sendable, Decodable, Equatable {
    public var session_generation: Int
    public var emergency_stopped: Bool
    public var cancel_task_ids: [String]
    public var lease_renewed: Bool
    public var poll_config: PollConfigDTO
}

public struct DeviceStatusResponseDTO: Sendable, Decodable, Equatable {
    public var device_id: String
    public var label: String
    public var name: String
    public var status: String
    public var session_generation: Int
    public var emergency_stopped: Bool
    public var emergency_stop_reason: String?
    public var last_observation_id: String?
    public var poll_config: PollConfigDTO
}

public struct CancelRequestDTO: Sendable, Encodable {
    public var task_id: String?
    public var lease_token: String?
    public var reason: String?
    public var owner_stop: Bool?
}

public struct CancelResponseDTO: Sendable, Decodable, Equatable {
    public var acknowledged: Bool
    public var emergency_stopped: Bool
    public var cancelled_count: Int
}
