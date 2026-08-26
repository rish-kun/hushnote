import CryptoKit
import Foundation
import Security

/// Identity without accounts: a 32-byte random token generated on first share.
/// Possession of it is the sole proof of ownership, so it is the only thing
/// that can update or revoke an existing link.
///
/// This type only mints the token and hashes it. Storing it is the
/// coordinator's job, in the data-protection Keychain through the existing
/// credential machinery — a secret this type wrote to disk itself would be a
/// second, unaudited place credentials live.
enum ShareDeviceToken {
    static let byteCount = 32

    /// Base64url with no padding: the token is shown in Settings so it can be
    /// written down and pasted back, and it travels in an `Authorization`
    /// header. `+`, `/` and `=` survive neither trip reliably.
    nonisolated static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // `SystemRandomNumberGenerator` is the platform CSPRNG, so this
            // fallback is not a weaker token — it exists because losing the
            // ability to share is not an acceptable answer to a transient
            // Security framework failure.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    /// What the server stores. It never sees the token itself except in the
    /// `Authorization` header of a request it is already authenticating, so a
    /// database breach cannot yield the ability to revoke or rewrite anyone's
    /// shares.
    ///
    /// Lowercase hex, over the token's UTF-8 bytes as sent — the string, not
    /// its decoded 32 bytes, so the server can compute the same hash from the
    /// header without knowing this encoding.
    nonisolated static func sha256(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
