import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (statusCode: Int, data: Data)
}

private final class NoCrossOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let nextHost = request.url?.host?.lowercased()
        if originalHost == nextHost {
            completionHandler(request)
        } else {
            // Stop at 3xx rather than following cross-origin Sites login redirects to HTML pages.
            completionHandler(nil)
        }
    }
}

public final class URLSessionHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let redirectDelegate = NoCrossOriginRedirectDelegate()
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = SitesBridgeConfig.makeProxyCompatibleSessionConfiguration()) {
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http.statusCode, data)
    }
}

public enum SitesClientError: Error, Sendable, Equatable {
    case invalidAddress
    case missingCredentials
    case staleGeneration(current: Int)
    case unauthorized(code: String, message: String)
    case httpError(status: Int, code: String, message: String)
}

private struct ServerErrorEnvelope: Decodable {
    struct Details: Decodable {
        var current_generation: Int?
    }
    struct Body: Decodable {
        var code: String
        var message: String
        var current_generation: Int?
        var details: Details?
    }
    var error: Body
}

/// Signed HTTPS client communicating exclusively with a ChatGPT Site (`/api/device/*`).
public final class SitesBridgeClient: @unchecked Sendable {
    private let address: SitesAddress
    private let transport: HTTPTransporting
    private let signer: SitesRequestSigner
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        address: SitesAddress,
        signer: SitesRequestSigner,
        transport: HTTPTransporting = URLSessionHTTPTransport()
    ) {
        self.address = address
        self.signer = signer
        self.transport = transport
    }

    public func pair(
        pairingCode: String,
        deviceName: String?,
        config: SitesBridgeConfig,
        siwcBypassToken: String?
    ) async throws -> PairResponseDTO {
        let ts = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.lowercased()
        let sig = try signer.signPairingProof(pairingCode: pairingCode, timestamp: ts, nonce: nonce)
        let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDeviceName = (trimmedName?.isEmpty == false) ? String(trimmedName!.prefix(80)) : nil
        let cleanBypass = SitesRequestSigner.normalizeBearerToken(siwcBypassToken)

        let payload = PairRequestDTO(
            pairing_code: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            label: signer.label,
            public_key_b64: signer.publicKeyBase64,
            proof_sig_b64: sig,
            timestamp: ts,
            nonce: nonce,
            device_name: safeDeviceName,
            app_version: config.appVersion,
            ios_version: config.iosVersion,
            capabilities: ["poki_core": .bool(true), "polling_v1": .bool(true)]
        )
        let body = try encoder.encode(payload)
        var req = URLRequest(url: address.endpoint("/api/device/pair"))
        req.httpMethod = "POST"
        req.timeoutInterval = config.requestTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cleanBypass {
            req.setValue("Bearer \(cleanBypass)", forHTTPHeaderField: "OAI-Sites-Authorization")
        }
        req.httpBody = body
        let (status, data) = try await transport.send(req)
        try checkStatus(status, data: data)
        return try decoder.decode(PairResponseDTO.self, from: data)
    }

    public func poll(
        credentials: StoredDeviceCredentials,
        generation: Int,
        payload: PollRequestDTO,
        timeoutSeconds: TimeInterval
    ) async throws -> PollResponseDTO {
        try await signedRequest(
            method: "POST",
            path: "/api/device/poll",
            bodyData: try encoder.encode(payload),
            credentials: credentials,
            generation: generation,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func submitResult(
        credentials: StoredDeviceCredentials,
        generation: Int,
        payload: ResultRequestDTO,
        timeoutSeconds: TimeInterval
    ) async throws -> ResultResponseDTO {
        try await signedRequest(
            method: "POST",
            path: "/api/device/result",
            bodyData: try encoder.encode(payload),
            credentials: credentials,
            generation: generation,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func heartbeat(
        credentials: StoredDeviceCredentials,
        generation: Int?,
        payload: HeartbeatRequestDTO,
        timeoutSeconds: TimeInterval
    ) async throws -> HeartbeatResponseDTO {
        try await signedRequest(
            method: "POST",
            path: "/api/device/heartbeat",
            bodyData: try encoder.encode(payload),
            credentials: credentials,
            generation: generation,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func cancel(
        credentials: StoredDeviceCredentials,
        generation: Int,
        payload: CancelRequestDTO,
        timeoutSeconds: TimeInterval
    ) async throws -> CancelResponseDTO {
        try await signedRequest(
            method: "POST",
            path: "/api/device/cancel",
            bodyData: try encoder.encode(payload),
            credentials: credentials,
            generation: generation,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func status(
        credentials: StoredDeviceCredentials,
        generation: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> DeviceStatusResponseDTO {
        try await signedRequest(
            method: "GET",
            path: "/api/device/status",
            bodyData: Data(),
            credentials: credentials,
            generation: generation,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func signedRequest<R: Decodable>(
        method: String,
        path: String,
        bodyData: Data,
        credentials: StoredDeviceCredentials,
        generation: Int?,
        timeoutSeconds: TimeInterval
    ) async throws -> R {
        var req = URLRequest(url: address.endpoint(path))
        req.httpMethod = method
        req.timeoutInterval = timeoutSeconds
        if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
        }
        let headers = try signer.signedHeaders(
            method: method,
            path: path,
            body: bodyData,
            deviceId: credentials.deviceId,
            deviceToken: credentials.deviceToken,
            generation: generation,
            siwcBypassToken: credentials.siwcBypassToken
        )
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (status, data) = try await transport.send(req)
        try checkStatus(status, data: data)
        return try decoder.decode(R.self, from: data)
    }

    private func checkStatus(_ status: Int, data: Data) throws {
        guard !(200...299).contains(status) else { return }
        if (300...399).contains(status) {
            throw SitesClientError.unauthorized(
                code: "SITES_AUTH_REQUIRED",
                message: "ChatGPT Site rejected access (HTTP \(status)); verify OAI-Sites-Authorization service token"
            )
        }
        let env = try? decoder.decode(ServerErrorEnvelope.self, from: data)
        let code = env?.error.code ?? "HTTP_\(status)"
        let msg = env?.error.message ?? String(decoding: data, as: UTF8.self)
        let currentGen = env?.error.current_generation ?? env?.error.details?.current_generation
        if status == 409 && code == "STALE_GENERATION", let currentGen {
            throw SitesClientError.staleGeneration(current: currentGen)
        }
        if status == 401 || status == 403 {
            throw SitesClientError.unauthorized(code: code, message: msg)
        }
        throw SitesClientError.httpError(status: status, code: code, message: msg)
    }
}
