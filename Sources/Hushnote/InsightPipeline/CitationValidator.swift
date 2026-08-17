import Foundation

/// The last gate between model output and a note the user reads, exports and
/// believes.
///
/// It is a gate, not a repair shop. Anything it cannot tie back to the
/// transcript is dropped rather than adjusted, because an adjusted citation is
/// a wrong citation that now looks right.
public struct CitationValidator: Sendable {
    /// A quote shorter than this turns up by chance in any transcript, so it
    /// says nothing about where a claim came from. Segment IDs are guessable,
    /// so the quote is the only real evidence a citation carries.
    static let minimumQuoteCharacters = 10
    static let minimumQuoteWords = 2

    /// A summary bullet is a sentence or two. Anything past this is not a
    /// claim, it is a payload riding in on the `text` field.
    static let maximumClaimCharacters = 2_000
    static let maximumAnswerCharacters = 4_000
    static let maximumAttributeCharacters = 200

    /// How much of a claim's own vocabulary has to appear in the evidence it
    /// cites. Summaries paraphrase, so this is not "all of it"; but a claim
    /// that shares nothing with its quotes is not a summary of them.
    static let minimumGroundedFraction = 0.5

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
                      containsVerbatim(citation.quote, in: segment.text),
                      // A citation that points at the right segment but the
                      // wrong moment used to be silently corrected. Disagreement
                      // is evidence the citation was not derived from the
                      // segment at all.
                      citation.startMilliseconds == segment.startMilliseconds,
                      citation.endMilliseconds == segment.endMilliseconds else {
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
            guard isAcceptableClaim(
                proposed.text,
                limit: Self.maximumClaimCharacters,
                citations: validCitations
            ) else {
                rejectedClaims += 1
                return nil
            }
            return CitedInsight(id: proposed.id, text: proposed.text, citations: validCitations)
        }

        func action(_ proposed: ActionItemInsight) -> ActionItemInsight? {
            let validCitations = citations(proposed.citations)
            guard isAcceptableClaim(
                proposed.text,
                limit: Self.maximumClaimCharacters,
                citations: validCitations
            ),
                  isWithinLimit(proposed.owner),
                  isWithinLimit(proposed.dueDate) else {
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
                  containsVerbatim(citation.quote, in: segment.text),
                  citation.startMilliseconds == segment.startMilliseconds,
                  citation.endMilliseconds == segment.endMilliseconds else {
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
        guard isAcceptableClaim(
            answer.answer,
            limit: Self.maximumAnswerCharacters,
            citations: valid
        ) else { return nil }
        return ValidatedQuestionAnswer(
            answer: MeetingQuestionAnswer(
                question: answer.question,
                answer: answer.answer,
                citations: valid
            ),
            validation: InsightValidationReport(rejectedCitations: rejected)
        )
    }

    private func isAcceptableClaim(
        _ text: String,
        limit: Int,
        citations: [EvidenceCitation]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit, !citations.isEmpty else { return false }
        return isGrounded(trimmed, in: citations)
    }

    private func isWithinLimit(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.count <= Self.maximumAttributeCharacters
    }

    /// Whether a claim's own words come from the evidence it cites.
    ///
    /// Without this, a citation only proves that *some* quote survived; the
    /// claim beside it could say anything at all, and that text is what gets
    /// persisted, rendered and exported.
    private func isGrounded(_ text: String, in citations: [EvidenceCitation]) -> Bool {
        let claimWords = Set(contentWords(text))
        guard !claimWords.isEmpty else { return false }
        let evidence = Set(citations.flatMap { contentWords($0.quote) })
        let grounded = claimWords.filter(evidence.contains).count
        return Double(grounded) >= Double(claimWords.count) * Self.minimumGroundedFraction
    }

    private func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !Self.stopWords.contains($0) }
    }

    /// A quote counts only when it appears in the segment word-for-word.
    ///
    /// Case is allowed to differ because transcription decides capitalisation;
    /// accents are not, because folding them makes "resume" and "résumé" the
    /// same word and lets a citation land on a sentence it does not quote.
    private func containsVerbatim(_ quote: String, in transcript: String) -> Bool {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= Self.minimumQuoteCharacters,
              needle.split(whereSeparator: \.isWhitespace).count >= Self.minimumQuoteWords else {
            return false
        }
        var searchStart = transcript.startIndex
        while let range = transcript.range(
            of: needle,
            options: [.caseInsensitive],
            range: searchStart..<transcript.endIndex
        ) {
            if isWordAligned(range, in: transcript) { return true }
            guard range.lowerBound < transcript.endIndex else { return false }
            searchStart = transcript.index(after: range.lowerBound)
        }
        return false
    }

    /// A match that starts or ends inside a longer word is not a quotation of
    /// it: "contractor agreed" is not something a speaker who said
    /// "subcontractor agreed" ever said.
    private func isWordAligned(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    private static let stopWords: Set<String> = [
        "about", "after", "also", "another", "because", "been", "before", "being",
        "both", "each", "either", "from", "have", "here", "into", "just", "like",
        "more", "most", "much", "only", "other", "over", "should", "some", "such",
        "than", "that", "their", "them", "then", "there", "these", "they", "this",
        "those", "through", "very", "were", "what", "when", "where", "which",
        "while", "will", "with", "would", "your"
    ]
}
