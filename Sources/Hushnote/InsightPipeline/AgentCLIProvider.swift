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

        if let check = tool.configurationProbe {
            do {
                let result = try await probe(
                    executable,
                    arguments: check.arguments,
                    environment: nil
                )
                guard result.standardOutput.contains(check.expecting) else {
                    return .unavailable(
                        """
                        This version of \(tool.executableName) no longer honours \
                        \(check.mechanism). Hushnote uses it to switch the agent's tools off, so \
                        it will not run it. Update \(tool.executableName) or pick another provider.
                        """
                    )
                }
            } catch {
                return .unavailable(
                    "\(tool.executableName) could not confirm that \(check.mechanism) still applies."
                )
            }
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

    /// The models this tool says it takes, for Settings to offer.
    ///
    /// Every way this can go wrong ends in an empty list rather than an error:
    /// the tool may name no models at all, may not be installed, may be signed
    /// out, may need a network it does not have, or may have renamed the
    /// command since. None of that stops a summary, because the model can
    /// always be typed instead — so none of it is worth surfacing as a failure.
    ///
    /// Only the listing command runs. It reads; it is never given a prompt.
    ///
    /// Asked in the very environment a summary runs in, for the same reason the
    /// lockdown probe is: opencode writes into a shared database with no off
    /// switch, so even a listing has to be pointed at a temporary one, and the
    /// models it names under that environment are the models it will actually
    /// have when a meeting is sent to it.
    public func availableModels() async -> [String] {
        guard let listing = tool.modelListing,
              let executable = try? resolver.resolve(tool.executableName),
              let result = try? await probe(
                  executable,
                  arguments: listing.arguments,
                  environment: nil
              )
        else { return [] }
        return listing.models(in: result.standardOutput + "\n" + result.standardError)
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

    /// Runs a short read-only command against the tool.
    ///
    /// `environment` defaults to the very environment a real summary uses, so
    /// that a probe of the lockdown is a probe of the lockdown as configured
    /// and not of some cleaner arrangement that only exists here.
    private func probe(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = AgentProcessEnvironment.minimal()
    ) async throws -> AgentProcessResult {
        let sandbox = try AgentSandboxDirectory.make(label: "\(tool.rawValue)-probe")
        defer { sandbox.remove() }
        let support = try AgentSandboxDirectory.make(label: "\(tool.rawValue)-probe-support")
        defer { support.remove() }
        return try await runner.run(
            AgentProcessInvocation(
                executableURL: executable,
                arguments: arguments,
                environment: environment
                    ?? tool.environment(sandbox: sandbox.url, supportDirectory: support.url),
                workingDirectory: sandbox.url,
                standardInput: "",
                timeout: .seconds(20)
            )
        )
    }
}
