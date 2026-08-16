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

public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "app.hushnote.insight-providers") {
        self.service = service
    }

    public func setCredential(_ credential: String, for key: ProviderCredential) throws {
        guard let data = credential.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.keychain(updateStatus)
        }
    }

    public func credential(for key: ProviderCredential) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = String(data: data, encoding: .utf8) else {
            if status != errSecSuccess { throw CredentialStoreError.keychain(status) }
            throw CredentialStoreError.invalidEncoding
        }
        return credential
    }

    public func removeCredential(for key: ProviderCredential) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

