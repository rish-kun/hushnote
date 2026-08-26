import CryptoKit
import Foundation

/// Turns a meeting into the flat value that gets uploaded, and reduces that
/// value to the checksum sync decisions are made on.
///
/// Pure and `nonisolated` throughout: everything it needs is passed in, so the
/// whole of what leaves the machine can be asserted in a test without a
/// database, a coordinator, or a network.
enum SharePayloadBuilder {
    /// `includes` is honoured strictly. A section that is off is `nil` in the
    /// payload, not an empty string or an empty array — content not included in
    /// a share is the only content guaranteed never to leave the machine, and
    /// that guarantee is worth nothing if "off" and "empty" look the same on
    /// the wire.
    ///
    /// - Parameters:
    ///   - summary: the structured insights, whose lists become the payload's.
    ///   - summaryText: the prose actually displayed for this meeting, which may
    ///     be a user-edited summary version rather than the model's overview.
    ///     Omitted, the overview is used.
    nonisolated static func build(
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        includes: ShareIncludes,
        transcript: [TranscriptSegment],
        notes: String,
        summary: MeetingInsights?,
        summaryText: String? = nil
    ) -> SharePayload {
        SharePayload(
            title: WhisperSpecialToken.cleanedSegmentText(title),
            startedAt: startedAt,
            durationSeconds: max(0, duration),
            includes: includes,
            transcript: includes.transcript ? shareSegments(transcript) : nil,
            notes: includes.notes ? shareNotes(notes) : nil,
            summary: includes.summary ? shareSummary(summary, text: summaryText) : nil
        )
    }

    /// The same build, for a caller that already holds the summary as flat
    /// text.
    ///
    /// `AppViewState.InsightWorkspaceState` keeps topics, decisions, actions
    /// and open questions as `[String]` — the citations have already been
    /// resolved away by the time the workspace renders them. Reconstructing a
    /// `MeetingInsights` from those strings would mean inventing the
    /// `CitedInsight` values it requires, so the flat form is passed straight
    /// through instead.
    nonisolated static func build(
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        includes: ShareIncludes,
        transcript: [TranscriptSegment],
        notes: String,
        preparedSummary: SharePayload.Summary?
    ) -> SharePayload {
        SharePayload(
            title: WhisperSpecialToken.cleanedSegmentText(title),
            startedAt: startedAt,
            durationSeconds: max(0, duration),
            includes: includes,
            transcript: includes.transcript ? shareSegments(transcript) : nil,
            notes: includes.notes ? shareNotes(notes) : nil,
            summary: includes.summary ? preparedSummary : nil
        )
    }

    /// `nil` when there is no summary text, so a share that includes the
    /// summary of a meeting that has none renders no empty section.
    nonisolated static func summary(
        text: String,
        topics: [String],
        decisions: [String],
        actions: [String],
        openQuestions: [String]
    ) -> SharePayload.Summary? {
        let overview = WhisperSpecialToken.cleanedSegmentText(text)
        guard !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SharePayload.Summary(
            text: overview,
            topics: cleaned(topics),
            decisions: cleaned(decisions),
            actions: cleaned(actions),
            openQuestions: cleaned(openQuestions)
        )
    }

    /// A stable fingerprint of the payload's *content*.
    ///
    /// Stability is the whole point. Keys are sorted and dates use one fixed
    /// strategy, because `JSONEncoder`'s dictionary order and default date
    /// encoding are not promised to be reproducible across runs. A checksum
    /// that drifts on identical content re-uploads the same transcript forever;
    /// one that collapses distinct content never uploads an edit at all.
    nonisolated static func checksum(_ payload: SharePayload) -> String {
        let digest = SHA256.hash(data: encodedPayload(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes that are both hashed and uploaded, so the server always holds
    /// exactly the content the checksum was taken over.
    nonisolated static func encodedPayload(_ payload: SharePayload) -> Data {
        // `SharePayload` is a plain value of strings, numbers and dates, so this
        // cannot fail. The fallback is still content-derived rather than a
        // constant: two different payloads must never reduce to one checksum.
        (try? encoder.encode(payload)) ?? Data(String(describing: payload).utf8)
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Segment ids do not travel: the final pass re-mints them, and an id that
    /// means something on one Mac means nothing anywhere else. Times become
    /// seconds, which is what the page renders.
    ///
    /// Text goes through `WhisperSpecialToken` because shared text is exported
    /// text. A leak here is published, permanent, and in somebody else's hands.
    /// A segment that was nothing but control tokens is dropped rather than
    /// published as an empty paragraph — a publication is a rendering, unlike
    /// the v6 repair migration, which keeps such rows because a migration does
    /// not decide rows out of a user's transcript.
    private nonisolated static func shareSegments(
        _ segments: [TranscriptSegment]
    ) -> [SharePayload.Segment] {
        segments.compactMap { segment in
            let text = WhisperSpecialToken.cleanedSegmentText(segment.text)
            guard !text.isEmpty else { return nil }
            return SharePayload.Segment(
                start: Double(segment.startMilliseconds) / 1_000,
                end: Double(segment.endMilliseconds) / 1_000,
                speaker: segment.speakerName,
                text: text
            )
        }
    }

    /// Notes are the user's own prose and are published verbatim apart from
    /// surrounding whitespace. An included but empty page publishes nothing
    /// rather than an empty heading.
    private nonisolated static func shareNotes(_ notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Citations are dropped with the segment ids they point at. Owner and due
    /// date survive inside the action's text, which is the only place the flat
    /// payload has for them; dropping them silently would publish a list of
    /// tasks belonging to nobody.
    private nonisolated static func shareSummary(
        _ insights: MeetingInsights?,
        text: String?
    ) -> SharePayload.Summary? {
        let overview = text ?? insights?.overview.text
        guard let overview else { return nil }
        return SharePayload.Summary(
            text: WhisperSpecialToken.cleanedSegmentText(overview),
            topics: cleaned(insights?.topics.map(\.text) ?? []),
            decisions: cleaned(insights?.decisions.map(\.text) ?? []),
            actions: cleaned(insights?.actionItems.map(actionText) ?? []),
            openQuestions: cleaned(insights?.openQuestions.map(\.text) ?? [])
        )
    }

    private nonisolated static func actionText(_ action: ActionItemInsight) -> String {
        let attribution = [action.owner, action.dueDate.map { "due \($0)" }]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !attribution.isEmpty else { return action.text }
        return "\(action.text) (\(attribution.joined(separator: ", ")))"
    }

    private nonisolated static func cleaned(_ lines: [String]) -> [String] {
        lines
            .map(WhisperSpecialToken.cleanedSegmentText)
            .filter { !$0.isEmpty }
    }
}
