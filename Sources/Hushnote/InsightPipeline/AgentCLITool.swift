import Foundation

/// The three coding-agent CLIs a user is likely already signed into, described
/// well enough to be driven as summarisers.
///
/// They differ in every detail that matters — how tools are switched off, where
/// errors land, whether a schema can be enforced, what the output stream even
/// is — so the differences live here and the provider stays one thing.
public enum AgentCLITool: String, Sendable, CaseIterable {
    case claude
    case codex
    case opencode

    public var executableName: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code CLI"
        case .codex: "Codex CLI"
        case .opencode: "opencode CLI"
        }
    }

    public var descriptorKind: InsightProviderDescriptor.Kind {
        switch self {
        case .claude: .claudeCLI
        case .codex: .codexCLI
        case .opencode: .opencodeCLI
        }
    }

    public var descriptor: InsightProviderDescriptor {
        InsightProviderDescriptor(
            id: "cli-\(rawValue)",
            displayName: displayName,
            kind: descriptorKind,
            sendsTranscriptOffDevice: true
        )
    }

    /// Whether the tool can be held to the output schema, or only asked.
    public var supportsOutputSchema: Bool {
        switch self {
        case .claude, .codex: true
        case .opencode: false
        }
    }

    // MARK: - capability check

    /// Where the flags below are documented, so a version that renamed one can
    /// be caught at launch instead of halfway through a summary.
    public var helpArguments: [String] {
        switch self {
        case .claude: ["--help"]
        case .codex: ["exec", "--help"]
        case .opencode: ["run", "--help"]
        }
    }

    /// Flags the lockdown depends on. Losing any of these silently would mean
    /// running an agent with its tools back on.
    public var requiredHelpFlags: [String] {
        switch self {
        case .claude:
            ["--safe-mode", "--tools", "--output-format", "--no-session-persistence", "--json-schema"]
        case .codex:
            ["--json", "--ephemeral", "--skip-git-repo-check", "--sandbox", "--cd", "--disable", "--output-schema"]
        case .opencode:
            ["--format", "--agent", "--model"]
        }
    }

    /// A second capability check, for lockdowns that `--help` cannot show.
    ///
    /// opencode has no flag for switching its tools off — only
    /// `OPENCODE_CONFIG_CONTENT`, which is undocumented and appears in no help
    /// output. Running `agent list` with that variable set makes its effect
    /// visible: the agent Hushnote defines shows up only when the variable is
    /// still honoured. Verified on this machine, where `hushnote (primary)`
    /// appears in the list with the variable set and not without it.
    public var configurationProbe: (arguments: [String], expecting: String, mechanism: String)? {
        switch self {
        case .claude, .codex:
            // Everything these two rely on is a documented flag, and the
            // required-flag check already covers it.
            nil
        case .opencode:
            (["agent", "list"], Self.opencodeAgentName, "OPENCODE_CONFIG_CONTENT")
        }
    }

    // MARK: - authentication

    public var authProbeArguments: [String] {
        switch self {
        case .claude: ["auth", "status", "--json"]
        case .codex: ["login", "status"]
        case .opencode: ["providers", "list"]
        }
    }

    /// Why the tool is not usable yet, or nil when it is.
    ///
    /// Only claude answers this machine-readably; the other two print text for
    /// a person, so their exit status is what there is to go on.
    public func signInProblem(_ result: AgentProcessResult) -> String? {
        switch self {
        case .claude:
            guard let data = result.standardOutput.data(using: .utf8),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .bool(let loggedIn)? = json["loggedIn"] else {
                return result.exitCode == 0
                    ? nil
                    : "Sign in first: run `claude` in a terminal and follow the prompt."
            }
            return loggedIn
                ? nil
                : "Sign in first: run `claude` in a terminal and follow the prompt."
        case .codex:
            return result.exitCode == 0
                ? nil
                : "Sign in first: run `codex login` in a terminal."
        case .opencode:
            return result.exitCode == 0
                ? nil
                : "Sign in first: run `opencode providers login` in a terminal."
        }
    }

    // MARK: - invocation

    /// The command line, with every switch that keeps this a summariser rather
    /// than an agent.
    public func arguments(
        model: String?,
        request: InsightProviderRequest,
        sandbox: URL,
        schemaFileURL: URL?
    ) -> [String] {
        switch self {
        case .claude:
            var arguments = [
                "-p",
                // Without this a canary CLAUDE.md in the working directory is
                // obeyed, and the user's personal configuration is billed on
                // every summary.
                "--safe-mode",
                "--tools", "",
                "--output-format", "json",
                "--no-session-persistence",
                // Claude has a real second channel for instructions, so the
                // transcript travels alone on stdin.
                "--append-system-prompt", request.systemPrompt
            ]
            if let schema = encodedSchema(request.outputSchema) {
                arguments += ["--json-schema", schema]
            }
            if let model { arguments += ["--model", model] }
            return arguments
        case .codex:
            var arguments = [
                "exec",
                "--json",
                "--ephemeral",
                "--skip-git-repo-check",
                // Long forms on purpose: these are the names the startup
                // capability check looks for in --help, so the invocation and
                // the check cannot drift apart.
                "--sandbox", "read-only",
                "--cd", sandbox.path,
                "-c", "project_doc_max_bytes=0",
                "-c", "include_environment_context=false",
                "-c", "tools.web_search=false",
                "--disable", "shell_tool",
                "--disable", "unified_exec",
                "--disable", "view_image"
            ]
            if let schemaFileURL { arguments += ["--output-schema", schemaFileURL.path] }
            if let model { arguments += ["--model", model] }
            // Read the prompt from stdin.
            arguments.append("-")
            return arguments
        case .opencode:
            var arguments = [
                "run",
                "--format", "json",
                "--agent", Self.opencodeAgentName,
                "--dir", sandbox.path
            ]
            if let model { arguments += ["--model", model] }
            return arguments
        }
    }

    /// What the child sees. Built, never inherited.
    public func environment(sandbox: URL, supportDirectory: URL) -> [String: String] {
        switch self {
        case .claude, .codex:
            return AgentProcessEnvironment.minimal()
        case .opencode:
            // opencode writes every conversation into a shared database with no
            // off switch. OPENCODE_DB moves it somewhere Hushnote can delete;
            // the config disables the tools, since opencode has no flag for it.
            return AgentProcessEnvironment.minimal(extra: [
                "OPENCODE_DB": supportDirectory.appending(path: "oc.db").path,
                "OPENCODE_CONFIG_CONTENT": Self.opencodeConfigContent,
                "OPENCODE_DISABLE_PROJECT_CONFIG": "1"
            ])
        }
    }

    /// What goes down the pipe.
    ///
    /// Only claude has a channel for instructions that is not the prompt, so
    /// for the other two the instruction and the transcript share one stream.
    /// What keeps that boundary meaningful is that the prompt builder has
    /// already neutralised the angle brackets in the transcript, so no spoken
    /// sentence can close the transcript block and open something else.
    public func standardInput(for request: InsightProviderRequest) -> String {
        switch self {
        case .claude: request.userPrompt
        case .codex, .opencode: request.systemPrompt + "\n\n" + request.userPrompt
        }
    }

    // MARK: - output

    /// The model's answer, or a description of why there isn't one.
    ///
    /// Errors arrive on opposite streams per tool, and the exit code is the
    /// least reliable signal of the three: codex exits non-zero carrying a
    /// perfectly good JSONL error object, and claude exits zero carrying
    /// `is_error`.
    public func result(_ result: AgentProcessResult) throws -> String {
        switch self {
        case .claude: try claudeResult(result)
        case .codex: try codexResult(result)
        case .opencode: try opencodeResult(result)
        }
    }

    private func claudeResult(_ result: AgentProcessResult) throws -> String {
        guard let data = result.standardOutput.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw failure(stderr: result.standardError, exitCode: result.exitCode)
        }
        if let denials = json["permission_denials"]?.arrayValue, !denials.isEmpty {
            // The tools were supposed to be off. If one was attempted, the
            // lockdown did not hold and this run is not trustworthy.
            let name = denials.first?["tool_name"]?.stringValue ?? "unknown"
            throw InsightProviderError.agentAttemptedTool(name)
        }
        if json["is_error"] == .bool(true) {
            throw InsightProviderError.rpcError(
                code: -1,
                message: json["result"]?.stringValue ?? "Claude reported an error"
            )
        }
        if let structured = json["structured_output"], structured != .null,
           let encoded = try? JSONEncoder().encode(structured) {
            return String(decoding: encoded, as: UTF8.self)
        }
        guard let text = json["result"]?.stringValue else {
            throw InsightProviderError.malformedResponse
        }
        return text
    }

    private func codexResult(_ result: AgentProcessResult) throws -> String {
        var message: String?
        var completed = false
        for event in jsonLines(result.standardOutput) {
            switch event["type"]?.stringValue {
            case "item.completed":
                if event["item"]?["type"]?.stringValue == "agent_message",
                   let text = event["item"]?["text"]?.stringValue {
                    message = text
                }
            case "turn.completed":
                completed = true
            case "turn.failed", "error":
                throw InsightProviderError.rpcError(
                    code: -1,
                    message: event["error"]?["message"]?.stringValue
                        ?? event["message"]?.stringValue
                        ?? "The Codex turn failed"
                )
            default:
                continue
            }
        }
        guard completed, let message else {
            throw failure(stderr: result.standardError, exitCode: result.exitCode)
        }
        return message
    }

    private func opencodeResult(_ result: AgentProcessResult) throws -> String {
        var text = ""
        var finished = false
        for event in jsonLines(result.standardOutput) {
            switch event["type"]?.stringValue {
            case "text":
                text += event["part"]?["text"]?.stringValue ?? event["text"]?.stringValue ?? ""
            case "step_finish":
                finished = true
            default:
                continue
            }
        }
        guard finished, !text.isEmpty else {
            throw failure(stderr: result.standardError, exitCode: result.exitCode)
        }
        return text
    }

    private func jsonLines(_ output: String) -> [JSONValue] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    /// A failure with the tool's own words in it, taken from whichever stream
    /// it chose to use.
    private func failure(stderr: String, exitCode: Int32) -> InsightProviderError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return exitCode == 0
                ? .malformedResponse
                : .processExited(exitCode)
        }
        return .rpcError(code: Int(exitCode), message: String(message.prefix(500)))
    }

    private func encodedSchema(_ schema: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(schema) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static let opencodeAgentName = "hushnote"

    /// Every tool opencode has, off. There is no flag for this, only config,
    /// and only through the environment when the project config is disabled.
    static let opencodeConfigContent = #"""
    {"agent":{"hushnote":{"mode":"primary","tools":{"bash":false,"edit":false,"write":false,"read":false,"grep":false,"glob":false,"list":false,"patch":false,"todowrite":false,"webfetch":false,"task":false,"skill":false}}}}
    """#
}
