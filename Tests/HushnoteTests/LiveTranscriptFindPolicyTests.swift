import Foundation
import Testing
@testable import Hushnote

@Suite("Live transcript find")
struct LiveTranscriptFindPolicyTests {
    @Test("Search includes only text that still belongs to the live pass")
    func provisionalOnly() {
        let lines = [
            line("final", text: "final decision", provisional: false),
            line("live", text: "live decision", provisional: true)
        ]

        #expect(
            LiveTranscriptFindPolicy.matches(query: "decision", in: lines)
                == [LiveTranscriptMatch(segmentID: "live")]
        )
    }

    @Test("Search follows visible token-cleaned text and ignores case and accents")
    func normalizedVisibleText() {
        let lines = [
            line("one", text: "<|0.00|> CAFÉ launch <|0.40|>", provisional: true)
        ]

        #expect(
            LiveTranscriptFindPolicy.matches(query: "cafe LAUNCH", in: lines)
                == [LiveTranscriptMatch(segmentID: "one")]
        )
        #expect(LiveTranscriptFindPolicy.matches(query: "0.00", in: lines).isEmpty)
    }

    @Test("Navigation wraps in both directions")
    func wrappingNavigation() {
        let matches = ["a", "b", "c"].map(LiveTranscriptMatch.init(segmentID:))

        #expect(
            LiveTranscriptFindPolicy.adjacentSelection(
                from: "c", in: matches, direction: .next
            ) == "a"
        )
        #expect(
            LiveTranscriptFindPolicy.adjacentSelection(
                from: "a", in: matches, direction: .previous
            ) == "c"
        )
    }

    @Test("Selection survives streaming replacement by identity")
    func identitySurvivesReplacement() {
        let replaced = ["new", "kept", "later"].map(LiveTranscriptMatch.init(segmentID:))

        #expect(
            LiveTranscriptFindPolicy.resolvedSelection(
                currentSegmentID: "kept", in: replaced
            ) == "kept"
        )
        #expect(
            LiveTranscriptFindPolicy.resolvedSelection(
                currentSegmentID: "gone", in: replaced
            ) == "new"
        )
    }

    @Test("Blank queries have no matches")
    func blankQuery() {
        #expect(
            LiveTranscriptFindPolicy.matches(
                query: "  \n",
                in: [line("one", text: "anything", provisional: true)]
            ).isEmpty
        )
    }

    @Test("Find navigation and return to latest make opposite follow decisions")
    func followDecision() {
        #expect(TranscriptFollow.followsAfterJump(returningToLatest: false) == false)
        #expect(TranscriptFollow.followsAfterJump(returningToLatest: true))
    }

    private func line(
        _ segmentID: String,
        text: String,
        provisional: Bool
    ) -> TranscriptLineItem {
        TranscriptLineItem(
            id: UUID(),
            segmentID: segmentID,
            speaker: "Speaker",
            start: 0,
            end: 1,
            text: text,
            isProvisional: provisional
        )
    }
}
