import Foundation
import Testing
@testable import Hushnote

/// Choosing which model a coding-agent CLI runs.
///
/// Three separable pieces, all pure: what a typed model name is allowed to be,
/// where the choice is remembered, and how each tool's own output is read back
/// into a list of identifiers. Nothing here launches a CLI -- every listing is
/// a fixture captured from the real command named in the suite comment.
@Suite("Agent CLI model selection")
struct AgentCLIModelSelectionTests {

    // MARK: - what a model name may be

    @Test("Nothing typed means the CLI's own default, not an empty --model")
    func emptyMeansDefault() {
        #expect(AgentCLIModelName.resolve("") == .unset)
        #expect(AgentCLIModelName.resolve("   ") == .unset)
        #expect(AgentCLIModelName.resolve("\n\t ") == .unset)
        #expect(AgentCLIModelName.argument("") == nil)
        #expect(AgentCLIModelName.argument("  ") == nil)
    }

    @Test("Surrounding whitespace is trimmed off an otherwise good name")
    func trimsAroundName() {
        #expect(AgentCLIModelName.resolve("  opus\n") == .valid("opus"))
        #expect(AgentCLIModelName.argument(" opencode-go/glm-5.3 ") == "opencode-go/glm-5.3")
    }

    @Test("A name that starts with a dash is refused, not passed on as a flag")
    func refusesLeadingDash() {
        for raw in ["--help", "-p", " --dangerously-skip-permissions", "—em-dash"] {
            guard case .rejected = AgentCLIModelName.resolve(raw) else {
                Issue.record("\(raw) should have been refused")
                continue
            }
            #expect(AgentCLIModelName.argument(raw) == nil)
        }
    }

    @Test("A name with whitespace inside it is refused")
    func refusesInteriorWhitespace() {
        for raw in ["gpt 5", "sonnet\n--tools", "a\tb"] {
            guard case .rejected = AgentCLIModelName.resolve(raw) else {
                Issue.record("\(raw) should have been refused")
                continue
            }
        }
    }

    @Test("The refusal says why, so the field can explain itself")
    func explainsRefusal() {
        guard case .rejected(let reason) = AgentCLIModelName.resolve("--model") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("Ordinary identifiers the three CLIs actually use are accepted")
    func acceptsRealIdentifiers() {
        for raw in [
            "opus", "sonnet", "claude-fable-5",
            "gpt-5.1-codex-max", "o3",
            "opencode-go/glm-5.3", "anthropic/claude-sonnet-4-5-20250929"
        ] {
            #expect(AgentCLIModelName.resolve(raw) == .valid(raw), "\(raw) should be accepted")
        }
    }

    // MARK: - where the choice is remembered

    @Test("Every tool has its own key, so one CLI's model is never the other's")
    func keysArePerTool() {
        let keys = AgentCLITool.allCases.map(AgentCLIModelDefaults.key(for:))
        #expect(Set(keys).count == AgentCLITool.allCases.count)
        #expect(AgentCLIModelDefaults.key(for: .codex) == "agentCLI.model.codex")
    }

    @Test("A model stored for one CLI does not come back for another")
    func storesPerTool() {
        let defaults = Self.scratchDefaults()
        AgentCLIModelDefaults.store("gpt-5.1-codex-max", for: .codex, in: defaults)

        #expect(AgentCLIModelDefaults.model(for: .codex, from: defaults) == "gpt-5.1-codex-max")
        #expect(AgentCLIModelDefaults.model(for: .opencode, from: defaults) == nil)
        #expect(AgentCLIModelDefaults.model(for: .claude, from: defaults) == nil)

        AgentCLIModelDefaults.store("opencode-go/glm-5.3", for: .opencode, in: defaults)
        #expect(AgentCLIModelDefaults.model(for: .codex, from: defaults) == "gpt-5.1-codex-max")
        #expect(AgentCLIModelDefaults.model(for: .opencode, from: defaults) == "opencode-go/glm-5.3")
    }

    @Test("Clearing the field goes back to the CLI's default rather than storing blank")
    func clearingRestoresDefault() {
        let defaults = Self.scratchDefaults()
        AgentCLIModelDefaults.store("opus", for: .claude, in: defaults)
        AgentCLIModelDefaults.store("   ", for: .claude, in: defaults)

        #expect(AgentCLIModelDefaults.model(for: .claude, from: defaults) == nil)
        #expect(defaults.string(forKey: AgentCLIModelDefaults.key(for: .claude)) == nil)
    }

    @Test("A refused name is never stored and never read back")
    func refusedNameNeverPersists() {
        let defaults = Self.scratchDefaults()
        AgentCLIModelDefaults.store("--sandbox", for: .codex, in: defaults)
        #expect(AgentCLIModelDefaults.model(for: .codex, from: defaults) == nil)

        // Even a value written straight into the domain by hand is refused on
        // the way out, because it becomes an argument vector element.
        defaults.set("--sandbox", forKey: AgentCLIModelDefaults.key(for: .codex))
        #expect(AgentCLIModelDefaults.model(for: .codex, from: defaults) == nil)
    }

    // MARK: - reading each tool's own listing

    /// Captured verbatim from `opencode models` on 2026-08-18 (opencode 1.18.18).
    static let opencodeModelsOutput = """
    opencode/big-pickle
    opencode/deepseek-v4-flash-free
    opencode/hy3-free
    opencode-go/glm-5.3
    opencode-go/gpt-5.6-luna
    opencode-go/kimi-k2.7-code
    """

    /// Captured verbatim from `claude --help` on 2026-08-18 (Claude Code
    /// 2.1.234), with the neighbouring options kept so the block boundaries are
    /// the real ones.
    static let claudeHelpOutput = """
      --mcp-config <configs...>             Load MCP servers from JSON files or
                                            strings (space-separated)
      --model <model>                       Model for the current session. Provide
                                            an alias for the latest model (e.g.
                                            'fable', 'opus', or 'sonnet') or a
                                            model's full name (e.g.
                                            'claude-fable-5').
      -n, --name <name>                     Set a display name for this session
                                            (shown in the prompt box, /resume
                                            picker, and terminal title)
      --no-chrome                           Disable Claude in Chrome integration
    """

    @Test("opencode's one-per-line listing becomes identifiers")
    func readsOpencodeListing() {
        guard let listing = AgentCLITool.opencode.modelListing else {
            Issue.record("opencode lists its models")
            return
        }
        #expect(listing.arguments == ["models"])

        let models = listing.models(in: Self.opencodeModelsOutput)
        #expect(models.count == 6)
        #expect(models.first == "opencode/big-pickle")
        #expect(models.contains("opencode-go/glm-5.3"))
    }

    @Test("claude names its aliases inside --model's own help, and only those")
    func readsClaudeHelp() {
        guard let listing = AgentCLITool.claude.modelListing else {
            Issue.record("claude names its models in --help")
            return
        }
        #expect(listing.arguments == ["--help"])

        let models = listing.models(in: Self.claudeHelpOutput)
        #expect(models == ["fable", "opus", "sonnet", "claude-fable-5"])
    }

    @Test("The apostrophe in \"a model's full name\" is not read as a model")
    func ignoresApostrophes() {
        let models = AgentCLITool.claude.modelListing?.models(in: Self.claudeHelpOutput) ?? []
        #expect(models.allSatisfy { !$0.contains(" ") })
        #expect(!models.contains { $0.hasPrefix("s ") })
    }

    @Test("Neighbouring options are not mined for models")
    func staysInsideTheFlagBlock() {
        let models = AgentCLITool.claude.modelListing?.models(in: Self.claudeHelpOutput) ?? []
        #expect(!models.contains("resume"))
        #expect(!models.contains("configs"))
    }

    @Test("codex names none of its models, and says so rather than guessing")
    func codexListsNothing() {
        #expect(AgentCLITool.codex.modelListing == nil)
    }

    @Test("A listing that failed, hung or printed a complaint yields no models")
    func toleratesJunk() {
        let junk = """
        error: not logged in
        Run `opencode providers login` first.

        """
        #expect(AgentCLITool.opencode.modelListing?.models(in: junk) == [])
        #expect(AgentCLITool.opencode.modelListing?.models(in: "") == [])
        #expect(AgentCLITool.claude.modelListing?.models(in: "command not found") == [])
    }

    @Test("Nothing read out of a listing could be mistaken for a flag")
    func listedModelsAreAlwaysPassable() {
        for tool in AgentCLITool.allCases {
            guard let listing = tool.modelListing else { continue }
            let fixture = tool == .opencode ? Self.opencodeModelsOutput : Self.claudeHelpOutput
            for model in listing.models(in: fixture) {
                #expect(AgentCLIModelName.argument(model) == model, "\(model) must be passable")
            }
        }
    }

    @Test("Duplicates in a listing are shown once")
    func deduplicates() {
        let repeated = "opencode/big-pickle\nopencode/big-pickle\nopencode/hy3-free"
        #expect(
            AgentCLITool.opencode.modelListing?.models(in: repeated)
                == ["opencode/big-pickle", "opencode/hy3-free"]
        )
    }

    // MARK: - what the control offers

    @Test("With nothing discovered and nothing stored there is no menu to show")
    func degradesToPlainEntry() {
        #expect(AgentCLIModelMenu.options(discovered: [], stored: nil) == [])
        #expect(!AgentCLIModelMenu.showsMenu(discovered: [], stored: nil))
    }

    @Test("A stored model a listing never named is still offered")
    func keepsTheStoredChoiceReachable() {
        #expect(
            AgentCLIModelMenu.options(discovered: [], stored: "gpt-5.1-codex-max")
                == ["gpt-5.1-codex-max"]
        )
        #expect(AgentCLIModelMenu.showsMenu(discovered: [], stored: "gpt-5.1-codex-max"))
        #expect(
            AgentCLIModelMenu.options(discovered: ["opus", "sonnet"], stored: "claude-fable-5")
                == ["opus", "sonnet", "claude-fable-5"]
        )
    }

    @Test("A stored model the listing already names is not offered twice")
    func doesNotRepeatTheStoredChoice() {
        #expect(
            AgentCLIModelMenu.options(discovered: ["opus", "sonnet"], stored: "sonnet")
                == ["opus", "sonnet"]
        )
    }

    private static func scratchDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "hushnote.tests.\(UUID().uuidString)")!
        for tool in AgentCLITool.allCases {
            defaults.removeObject(forKey: AgentCLIModelDefaults.key(for: tool))
        }
        return defaults
    }
}
