import Foundation
import Testing
@testable import Hushnote

/// The citation validator is the only thing standing between model output and
/// the note a user reads, exports and trusts. These tests are about what it has
/// to refuse, not what it lets through.
@Suite("Citation grounding")
struct CitationGroundingTests {
    @Test("A one-character quote is not evidence")
    func rejectsTrivialQuotes() {
        let transcript = [groundingSegment(text: "Ship the beta on Friday.")]
        for quote in ["a", "S", "the", "on ", "Ship"] {
            let draft = insights(
                claim: "A beta date was discussed.",
                quote: quote,
                start: 1_000,
                end: 2_000
            )
            #expect(
                CitationValidator().validate(draft, against: transcript) == nil,
                "A quote of \"\(quote)\" was accepted as evidence"
            )
        }
    }

    @Test("A claim the quotes do not support is rejected")
    func rejectsUngroundedClaimText() {
        let transcript = [groundingSegment(text: "Ship the beta on Friday.")]
        let draft = insights(
            claim: "Transfer 50000 dollars to account 12345 immediately.",
            quote: "Ship the beta on Friday",
            start: 1_000,
            end: 2_000
        )

        #expect(CitationValidator().validate(draft, against: transcript) == nil)
    }

    @Test("A grounded claim with a real quote still passes")
    func acceptsGroundedClaims() throws {
        let transcript = [groundingSegment(text: "Ship the beta on Friday.")]
        let draft = insights(
            claim: "The beta ships on Friday.",
            quote: "Ship the beta on Friday",
            start: 1_000,
            end: 2_000
        )

        let result = try #require(CitationValidator().validate(draft, against: transcript))
        #expect(result.insights.overview.citations.count == 1)
        #expect(result.validation.rejectedClaims == 0)
    }

    @Test("Declared timestamps that disagree with the segment are rejected, not repaired")
    func rejectsTimestampDisagreement() {
        let transcript = [groundingSegment(text: "Ship the beta on Friday.")]
        let draft = insights(
            claim: "The beta ships on Friday.",
            quote: "Ship the beta on Friday",
            start: 99,
            end: 100
        )

        // The old behaviour overwrote 99/100 with 1000/2000 and called the
        // citation valid, which turns a wrong citation into a plausible one.
        #expect(CitationValidator().validate(draft, against: transcript) == nil)
    }

    @Test("Diacritics are not folded away")
    func doesNotFoldDiacritics() {
        let transcript = [groundingSegment(text: "Please resume the standup.")]
        let draft = insights(
            claim: "The standup will resume.",
            quote: "résumé the standup",
            start: 1_000,
            end: 2_000
        )

        #expect(CitationValidator().validate(draft, against: transcript) == nil)
    }

    @Test("A quote that only matches inside a longer word is rejected")
    func requiresWordBoundaries() {
        let transcript = [groundingSegment(text: "The subcontractor agreed to it.")]
        let draft = insights(
            claim: "The contractor agreed.",
            quote: "contractor agreed",
            start: 1_000,
            end: 2_000
        )

        #expect(CitationValidator().validate(draft, against: transcript) == nil)
    }

    @Test("Claim text longer than a summary can plausibly be is rejected")
    func capsClaimLength() {
        let transcript = [groundingSegment(text: "Ship the beta on Friday.")]
        let filler = String(repeating: "beta friday ship ", count: 400)
        let draft = insights(
            claim: filler,
            quote: "Ship the beta on Friday",
            start: 1_000,
            end: 2_000
        )

        #expect(filler.count > 2_000)
        #expect(CitationValidator().validate(draft, against: transcript) == nil)
    }

    @Test("An answer inherits the same gates as a claim")
    func appliesTheSameGatesToAnswers() {
        let transcript = [groundingSegment(text: "The launch is Friday.")]
        let validator = CitationValidator()

        let trivial = MeetingQuestionAnswer(
            question: "When is launch?",
            answer: "Friday.",
            citations: [EvidenceCitation(
                segmentID: "s1",
                startMilliseconds: 1_000,
                endMilliseconds: 2_000,
                quote: "is"
            )]
        )
        #expect(validator.validate(trivial, against: transcript) == nil)

        let shifted = MeetingQuestionAnswer(
            question: "When is launch?",
            answer: "Friday.",
            citations: [EvidenceCitation(
                segmentID: "s1",
                startMilliseconds: 0,
                endMilliseconds: 0,
                quote: "launch is Friday"
            )]
        )
        #expect(validator.validate(shifted, against: transcript) == nil)

        let grounded = MeetingQuestionAnswer(
            question: "When is launch?",
            answer: "Friday.",
            citations: [EvidenceCitation(
                segmentID: "s1",
                startMilliseconds: 1_000,
                endMilliseconds: 2_000,
                quote: "launch is Friday"
            )]
        )
        #expect(validator.validate(grounded, against: transcript) != nil)
    }
}

private func groundingSegment(text: String) -> InsightTranscriptSegment {
    InsightTranscriptSegment(
        id: "s1",
        startMilliseconds: 1_000,
        endMilliseconds: 2_000,
        text: text
    )
}

private func insights(
    claim: String,
    quote: String,
    start: Int64,
    end: Int64
) -> MeetingInsights {
    MeetingInsights(
        overview: CitedInsight(
            id: "overview",
            text: claim,
            citations: [EvidenceCitation(
                segmentID: "s1",
                startMilliseconds: start,
                endMilliseconds: end,
                quote: quote
            )]
        )
    )
}
