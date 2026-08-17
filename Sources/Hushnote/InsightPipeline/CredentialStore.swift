import Foundation
import Security

public enum ProviderCredential: String, Codable, CaseIterable, Sendable {
    case openAIAPIKey = "openai-api-key"
    case anthropicAPIKey = "anthropic-api-key"
}

public protocol CredentialStore: Sendable {
    func setCredential(_ credential: String, for key: ProviderCredential) async throws
    func credential(for key: ProviderCredential) async throws -> String?
    func removeCredential(for key: ProviderCredential) async throws
}

public enum CredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidEncoding
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: "The credential could not be encoded."
        case .keychain(let status): "Keychain operation failed (\(status))."
        }
    }
}

/// One keychain lookup, described in a form that can be inspected before it
/// becomes a CFDictionary.
///
/// The distinction that matters is `useDataProtectionKeychain`. Without it a
/// query targets `login.keychain-db`, where `kSecAttrAccessible` is not
/// supported and is silently ignored — so the carefully chosen protection class
/// buys nothing, and the item ends up in file-level backups and unlocked for
/// the whole login session.
public struct KeychainQuery: Sendable, Equatable {
    public var service: String
    public var account: String
    public var useDataProtectionKeychain: Bool
    public var accessible: String?
    public var returnData: Bool

    /// The item as Hushnote stores it today.
    public static func item(service: String, account: String) -> KeychainQuery {
        KeychainQuery(
            service: service,
            account: account,
            useDataProtectionKeychain: true,
            accessible: nil,
            returnData: false
        )
    }

    public static func read(service: String, account: String) -> KeychainQuery {
        var query = item(service: service, account: account)
        query.returnData = true
        return query
    }

    /// The same item as it was written before this was fixed, so it can be
    /// found and moved.
    public static func legacyRead(service: String, account: String) -> KeychainQuery {
        var query = read(service: service, account: account)
        query.useDataProtectionKeychain = false
        return query
    }

    /// Adds the protection class, for the calls that write.
    ///
    /// AfterFirstUnlock because finalization runs after a meeting ends and may
    /// find the screen locked; ThisDeviceOnly to keep the key out of backups.
    public func storing() -> KeychainQuery {
        var query = self
        query.accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        return query
    }

    public func asDictionary() -> [String: Any] {
        var dictionary: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            dictionary[kSecUseDataProtectionKeychain as String] = true
        }
        if let accessible {
            dictionary[kSecAttrAccessible as String] = accessible
        }
        if returnData {
            dictionary[kSecReturnData as String] = true
            dictionary[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return dictionary
    }
}

public protocol KeychainBackend: Sendable {
    func copy(_ query: KeychainQuery) async -> (status: OSStatus, data: Data?)
    func add(_ query: KeychainQuery, data: Data) async -> OSStatus
    func update(_ query: KeychainQuery, data: Data) async -> OSStatus
    func delete(_ query: KeychainQuery) async -> OSStatus
}

public struct SecItemKeychainBackend: KeychainBackend {
    public init() {}

    public func copy(_ query: KeychainQuery) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.asDictionary() as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ query: KeychainQuery, data: Data) -> OSStatus {
        var attributes = query.storing().asDictionary()
        attributes[kSecReturnData as String] = nil
        attributes[kSecMatchLimit as String] = nil
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: KeychainQuery, data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemUpdate(query.asDictionary() as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: KeychainQuery) -> OSStatus {
        SecItemDelete(query.asDictionary() as CFDictionary)
    }
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let backend: any KeychainBackend
    private var migrated: Set<ProviderCredential> = []

    public init(
        service: String = "app.hushnote.insight-providers",
        backend: any KeychainBackend = SecItemKeychainBackend()
    ) {
        self.service = service
        self.backend = backend
    }

    public func setCredential(_ credential: String, for key: ProviderCredential) async throws {
        guard let data = credential.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        let query = KeychainQuery.item(service: service, account: key.rawValue)
        let updateStatus = await backend.update(query, data: data)
        if updateStatus == errSecItemNotFound {
            let status = await backend.add(query, data: data)
            guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.keychain(updateStatus)
        }
        // A key written here supersedes anything left behind in the old
        // keychain, so the stale copy goes.
        _ = await backend.delete(KeychainQuery.legacyRead(service: service, account: key.rawValue))
    }

    public func credential(for key: ProviderCredential) async throws -> String? {
        await migrateIfNeeded(key)
        let (status, data) = await backend.copy(
            KeychainQuery.read(service: service, account: key.rawValue)
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data,
              let credential = String(data: data, encoding: .utf8) else {
            if status != errSecSuccess { throw CredentialStoreError.keychain(status) }
            throw CredentialStoreError.invalidEncoding
        }
        return credential
    }

    public func removeCredential(for key: ProviderCredential) async throws {
        let status = await backend.delete(KeychainQuery.item(service: service, account: key.rawValue))
        _ = await backend.delete(KeychainQuery.legacyRead(service: service, account: key.rawValue))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    /// Moves an item written before the data protection keychain was requested.
    ///
    /// Existing keys become invisible otherwise: they were written to
    /// `login.keychain-db` and every query now looks somewhere else. Done in
    /// this order on purpose — read the old one, write the new one, and only
    /// then delete the old one — so an interruption anywhere leaves two copies
    /// of the key rather than none.
    private func migrateIfNeeded(_ key: ProviderCredential) async {
        guard !migrated.contains(key) else { return }
        migrated.insert(key)

        let modern = KeychainQuery.read(service: service, account: key.rawValue)
        let (existing, _) = await backend.copy(modern)
        guard existing == errSecItemNotFound else { return }

        let legacy = KeychainQuery.legacyRead(service: service, account: key.rawValue)
        let (legacyStatus, data) = await backend.copy(legacy)
        guard legacyStatus == errSecSuccess, let data else { return }

        guard await backend.add(modern, data: data) == errSecSuccess else { return }
        _ = await backend.delete(legacy)
    }
}
