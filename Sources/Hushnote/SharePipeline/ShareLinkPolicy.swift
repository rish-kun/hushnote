import Foundation

/// What a share id is allowed to look like, and where a share id lives.
///
/// Ids are minted by the server; this side validates what comes back and
/// composes URLs from it. Both halves are pure so the one place that knows a
/// link's shape can be tested without a network.
enum ShareLinkPolicy {
    static let idLength = 10

    /// Base58: the ASCII alphanumerics minus `0`, `O`, `I` and `l`. A share id
    /// gets read aloud, retyped, and pasted out of chat clients that helpfully
    /// change fonts, so the look-alike characters are excluded rather than
    /// merely discouraged. Ten characters of it is ~4.3e17 ids.
    static let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    private static let allowed = Set(alphabet)

    /// Deliberately strict and deliberately silent about *why*: an id is either
    /// one this app can ask about or it is not, and enumerating rejection
    /// reasons to a caller only invites lenient repair. In particular a
    /// look-alike is rejected rather than folded to its neighbour — `0` is not
    /// a typo for `O` that anyone can safely correct on the user's behalf.
    nonisolated static func isValidShareID(_ raw: String) -> Bool {
        guard raw.count == idLength else { return false }
        return raw.allSatisfy(allowed.contains)
    }

    /// The link people are given. Absolute, and absolute forever: changing the
    /// custom domain later changes only what new links are built from, because
    /// existing links are already in other people's hands.
    nonisolated static func url(shareID: String, origin: URL) -> URL? {
        guard isValidShareID(shareID) else { return nil }
        return origin.appending(path: "s").appending(path: shareID)
    }

    /// `POST` — creates a share and returns its id.
    nonisolated static func createEndpoint(origin: URL) -> URL {
        origin.appending(path: "api").appending(path: "shares")
    }

    /// `PUT` republishes the payload, `DELETE` revokes it.
    nonisolated static func shareEndpoint(shareID: String, origin: URL) -> URL? {
        guard isValidShareID(shareID) else { return nil }
        return createEndpoint(origin: origin).appending(path: shareID)
    }

    /// `PUT` sets or clears the password.
    nonisolated static func passwordEndpoint(shareID: String, origin: URL) -> URL? {
        shareEndpoint(shareID: shareID, origin: origin)?.appending(path: "password")
    }
}
