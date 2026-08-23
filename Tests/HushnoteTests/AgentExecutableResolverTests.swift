import Foundation
import Testing
@testable import Hushnote

/// A Finder-launched .app gets PATH=/usr/bin:/bin:/usr/sbin:/sbin, and none of
/// the agent CLIs live there. Resolving by name through PATH therefore fails in
/// every bundle the app ships as — and, worse, hands anything writable earlier
/// on PATH the app's system-audio recording permission.
@Suite("Agent executable resolution")
struct AgentExecutableResolverTests {
    @Test("A tool is found by absolute location, not by PATH")
    func resolvesByAbsoluteLocation() throws {
        let bin = try makeTemporaryBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let tool = try makeExecutable(named: "faketool", in: bin, mode: 0o755)

        let resolved = try AgentExecutableResolver(searchPaths: [bin]).resolve("faketool")

        #expect(resolved.path == tool.path)
        #expect(resolved.path.hasPrefix("/"))
    }

    @Test("The first safe installation wins, matching user-scoped CLI precedence")
    func prefersUserScopedInstallation() throws {
        let userBin = try makeTemporaryBin()
        let packageManagerBin = try makeTemporaryBin()
        defer {
            try? FileManager.default.removeItem(at: userBin)
            try? FileManager.default.removeItem(at: packageManagerBin)
        }
        let userTool = try makeExecutable(named: "opencode", in: userBin, mode: 0o755)
        _ = try makeExecutable(named: "opencode", in: packageManagerBin, mode: 0o755)

        let resolved = try AgentExecutableResolver(
            searchPaths: [userBin, packageManagerBin]
        ).resolve("opencode")

        #expect(resolved.path == userTool.path)
    }

    @Test("A tool reachable only through PATH is not found")
    func ignoresPATH() throws {
        let bin = try makeTemporaryBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        _ = try makeExecutable(named: "pathonly", in: bin, mode: 0o755)
        setenv("PATH", bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)

        #expect(throws: AgentExecutableResolver.Failure.self) {
            _ = try AgentExecutableResolver(searchPaths: []).resolve("pathonly")
        }
    }

    @Test("A group- or world-writable executable is refused")
    func refusesWritableExecutables() throws {
        let bin = try makeTemporaryBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        _ = try makeExecutable(named: "grouptool", in: bin, mode: 0o775)
        _ = try makeExecutable(named: "worldtool", in: bin, mode: 0o757)
        let resolver = AgentExecutableResolver(searchPaths: [bin])

        #expect(throws: AgentExecutableResolver.Failure.self) {
            _ = try resolver.resolve("grouptool")
        }
        #expect(throws: AgentExecutableResolver.Failure.self) {
            _ = try resolver.resolve("worldtool")
        }
    }

    @Test("Group write is allowed only for groups that could already become root")
    func allowsOnlyPrivilegedGroupWrite() throws {
        let bin = try makeTemporaryBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let tool = try makeExecutable(named: "brewlike", in: bin, mode: 0o775)
        let group = try #require(
            (try FileManager.default.attributesOfItem(atPath: tool.path)[.groupOwnerAccountID]
                as? NSNumber)?.uint32Value
        )

        // Homebrew ships /opt/homebrew/bin as 775 you:admin, so admin and wheel
        // are the deliberate exception and nothing else is.
        #expect(throws: AgentExecutableResolver.Failure.self) {
            _ = try AgentExecutableResolver(searchPaths: [bin]).resolve("brewlike")
        }
        let permissive = AgentExecutableResolver(
            searchPaths: [bin],
            groupsAllowedToWrite: [gid_t(group)]
        )
        #expect(try permissive.resolve("brewlike").path == tool.path)
    }

    @Test("An executable in a world-writable directory is refused")
    func refusesWritableDirectories() throws {
        let bin = try makeTemporaryBin(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: bin) }
        _ = try makeExecutable(named: "opentool", in: bin, mode: 0o755)

        #expect(throws: AgentExecutableResolver.Failure.self) {
            _ = try AgentExecutableResolver(searchPaths: [bin]).resolve("opentool")
        }
    }

    @Test("A name that is really a path is refused")
    func refusesPathsDressedAsNames() throws {
        let bin = try makeTemporaryBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let resolver = AgentExecutableResolver(searchPaths: [bin])

        for name in ["../codex", "/usr/bin/env", "sub/codex", ""] {
            #expect(throws: AgentExecutableResolver.Failure.self) {
                _ = try resolver.resolve(name)
            }
        }
    }

    @Test("The child environment is built, not inherited")
    func buildsAMinimalEnvironment() {
        setenv("HUSHNOTE_TEST_LEAK", "leaked", 1)
        defer { unsetenv("HUSHNOTE_TEST_LEAK") }

        let environment = AgentProcessEnvironment.minimal()

        #expect(environment["HUSHNOTE_TEST_LEAK"] == nil)
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        // The CLIs read their own credentials out of the home directory, so
        // this one has to survive.
        #expect(environment["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test("The Codex transport spawns an absolute path instead of /usr/bin/env")
    func codexTransportResolvesAnAbsolutePath() async throws {
        let bin = try makeTemporaryBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let tool = try makeExecutable(named: "codex", in: bin, mode: 0o755)
        let transport = ProcessCodexAppServerTransport(
            resolver: AgentExecutableResolver(searchPaths: [bin])
        )

        let executable = try await transport.executable()

        #expect(executable.path == tool.path)
        // "codex" used to be argv[1] of /usr/bin/env.
        #expect(!(await transport.launchArguments().contains("codex")))
    }
}

func makeTemporaryBin(mode: Int = 0o755) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "hushnote-bin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
}

@discardableResult
func makeExecutable(named name: String, in directory: URL, mode: Int) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
}
