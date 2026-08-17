import Foundation

/// An empty, app-private directory handed to a spawned coding agent as its
/// working directory.
///
/// Every agent CLI Hushnote can drive runs with filesystem read access of some
/// kind, and every one of them treats the working directory as the place to
/// look first: project docs, `AGENTS.md`, `CLAUDE.md`, config discovery. Left
/// at the app's own directory that means the agent reads the user's project on
/// every summary, and a transcript line that says "read the file next to you"
/// has something to point at. A fresh directory with nothing in it removes the
/// target rather than arguing with the model about it.
public struct AgentSandboxDirectory: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Creates a new empty directory owned by this user alone.
    public static func make(label: String) throws -> AgentSandboxDirectory {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "app.hushnote.agent-sandbox", directoryHint: .isDirectory)
        let url = root
            .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InsightProviderError.invalidConfiguration(
                "Unable to create a private working directory for the agent: \(error.localizedDescription)"
            )
        }
        return AgentSandboxDirectory(url: url)
    }

    public var path: String { url.path }

    /// Removes the directory. Deliberately silent: a leftover empty directory in
    /// the temporary folder is not worth failing a summary over.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
