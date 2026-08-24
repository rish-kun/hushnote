import Foundation

/// Where to start, when the meeting is thirty minutes long and the box is
/// empty.
///
/// Every suggestion is derived on-device from what this meeting already
/// contains. Deliberately *not* a model call: spending the user's quota — and
/// sending the transcript off-device — to fill an empty state, before the user
/// has asked for anything, is indefensible on a privacy-first app.
enum AskSuggestionPolicy {
    struct Suggestion: Equatable, Identifiable, Sendable {
        let id: String
        let text: String
        let origin: Origin
    }

    enum Origin: Equatable, Sendable {
        case openQuestion
        case topic
        case decision
        case speaker
        case template
    }

    static let limit = 4

    /// A speaker has to say enough to be worth asking about, and must have been
    /// given a real name — "Speaker 2" tells the user nothing.
    static let minimumSpeakerLines = 3

    nonisolated static func suggestions(
        openQuestions: [String],
        topics: [String],
        decisions: [String],
        speakers: [String],
        template: MeetingTemplate,
        limit: Int = AskSuggestionPolicy.limit
    ) -> [Suggestion] {
        var suggestions: [Suggestion] = []

        // The meeting's own unresolved questions are the best possible prompt:
        // they are already phrased as questions, by the people who were there.
        for question in openQuestions {
            suggestions.append(.init(id: "open-\(question)", text: question, origin: .openQuestion))
        }
        for topic in topics {
            suggestions.append(
                .init(id: "topic-\(topic)", text: "What was decided about \(topic)?", origin: .topic)
            )
        }
        for decision in decisions {
            let clause = firstClause(of: decision)
            suggestions.append(
                .init(id: "decision-\(decision)", text: "Why did we decide \(clause)?", origin: .decision)
            )
        }
        for speaker in speakers {
            suggestions.append(
                .init(id: "speaker-\(speaker)", text: "What did \(speaker) commit to?", origin: .speaker)
            )
        }
        for question in templateQuestions(for: template) {
            suggestions.append(.init(id: "template-\(question)", text: question, origin: .template))
        }

        var seen = Set<String>()
        return suggestions
            .filter { seen.insert($0.text.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Names the source, so the list reads as earned rather than canned — and
    /// so the weakest variant does real work by teaching that Summary and Ask
    /// reinforce each other.
    nonisolated static func caption(for suggestions: [Suggestion]) -> String {
        let origins = Set(suggestions.map(\.origin))
        if origins.contains(.openQuestion) || origins.contains(.topic) || origins.contains(.decision) {
            return "These come from this meeting's summary."
        }
        if origins.contains(.speaker) {
            return "These come from who spoke. Generate a summary for sharper suggestions."
        }
        return "Starting points for any meeting. Generate a summary to get suggestions from what was actually said."
    }

    /// Speakers worth naming: given a real name, and heard from more than once.
    nonisolated static func namedSpeakers(
        lineCountsBySpeaker: [String: Int],
        minimum: Int = AskSuggestionPolicy.minimumSpeakerLines
    ) -> [String] {
        lineCountsBySpeaker
            .filter { $0.value >= minimum && !isDefaultName($0.key) }
            .keys
            .sorted()
    }

    /// "Speaker 1" and friends are placeholders, not people.
    nonisolated static func isDefaultName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("speaker") else { return false }
        let rest = trimmed.dropFirst("speaker".count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || Int(rest) != nil
    }

    nonisolated static func templateQuestions(for template: MeetingTemplate) -> [String] {
        switch template {
        case .general:
            ["What was decided?", "What is still unresolved?"]
        case .oneOnOne:
            ["What did we agree to follow up on?", "What concerns were raised?"]
        case .standup:
            ["What is blocked?", "What shipped since last time?"]
        case .interview:
            ["What experience was described?", "What questions went unanswered?"]
        case .clientCall:
            ["What did we commit to?", "What did the client ask for?"]
        }
    }

    /// Trims a decision down to something that reads inside "Why did we decide…".
    nonisolated static func firstClause(of decision: String) -> String {
        let trimmed = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = trimmed.split(separator: ",").first.map(String.init) ?? trimmed
        let lowered = clause.prefix(1).lowercased() + clause.dropFirst()
        return lowered.trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
    }
}

/// What the user is actually agreeing to when they press Ask.
///
/// There are three genuinely different privacy stories here, and the third —
/// an agent CLI — is the one users will most misread, because "it runs a local
/// command" feels local. It is not: the command sends the transcript onward.
enum AskDisclosurePolicy {
    enum Reach: Equatable, Sendable {
        case onDevice
        case cloudAPI
        case cliToCloud
    }

    struct Disclosure: Equatable, Sendable {
        let reach: Reach
        let badge: String
        let providerLine: String
        let detail: String
        let actionTitle: String
    }

    nonisolated static func reach(for provider: InsightProviderChoice) -> Reach {
        if provider.isLocal { return .onDevice }
        return provider.isAgentCLI ? .cliToCloud : .cloudAPI
    }

    nonisolated static func disclosure(
        provider: InsightProviderChoice,
        model: String?,
        transcriptDuration: TimeInterval,
        wordCount: Int
    ) -> Disclosure {
        let reach = reach(for: provider)
        let providerLine = [provider.displayName, model]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let payload = "\(DurationText.approximateMinutes(transcriptDuration)), about \(approximateWords(wordCount)) words"

        return switch reach {
        case .onDevice:
            Disclosure(
                reach: reach,
                badge: "On device",
                providerLine: providerLine,
                detail: "Questions are answered on this Mac. Nothing leaves it.",
                actionTitle: "Change model"
            )
        case .cloudAPI:
            Disclosure(
                reach: reach,
                badge: "Off device",
                providerLine: providerLine,
                detail: "Each question sends this meeting's full transcript (\(payload)) to \(provider.displayName).",
                actionTitle: "Change provider"
            )
        case .cliToCloud:
            Disclosure(
                reach: reach,
                badge: "Off device",
                providerLine: providerLine,
                detail: "Hushnote runs a command on this Mac. That command sends the transcript (\(payload)) onward under your existing sign-in.",
                actionTitle: "Change provider"
            )
        }
    }

    nonisolated static func approximateWords(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(max(0, count))" }
        return "\((count / 100) * 100)"
    }
}
