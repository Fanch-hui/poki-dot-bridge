import CryptoKit
import Foundation
import Security

public struct StoredDeviceCredentials: Sendable, Codable, Equatable {
    public var sitesOrigin: String
    public var deviceId: String
    public var deviceToken: String
    public var label: String
    public var sessionGeneration: Int
    public var siwcBypassToken: String?

    public init(
        sitesOrigin: String,
        deviceId: String,
        deviceToken: String,
        label: String,
        sessionGeneration: Int,
        siwcBypassToken: String? = nil
    ) {
        self.sitesOrigin = sitesOrigin
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.label = label
        self.sessionGeneration = sessionGeneration
        self.siwcBypassToken = siwcBypassToken
    }
}

public protocol CredentialStoring: Sendable {
    func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey
    func loadCredentials() throws -> StoredDeviceCredentials?
    func saveCredentials(_ credentials: StoredDeviceCredentials) throws
    func deleteCredentials() throws
    func loadOutbox() throws -> [ResultRequestDTO]
    func saveOutbox(_ items: [ResultRequestDTO]) throws
}

/// iOS Keychain-backed store (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) so credentials
/// survive app suspension/restarts and remain readable while the device is locked after first unlock.
public final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let service: String
    private let keyAccount: String
    private let credsAccount: String
    private let outboxAccount: String

    public init(
        service: String = "nz.zheha.poki",
        keyAccount: String = "relay.ed25519",
        credsAccount: String = "sites.bridge.credentials",
        outboxAccount: String = "sites.bridge.outbox"
    ) {
        self.service = service
        self.keyAccount = keyAccount
        self.credsAccount = credsAccount
        self.outboxAccount = outboxAccount
    }

    public func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = try read(account: keyAccount) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let generated = Curve25519.Signing.PrivateKey()
        try write(generated.rawRepresentation, account: keyAccount)
        return generated
    }

    public func loadCredentials() throws -> StoredDeviceCredentials? {
        guard let data = try read(account: credsAccount) else { return nil }
        return try JSONDecoder().decode(StoredDeviceCredentials.self, from: data)
    }

    public func saveCredentials(_ credentials: StoredDeviceCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try write(data, account: credsAccount)
    }

    public func deleteCredentials() throws {
        delete(account: credsAccount)
    }

    public func loadOutbox() throws -> [ResultRequestDTO] {
        guard let data = try read(account: outboxAccount) else { return [] }
        return (try? JSONDecoder().decode([ResultRequestDTO].self, from: data)) ?? []
    }

    public func saveOutbox(_ items: [ResultRequestDTO]) throws {
        if items.isEmpty {
            delete(account: outboxAccount)
            return
        }
        let data = try JSONEncoder().encode(Array(items.suffix(8)))
        try write(data, account: outboxAccount)
    }

    private func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return result as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func delete(account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }
}

/// Thread-safe in-memory credential store for Swift unit tests and simulator verification.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Curve25519.Signing.PrivateKey
    private var creds: StoredDeviceCredentials?
    private var outbox: [ResultRequestDTO] = []

    public init(privateKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) {
        self.key = privateKey
    }

    public func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        lock.withLock { key }
    }

    public func loadCredentials() throws -> StoredDeviceCredentials? {
        lock.withLock { creds }
    }

    public func saveCredentials(_ credentials: StoredDeviceCredentials) throws {
        lock.withLock { creds = credentials }
    }

    public func deleteCredentials() throws {
        lock.withLock { creds = nil }
    }

    public func loadOutbox() throws -> [ResultRequestDTO] {
        lock.withLock { outbox }
    }

    public func saveOutbox(_ items: [ResultRequestDTO]) throws {
        lock.withLock { outbox = items }
    }
}
