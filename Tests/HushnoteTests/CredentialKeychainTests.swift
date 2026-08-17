import Foundation
import Security
import Testing
@testable import Hushnote

/// Where an API key physically lands. Nothing here touches the real keychain:
/// the SecItem calls go through a fake, because a unit test has no business
/// writing to the user's login keychain.
@Suite("Credential keychain")
struct CredentialKeychainTests {
    @Test("Every query targets the data protection keychain")
    func targetsTheDataProtectionKeychain() {
        let queries = [
            KeychainQuery.item(service: "s", account: "a"),
            KeychainQuery.read(service: "s", account: "a"),
            KeychainQuery.item(service: "s", account: "a").storing()
        ]

        for query in queries {
            #expect(query.useDataProtectionKeychain)
            let dictionary = query.asDictionary()
            #expect(dictionary[kSecUseDataProtectionKeychain as String] as? Bool == true)
        }
    }

    @Test("The accessibility class is the one that survives background finalization")
    func usesTheRightAccessibilityClass() {
        let dictionary = KeychainQuery.item(service: "s", account: "a").storing().asDictionary()

        // Finalization runs after a meeting ends, possibly with the screen
        // locked, so AfterFirstUnlock is needed. ThisDeviceOnly keeps the key
        // out of file-level backups. In the legacy keychain this attribute is
        // unsupported and was being ignored outright.
        #expect(
            dictionary[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        )
    }

    @Test("The legacy query is the only one that does not opt in")
    func describesTheLegacyItem() {
        let legacy = KeychainQuery.legacyRead(service: "s", account: "a")

        #expect(!legacy.useDataProtectionKeychain)
        #expect(legacy.asDictionary()[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test("An existing key is copied forward before the old one is deleted")
    func migratesWithoutEverLosingTheKey() async throws {
        let backend = FakeKeychain(legacy: ["openai-api-key": "sk-old"])
        let store = KeychainCredentialStore(service: "test", backend: backend)

        let value = try await store.credential(for: .openAIAPIKey)

        #expect(value == "sk-old")
        // The order is the whole point: a crash between the write and the
        // delete leaves two copies, never zero.
        #expect(await backend.operations() == [
            "copy(modern)", "copy(legacy)", "add(modern)", "delete(legacy)", "copy(modern)"
        ])
        #expect(await backend.modernValue("openai-api-key") == "sk-old")
        #expect(await backend.legacyValue("openai-api-key") == nil)
    }

    @Test("A failed write leaves the legacy item exactly where it was")
    func keepsTheLegacyItemWhenTheWriteFails() async throws {
        let backend = FakeKeychain(legacy: ["openai-api-key": "sk-old"], failAdd: true)
        let store = KeychainCredentialStore(service: "test", backend: backend)

        _ = try? await store.credential(for: .openAIAPIKey)

        #expect(await !backend.operations().contains("delete(legacy)"))
        #expect(await backend.legacyValue("openai-api-key") == "sk-old")
    }

    @Test("Migration is attempted once, not on every read")
    func migratesOnlyOnce() async throws {
        let backend = FakeKeychain(legacy: [:])
        let store = KeychainCredentialStore(service: "test", backend: backend)

        _ = try await store.credential(for: .openAIAPIKey)
        _ = try await store.credential(for: .openAIAPIKey)

        #expect(await backend.operations().filter { $0 == "copy(legacy)" }.count == 1)
    }

    @Test("A key already in the data protection keychain is left alone")
    func skipsMigrationWhenAlreadyMoved() async throws {
        let backend = FakeKeychain(legacy: ["openai-api-key": "sk-old"], modern: ["openai-api-key": "sk-new"])
        let store = KeychainCredentialStore(service: "test", backend: backend)

        #expect(try await store.credential(for: .openAIAPIKey) == "sk-new")
        #expect(await !backend.operations().contains("copy(legacy)"))
    }
}

private actor FakeKeychain: KeychainBackend {
    private var modern: [String: String]
    private var legacy: [String: String]
    private let failAdd: Bool
    private var log: [String] = []

    init(legacy: [String: String], modern: [String: String] = [:], failAdd: Bool = false) {
        self.legacy = legacy
        self.modern = modern
        self.failAdd = failAdd
    }

    func copy(_ query: KeychainQuery) -> (status: OSStatus, data: Data?) {
        let isModern = query.useDataProtectionKeychain
        log.append(isModern ? "copy(modern)" : "copy(legacy)")
        let table = isModern ? modern : legacy
        guard let value = table[query.account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, Data(value.utf8))
    }

    func add(_ query: KeychainQuery, data: Data) -> OSStatus {
        log.append(query.useDataProtectionKeychain ? "add(modern)" : "add(legacy)")
        guard !failAdd else { return errSecIO }
        if query.useDataProtectionKeychain {
            modern[query.account] = String(decoding: data, as: UTF8.self)
        } else {
            legacy[query.account] = String(decoding: data, as: UTF8.self)
        }
        return errSecSuccess
    }

    func update(_ query: KeychainQuery, data: Data) -> OSStatus {
        log.append(query.useDataProtectionKeychain ? "update(modern)" : "update(legacy)")
        let table = query.useDataProtectionKeychain ? modern : legacy
        guard table[query.account] != nil else { return errSecItemNotFound }
        if query.useDataProtectionKeychain {
            modern[query.account] = String(decoding: data, as: UTF8.self)
        } else {
            legacy[query.account] = String(decoding: data, as: UTF8.self)
        }
        return errSecSuccess
    }

    func delete(_ query: KeychainQuery) -> OSStatus {
        log.append(query.useDataProtectionKeychain ? "delete(modern)" : "delete(legacy)")
        if query.useDataProtectionKeychain {
            modern[query.account] = nil
        } else {
            legacy[query.account] = nil
        }
        return errSecSuccess
    }

    func operations() -> [String] { log }
    func modernValue(_ account: String) -> String? { modern[account] }
    func legacyValue(_ account: String) -> String? { legacy[account] }
}
