import Foundation

/// Validated ChatGPT Sites endpoint (`https://<site>.chatgpt.site` or local dev `http://127.0.0.1:<port>`).
public struct SitesAddress: Sendable, Equatable, Codable {
    public let origin: URL

    public init?(_ text: String) {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if !normalized.contains("://") {
            normalized = "https://" + normalized
        }
        guard let parts = URLComponents(string: normalized),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        let isLocal = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            return nil
        }
        guard parts.query == nil, parts.fragment == nil, parts.user == nil else {
            return nil
        }
        var out = URLComponents()
        out.scheme = scheme
        out.host = host
        out.port = parts.port
        guard let url = out.url else { return nil }
        self.origin = url
    }

    public func endpoint(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return origin.appendingPathComponent(trimmed)
    }
}

public struct SitesBridgeConfig: Sendable, Equatable {
    public var appVersion: String
    public var iosVersion: String
    public var defaultPollWaitMs: Int
    public var heartbeatIntervalSeconds: TimeInterval
    public var requestTimeoutSeconds: TimeInterval
    public var minBackoffSeconds: TimeInterval
    public var maxBackoffSeconds: TimeInterval

    public init(
        appVersion: String = "1.0.0",
        iosVersion: String = "27.3",
        defaultPollWaitMs: Int = 10_000,
        heartbeatIntervalSeconds: TimeInterval = 12,
        requestTimeoutSeconds: TimeInterval = 25,
        minBackoffSeconds: TimeInterval = 1,
        maxBackoffSeconds: TimeInterval = 30
    ) {
        self.appVersion = appVersion
        self.iosVersion = iosVersion
        self.defaultPollWaitMs = min(12_000, max(0, defaultPollWaitMs))
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.minBackoffSeconds = minBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
    }

    /// URLSession configuration compatible with Shadowrocket / proxy apps:
    /// uses system proxy settings for remote HTTPS Sites endpoints, while never caching device credentials.
    public static func makeProxyCompatibleSessionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        return cfg
    }
}
