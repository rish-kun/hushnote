import Foundation

public struct CitationValidator: Sendable {
    public init() {}

    public func validate(
        _ insights: MeetingInsights,
        against transcript: [InsightTranscriptSegment]
    ) -> ValidatedMeetingInsights? {
        let index = Dictionary(transcript.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rejectedClaims = 0
        var rejectedCitations = 0

        func citations(_ proposed: [EvidenceCitation]) -> [EvidenceCitation] {
            proposed.compactMap { citation in
                guard let segment = index[citation.segmentID],
                      containsVerbatim(citation.quote, in: segment.text) else {
                    rejectedCitations += 1
                    return nil
                }
                return EvidenceCitation(
                    segmentID: segment.id,
                    startMilliseconds: segment.startMilliseconds,
                    endMilliseconds: segment.endMilliseconds,
                    quote: citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        func claim(_ proposed: CitedInsight) -> CitedInsight? {
            let validCitations = citations(proposed.citations)
            guard !proposed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !validCitations.isEmpty else {
                rejectedClaims += 1
                return nil
            }
            return CitedInsight(id: proposed.id, text: proposed.text, citations: validCitations)
        }

        func action(_ proposed: ActionItemInsight) -> ActionItemInsight? {
            let validCitations = citations(proposed.citations)
            guard !proposed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !validCitations.isEmpty else {
                rejectedClaims += 1
                return nil
            }
            return ActionItemInsight(
                id: proposed.id,
                text: proposed.text,
                owner: proposed.owner,
                dueDate: proposed.dueDate,
                citations: validCitations
            )
        }

        guard let overview = claim(insights.overview) else { return nil }
        let validated = MeetingInsights(
            overview: overview,
            keyPoints: insights.keyPoints.compactMap(claim),
            decisions: insights.decisions.compactMap(claim),
            actionItems: insights.actionItems.compactMap(action),
            openQuestions: insights.openQuestions.compactMap(claim),
            risks: insights.risks.compactMap(claim),
            topics: insights.topics.compactMap(claim)
        )
        return ValidatedMeetingInsights(
            insights: validated,
            validation: InsightValidationReport(
                rejectedClaims: rejectedClaims,
                rejectedCitations: rejectedCitations
            )
        )
    }

    public func validate(
        _ answer: MeetingQuestionAnswer,
        against transcript: [InsightTranscriptSegment]
    ) -> ValidatedQuestionAnswer? {
        let index = Dictionary(transcript.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rejected = 0
        let valid = answer.citations.compactMap { citation -> EvidenceCitation? in
            guard let segment = index[citation.segmentID],
                  containsVerbatim(citation.quote, in: segment.text) else {
                rejected += 1
                return nil
            }
            return EvidenceCitation(
                segmentID: segment.id,
                startMilliseconds: segment.startMilliseconds,
                endMilliseconds: segment.endMilliseconds,
                quote: citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !answer.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !valid.isEmpty else { return nil }
        return ValidatedQuestionAnswer(
            answer: MeetingQuestionAnswer(
                question: answer.question,
                answer: answer.answer,
                citations: valid
            ),
            validation: InsightValidationReport(rejectedCitations: rejected)
        )
    }

    private func containsVerbatim(_ quote: String, in transcript: String) -> Bool {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return transcript.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

