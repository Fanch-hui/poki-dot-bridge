import CryptoKit
import Foundation

/// Cryptographic helpers matching Poki Relay (`base32`) and Sites backend (`src/server/crypto.ts`).
public enum SitesCrypto {
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func base32Encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(base32Alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 {
            out.append(base32Alphabet[(buffer << (5 - bits)) & 31])
        }
        return out
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    public static func canonicalDeviceMessage(
        method: String,
        path: String,
        timestamp: Int,
        nonce: String,
        bodySha256: String
    ) -> Data {
        let joined = [
            "poki-sites-v1",
            method.uppercased(),
            path,
            String(timestamp),
            nonce,
            bodySha256,
        ].joined(separator: "\n")
        return Data(joined.utf8)
    }

    public static func canonicalPairMessage(
        codeHash: String,
        label: String,
        timestamp: Int,
        nonce: String
    ) -> Data {
        let joined = [
            "poki-sites-pair-v1",
            codeHash,
            label,
            String(timestamp),
            nonce,
        ].joined(separator: "\n")
        return Data(joined.utf8)
    }
}

public struct SitesRequestSigner: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let label: String
    public let publicKeyBase64: String

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        let raw = privateKey.publicKey.rawRepresentation
        self.label = SitesCrypto.base32Encode(raw)
        self.publicKeyBase64 = raw.base64EncodedString()
    }

    public func signPairingProof(
        pairingCode: String,
        timestamp: Int,
        nonce: String
    ) throws -> String {
        let codeHash = SitesCrypto.sha256Hex(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        let message = SitesCrypto.canonicalPairMessage(
            codeHash: codeHash,
            label: label,
            timestamp: timestamp,
            nonce: nonce
        )
        return try privateKey.signature(for: message).base64EncodedString()
    }

    public func signedHeaders(
        method: String,
        path: String,
        body: Data,
        deviceId: String,
        deviceToken: String,
        generation: Int?,
        siwcBypassToken: String?,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        nonce: String = UUID().uuidString.lowercased()
    ) throws -> [String: String] {
        let bodyHash = SitesCrypto.sha256Hex(body)
        let message = SitesCrypto.canonicalDeviceMessage(
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            bodySha256: bodyHash
        )
        let signature = try privateKey.signature(for: message).base64EncodedString()
        var headers: [String: String] = [
            "Authorization": "Bearer \(deviceToken)",
            "X-Poki-Device-Id": deviceId,
            "X-Poki-Timestamp": String(timestamp),
            "X-Poki-Nonce": nonce,
            "X-Poki-Signature": signature,
        ]
        if let generation {
            headers["X-Poki-Generation"] = String(generation)
        }
        if let cleanBypass = Self.normalizeBearerToken(siwcBypassToken) {
            headers["OAI-Sites-Authorization"] = "Bearer \(cleanBypass)"
        }
        return headers
    }

    public static func normalizeBearerToken(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.lowercased().hasPrefix("bearer ") {
            trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
