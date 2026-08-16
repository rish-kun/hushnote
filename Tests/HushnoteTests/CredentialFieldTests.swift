import Foundation
import Testing
@testable import Hushnote

/// The API-key field was a `SecureField` bound to `get: { "" }`, so any
/// unrelated re-render mid-typing resynced it to empty and discarded what had
/// been typed. There was no indication whether a key was already stored, "Save
/// and verify" performed no verification and gave no feedback, and `stageAPIKey`
/// left the plaintext key in the coordinator indefinitely if Save was never
/// pressed.
@Suite("Credential field")
struct CredentialFieldTests {
    @Test("An empty field cannot be submitted")
    func emptyEntryCannotSubmit() {
        #expect(CredentialField.canSubmit(entry: "", state: .absent) == false)
        #expect(CredentialField.canSubmit(entry: "   \n ", state: .absent) == false)
    }

    @Test("A typed key can be submitted")
    func typedEntryCanSubmit() {
        #expect(CredentialField.canSubmit(entry: "sk-test-key", state: .absent))
        #expect(CredentialField.canSubmit(entry: "sk-test-key", state: .stored))
    }

    /// Pressing Save twice must not start a second verification round trip.
    @Test("A verification already running blocks another")
    func verifyingBlocksSubmission() {
        #expect(CredentialField.canSubmit(entry: "sk-test-key", state: .verifying) == false)
    }

    /// Whether a key exists is the thing the old field could never tell you.
    @Test("The status says whether a key is stored")
    func statusDistinguishesStoredFromAbsent() {
        #expect(CredentialField.statusText(.absent) == "No key is stored for this provider.")
        #expect(CredentialField.statusText(.stored) == "A key is stored in your Keychain.")
    }

    @Test("Verification reports both outcomes")
    func statusReportsVerification() {
        #expect(CredentialField.statusText(.verifying) == "Checking the key with the provider…")
        #expect(CredentialField.statusText(.verified) == "The key works and is saved in your Keychain.")
        #expect(CredentialField.statusText(.failed("The provider rejected the key.")) == "The provider rejected the key.")
    }

    /// Before the Keychain has been asked, claiming either answer would be a
    /// guess.
    @Test("An unchecked field claims nothing")
    func unknownStatusClaimsNothing() {
        #expect(CredentialField.statusText(.unknown).isEmpty)
    }

    /// A key that verified is in the Keychain, so the field is cleared -- the
    /// plaintext should not sit in a view for the rest of the session.
    @Test("A verified key is cleared from the field")
    func verifiedKeyIsCleared() {
        #expect(CredentialField.clearsEntry(after: .verified))
        #expect(CredentialField.clearsEntry(after: .failed("rejected")) == false)
        #expect(CredentialField.clearsEntry(after: .verifying) == false)
    }
}
