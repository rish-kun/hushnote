import Foundation
import Testing
@testable import Hushnote

/// A blank box against thirty minutes of speech is a cold start. Every
/// suggestion is derived on-device from what the meeting already holds —
/// deliberately not from a model call, which would spend the user's quota and
/// send the transcript off-device before they had asked for anything.
@Suite("Ask suggestions")
struct AskSuggestionPolicyTests {
    @Test("A meeting's own unresolved questions are used verbatim")
    func openQuestionsWin() {
        let suggestions = AskSuggestionPolicy.suggestions(
            openQuestions: ["Who owns the index migration?"],
            topics: ["sharding"],
            decisions: [],
            speakers: [],
            template: .general
        )
        #expect(suggestions.first?.text == "Who owns the index migration?")
        #expect(suggestions.first?.origin == .openQuestion)
    }

    /// With no summary yet there is still something honest to offer.
    @Test("A meeting with no summary still gets starting points")
    func templateFallback() {
        let suggestions = AskSuggestionPolicy.suggestions(
            openQuestions: [], topics: [], decisions: [], speakers: [], template: .standup
        )
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.origin == .template })
        #expect(suggestions.contains { $0.text == "What is blocked?" })
    }

    @Test("The list is capped and never repeats itself")
    func cappedAndDistinct() {
        let suggestions = AskSuggestionPolicy.suggestions(
            openQuestions: ["What is blocked?", "What is blocked?"],
            topics: ["a", "b", "c", "d", "e"],
            decisions: ["we ship in October"],
            speakers: ["Ada"],
            template: .standup
        )
        #expect(suggestions.count == AskSuggestionPolicy.limit)
        #expect(Set(suggestions.map(\.text)).count == suggestions.count)
    }

    /// The caption is what makes the list read as earned rather than canned,
    /// and the weakest variant teaches that Summary sharpens Ask.
    @Test("The caption names where the suggestions came from")
    func caption() {
        let fromSummary = AskSuggestionPolicy.suggestions(
            openQuestions: ["Why?"], topics: [], decisions: [], speakers: [], template: .general
        )
        #expect(AskSuggestionPolicy.caption(for: fromSummary).contains("summary"))

        let fromTemplate = AskSuggestionPolicy.suggestions(
            openQuestions: [], topics: [], decisions: [], speakers: [], template: .general
        )
        #expect(AskSuggestionPolicy.caption(for: fromTemplate).contains("Generate a summary"))
    }

    /// "Speaker 2" is a placeholder, not a person, and asking what it committed
    /// to tells the user nothing.
    @Test("Default speaker names are never suggested")
    func defaultNames() {
        #expect(AskSuggestionPolicy.isDefaultName("Speaker 1"))
        #expect(AskSuggestionPolicy.isDefaultName("speaker"))
        #expect(AskSuggestionPolicy.isDefaultName("Ada") == false)

        let named = AskSuggestionPolicy.namedSpeakers(
            lineCountsBySpeaker: ["Speaker 1": 40, "Ada": 12, "Grace": 1]
        )
        // Grace is below the floor; Speaker 1 is not a name.
        #expect(named == ["Ada"])
    }

    @Test("A decision is trimmed to something that reads in a question")
    func clause() {
        #expect(
            AskSuggestionPolicy.firstClause(of: "We ship in October, behind a flag.")
                == "we ship in October"
        )
    }
}

/// Three genuinely different privacy stories. The third is the one users most
/// misread, because a command that runs locally still sends the transcript on.
@Suite("Ask disclosure")
struct AskDisclosurePolicyTests {
    @Test("A local provider promises nothing leaves the Mac")
    func local() {
        let disclosure = AskDisclosurePolicy.disclosure(
            provider: .local, model: "mistral", transcriptDuration: 2_040, wordCount: 5_200
        )
        #expect(disclosure.reach == .onDevice)
        #expect(disclosure.badge == "On device")
        #expect(disclosure.detail.contains("Nothing leaves it"))
        #expect(disclosure.actionTitle == "Change model")
    }

    @Test("A cloud provider names itself and what it is sent")
    func cloud() {
        let disclosure = AskDisclosurePolicy.disclosure(
            provider: .anthropic, model: "claude", transcriptDuration: 2_040, wordCount: 5_200
        )
        #expect(disclosure.reach == .cloudAPI)
        #expect(disclosure.badge == "Off device")
        #expect(disclosure.detail.contains("Anthropic API"))
        #expect(disclosure.detail.contains("34 min"))
        #expect(disclosure.detail.contains("5,200".replacingOccurrences(of: ",", with: "")))
    }

    /// The case nobody had written copy for.
    @Test("An agent CLI is off device, and says why")
    func cli() {
        for provider in [InsightProviderChoice.claudeCLI, .codexCLI, .opencodeCLI] {
            let disclosure = AskDisclosurePolicy.disclosure(
                provider: provider, model: nil, transcriptDuration: 600, wordCount: 900
            )
            #expect(disclosure.reach == .cliToCloud)
            #expect(disclosure.badge == "Off device")
            #expect(disclosure.detail.contains("sends the transcript"))
        }
    }

    @Test("Word counts are rounded rather than stated to the word")
    func words() {
        #expect(AskDisclosurePolicy.approximateWords(5_243) == "5200")
        #expect(AskDisclosurePolicy.approximateWords(120) == "120")
        #expect(AskDisclosurePolicy.approximateWords(0) == "0")
    }
}
