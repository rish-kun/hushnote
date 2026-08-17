import Foundation

/// Drives a coding-agent CLI the user is already signed into, so that
/// summarising a meeting needs no new API key.
///
/// All three tools are one-prompt-in / one-result-out, so one actor covers
/// them; everything that differs lives in `AgentCLITool`. What they have in
/// common is the part that matters here: each is an agent by default, each has
/// filesystem tools, and each reads context out of the directory it is started
/// in. So every run is spawned tool-less, in an empty app-private directory,
/// with a built environment and a wall clock of Hushnote's own.
public actor AgentCLIProvider: InsightProvider {
    public nonisolated let descriptor: InsightProviderDescriptor

    private let tool: AgentCLITool
    private let model: String?
    private let resolver: AgentExecutableResolver
    private let runner: any AgentProcessRunner
    private let timeout: Duration
    private let witness: SharedDatabaseWitness?

    public init(
        tool: AgentCLITool,
        model: String? = nil,
        resolver: AgentExecutableResolver = AgentExecutableResolver(),
        runner: any AgentProcessRunner = SubprocessAgentProcessRunner(),
        timeout: Duration = .seconds(300),
        witness: SharedDatabaseWitness? = nil
    ) {
        self.tool = tool
        self.model = model
        self.resolver = resolver
        self.runner = runner
        self.timeout = timeout
        self.witness = witness ?? (tool == .opencode ? .opencodeDefault() : nil)
        self.descriptor = tool.descriptor
    }

    /// Answers three questions in the order that makes a failure legible:
    /// is the tool here, does this version still have the switches the lockdown
    /// depends on, and is the user signed in.
    public func healthCheck() async -> InsightProviderHealth {
        let executable: URL
        do {
            executable = try resolver.resolve(tool.executableName)
        } catch {
            return .unavailable(
                "\(tool.executableName) was not found. Install it, then reopen Settings."
            )
        }

        do {
            let help = try await probe(executable, arguments: tool.helpArguments)
            let documented = help.standardOutput + "\n" + help.standardError
            let missing = tool.requiredHelpFlags.filter { !documented.contains($0) }
            guard missing.isEmpty else {
                return .unavailable(
                    """
                    This version of \(tool.executableName) no longer documents \
                    \(missing.joined(separator: ", ")). Hushnote uses those to switch the agent's \
                    tools off, so it will not run it. Update \(tool.executableName) or pick \
                    another provider.
                    """
                )
            }
        } catch {
            return .unavailable("\(tool.executableName) did not respond to --help.")
        }

        do {
            let probe = try await probe(executable, arguments: tool.authProbeArguments)
            if let problem = tool.signInProblem(probe) {
                return .unavailable("\(tool.displayName): \(problem)")
            }
        } catch {
            return .unavailable("\(tool.displayName) could not report its sign-in status.")
        }
        return .available
    }

    public func complete(_ request: InsightProviderRequest) async throws -> String {
        let executable = try resolver.resolve(tool.executableName)
        let sandbox = try AgentSandboxDirectory.make(label: tool.rawValue)
        defer { sandbox.remove() }
        // Support files live beside the sandbox rather than inside it, so the
        // directory the agent stands in stays empty.
        let support = try AgentSandboxDirectory.make(label: "\(tool.rawValue)-support")
        defer { support.remove() }

        var schemaFileURL: URL?
        if tool.supportsOutputSchema, let data = try? JSONEncoder().encode(request.outputSchema) {
            let url = support.url.appending(path: "schema.json")
            try? data.write(to: url)
            schemaFileURL = url
        }

        let marker = "hushnote-\(UUID().uuidString)"
        let before = witness?.snapshot()

        var prompt = tool.standardInput(for: request)
        if witness != nil { prompt += "\n\n(run id \(marker))" }

        var lastFailure: (any Error)?
        for attempt in 0..<2 {
            let invocation = AgentProcessInvocation(
                executableURL: executable,
                arguments: tool.arguments(
                    model: model,
                    request: request,
                    sandbox: sandbox.url,
                    schemaFileURL: schemaFileURL
                ),
                environment: tool.environment(sandbox: sandbox.url, supportDirectory: support.url),
                workingDirectory: sandbox.url,
                standardInput: prompt,
                timeout: timeout
            )
            do {
                let result = try await runner.run(invocation)
                try assertNoLeak(marker: marker, since: before)
                let text = try tool.result(result)
                if let object = AgentOutputRepair.jsonObject(in: text) { return object }
                lastFailure = InsightProviderError.malformedResponse
            } catch {
                throw error
            }
            guard attempt == 0 else { break }
            prompt += AgentOutputRepair.correction(schemaName: request.outputSchemaName)
        }
        throw lastFailure ?? InsightProviderError.malformedResponse
    }

    /// opencode's `OPENCODE_DB` redirect is undocumented, so it is checked. A
    /// transcript in the user's shared database is not something to discover
    /// later.
    private func assertNoLeak(
        marker: String,
        since before: [URL: SharedDatabaseWitness.Fingerprint]?
    ) throws {
        guard let witness, let before else { return }
        if let file = witness.leak(of: marker, since: before) {
            throw InsightProviderError.transcriptLeaked(file.lastPathComponent)
        }
    }

    private func probe(_ executable: URL, arguments: [String]) async throws -> AgentProcessResult {
        let sandbox = try AgentSandboxDirectory.make(label: "\(tool.rawValue)-probe")
        defer { sandbox.remove() }
        return try await runner.run(
            AgentProcessInvocation(
                executableURL: executable,
                arguments: arguments,
                environment: AgentProcessEnvironment.minimal(),
                workingDirectory: sandbox.url,
                standardInput: "",
                timeout: .seconds(20)
            )
        )
    }
}
