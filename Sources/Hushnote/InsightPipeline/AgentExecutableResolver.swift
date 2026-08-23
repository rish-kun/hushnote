import Foundation

/// Finds an agent CLI by absolute path.
///
/// Spawning `/usr/bin/env <tool>` works from a terminal and fails in every
/// bundle `scripts/build-app.sh` produces, because a Finder-launched .app is
/// handed `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and none of these tools live
/// there. It is also the wrong shape for something Hushnote spawns: the child
/// inherits Hushnote's system-audio recording grant, so whatever sits earliest
/// on PATH gets code execution with the app's microphone permission. Looking in
/// a fixed set of locations and checking who can write to what removes both
/// problems at once.
public struct AgentExecutableResolver: Sendable {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidName(String)
        case notFound(name: String, searched: [String])
        case writableByOthers(path: String)

        public var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                "\"\(name)\" is not a command name."
            case .notFound(let name, let searched):
                "\(name) was not found. Looked in: \(searched.joined(separator: ", "))."
            case .writableByOthers(let path):
                "\(path) can be modified by other users, so Hushnote will not run it."
            }
        }
    }

    public let searchPaths: [URL]

    /// Groups whose write access is not a finding.
    ///
    /// Homebrew on Apple Silicon ships `/opt/homebrew/bin` as mode 775 owned by
    /// `you:admin`, and that is where `codex` and `opencode` install. Refusing
    /// every group-writable directory would refuse Homebrew, i.e. refuse the
    /// feature on most Macs. `wheel` and `admin` are the two groups whose
    /// members can already become root, so their write access buys an attacker
    /// nothing they did not have. Any other group is a real finding.
    public let groupsAllowedToWrite: Set<gid_t>

    public init(
        searchPaths: [URL] = AgentExecutableResolver.defaultSearchPaths,
        groupsAllowedToWrite: Set<gid_t> = [0, 80]
    ) {
        self.searchPaths = searchPaths
        self.groupsAllowedToWrite = groupsAllowedToWrite
    }

    /// The places these tools actually install themselves, in the order a
    /// developer machine tends to prefer them.
    public static var defaultSearchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let absolute = ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0) }
        let relativeToHome = [
            ".opencode/bin",
            ".local/bin",
            ".bun/bin",
            ".npm-global/bin",
            ".npm/bin",
            "Library/pnpm",
            ".local/share/pnpm",
            ".yarn/bin",
            ".volta/bin"
        ].map { home.appending(path: $0, directoryHint: .isDirectory) }
        // Prefer the user's explicit CLI installation over an older package-
        // manager copy. Every candidate still passes the ownership and write-
        // access checks below, so this does not reintroduce PATH hijacking.
        return relativeToHome + absolute
    }

    public func resolve(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw Failure.invalidName(name)
        }
        var writable: String?
        for directory in searchPaths {
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            do {
                try requireExclusiveWriteAccess(to: candidate)
            } catch Failure.writableByOthers(let path) {
                // Keep looking: a hijackable copy early in the list must not
                // shadow a sound one later, but it is worth reporting if
                // nothing sound turns up.
                writable = writable ?? path
                continue
            }
            return candidate.resolvingSymlinksInPath()
        }
        if let writable { throw Failure.writableByOthers(path: writable) }
        throw Failure.notFound(name: name, searched: searchPaths.map(\.path))
    }

    /// Refuses anything another user can write, along the whole chain: the
    /// file, whatever it links to, and the directories holding both. A
    /// writable directory is as good as a writable binary — the file can
    /// simply be replaced.
    private func requireExclusiveWriteAccess(to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let chain = Set([
            url.path,
            target.path,
            url.deletingLastPathComponent().path,
            target.deletingLastPathComponent().path
        ])
        for path in chain {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
                  let group = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value else {
                throw Failure.writableByOthers(path: path)
            }
            if permissions & 0o002 != 0 { throw Failure.writableByOthers(path: path) }
            if permissions & 0o020 != 0, !groupsAllowedToWrite.contains(gid_t(group)) {
                throw Failure.writableByOthers(path: path)
            }
            if owner != 0, owner != getuid() { throw Failure.writableByOthers(path: path) }
        }
    }
}

/// The environment a spawned agent gets.
///
/// Built rather than inherited, because Hushnote's own environment carries
/// whatever launched it — a hijacked PATH, a proxy, an API key meant for
/// something else — straight into a process that is about to be handed a
/// meeting transcript.
public enum AgentProcessEnvironment {
    public static func minimal(
        extra: [String: String] = [:]
    ) -> [String: String] {
        let info = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // The CLIs read their own credentials out of the home directory.
            // Without HOME they are simply signed out.
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8"
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SHELL"] {
            if let value = info[key] { environment[key] = value }
        }
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}
