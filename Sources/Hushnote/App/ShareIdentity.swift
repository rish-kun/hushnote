import Foundation

/// This Mac's proof that it owns the links it created.
///
/// There are no accounts. A share is owned by whoever holds this token, and the
/// server keeps only its SHA-256 -- so the token is not a password that can be
/// reset, it is the only credential that exists. Two consequences the UI has to
/// state rather than bury:
///
/// - Reinstalling without a Keychain restore permanently orphans existing
///   links. They keep rendering and can never be revoked from this app again.
/// - Anyone holding the token can revoke or rewrite every share it created.
///
/// It lives in the data-protection Keychain, not `AppPreferences`, for the same
/// reason provider API keys do. It is deliberately *not* a `ProviderCredential`:
/// that enum means "an API key for a model provider", and widening it to cover
/// an identity token would make the two indistinguishable at every call site.
protocol ShareTokenStoring: Sendable {
    func token() async throws -> String?
    func setToken(_ token: String) async throws
    func removeToken() async throws
}

actor KeychainShareTokenStore: ShareTokenStoring {
    private let service: String
    private let account = "device-token"
    private let backend: any KeychainBackend

    init(
        service: String = "app.hushnote.share",
        backend: any KeychainBackend = SecItemKeychainBackend()
    ) {
        self.service = service
        self.backend = backend
    }

    func token() async throws -> String? {
        let (status, data) = await backend.copy(
            KeychainQuery.read(service: service, account: account)
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func setToken(_ token: String) async throws {
        guard let data = token.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        let query = KeychainQuery.item(service: service, account: account)
        let updated = await backend.update(query, data: data)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updated)
        }
        let added = await backend.add(query, data: data)
        guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
    }

    func removeToken() async throws {
        let status = await backend.delete(KeychainQuery.item(service: service, account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

/// Where shares are published, and what a link therefore looks like.
///
/// Read from the environment at launch so a local Postgres and a
/// `localhost:3000` web app can serve development without a deployment, and so
/// changing the production domain later is one value rather than a rebuild of
/// every call site.
///
/// **Existing links keep the origin they were created with.** They are absolute
/// URLs already in other people's hands; changing this changes only what new
/// links look like.
enum ShareService {
    static let defaultOrigin = URL(string: "https://hushnote.app")!

    static func origin(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let raw = environment["HUSHNOTE_SHARE_ORIGIN"],
              let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http"
        else { return defaultOrigin }
        return url
    }
}
