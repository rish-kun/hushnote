import Foundation
import Testing
@testable import Hushnote

/// `searchSegments` returns the matched line, who said it, and when. All of it
/// used to be reduced to a set of meeting identifiers one line later, so search
/// could say a meeting matched but never which moment in it did.
@Suite("Meeting search results")
struct MeetingSearchResultTests {
    @Test("No matches yields no rows")
    func empty() {
        #expect(
            MeetingSearchResultBuilder.results(
                segmentMatches: [],
                meetings: [Self.meeting(index: 0)]
            ).isEmpty
        )
    }

    /// bm25 already ordered the segments; a meeting ranks by its best hit.
    @Test("Meetings rank by their first-appearing match")
    func ranking() {
        let first = Self.meeting(index: 0)
        let second = Self.meeting(index: 1)
        let results = MeetingSearchResultBuilder.results(
            segmentMatches: [
                Self.segment(meeting: second, ordinal: 0, text: "the strongest hit"),
                Self.segment(meeting: first, ordinal: 1, text: "a weaker hit"),
            ],
            meetings: [first, second]
        )
        #expect(results.map(\.id) == [second.id, first.id])
    }

    @Test("A talkative meeting is capped, and says how much it held back")
    func capping() throws {
        let meeting = Self.meeting(index: 0)
        let matches = (0..<7).map {
            Self.segment(meeting: meeting, ordinal: $0, text: "match number \($0)")
        }
        let result = try #require(
            MeetingSearchResultBuilder.results(
                segmentMatches: matches,
                meetings: [meeting]
            ).first
        )
        #expect(result.moments.count == MeetingSearchResultBuilder.momentsPerMeeting)
        #expect(result.additionalMomentCount == 7 - MeetingSearchResultBuilder.momentsPerMeeting)
    }

    @Test("A moment carries its time, its speaker, and what was said")
    func momentContents() throws {
        let meeting = Self.meeting(index: 0)
        var segment = Self.segment(meeting: meeting, ordinal: 0, text: "we are deferring it")
        segment.startMilliseconds = 72_400
        segment.speakerName = "Ada"

        let moment = try #require(
            MeetingSearchResultBuilder.results(
                segmentMatches: [segment],
                meetings: [meeting]
            ).first?.moments.first
        )
        #expect(moment.id == segment.id)
        #expect(moment.speaker == "Ada")
        #expect(moment.text == "we are deferring it")
        #expect(abs(moment.start - 72.4) < 0.001)
    }

    /// A match whose meeting is not in the list -- deleted, or filtered out --
    /// would otherwise render as a row that opens nothing.
    @Test("A match with no meeting behind it is dropped")
    func orphanMatch() {
        let absent = Self.meeting(index: 9)
        #expect(
            MeetingSearchResultBuilder.results(
                segmentMatches: [Self.segment(meeting: absent, ordinal: 0, text: "orphan")],
                meetings: [Self.meeting(index: 0)]
            ).isEmpty
        )
    }

    /// The same three-layer rule as the rest of the app: this text is about to
    /// be rendered, so a segment that is nothing but control tokens is dropped
    /// rather than shown as an empty moment.
    @Test("A segment that cleans away to nothing is not a moment")
    func controlTokensOnly() {
        let meeting = Self.meeting(index: 0)
        let results = MeetingSearchResultBuilder.results(
            segmentMatches: [Self.segment(meeting: meeting, ordinal: 0, text: "<|nospeech|>")],
            meetings: [meeting]
        )
        #expect(results.isEmpty)
    }

    /// A meeting whose title matched is still a real answer, and often the one
    /// the user meant -- but a phrase actually said outranks it.
    @Test("Title matches follow spoken matches, without duplicating them")
    func titleMatches() {
        let spoken = Self.meeting(index: 0)
        let titled = Self.meeting(index: 1)
        let results = MeetingSearchResultBuilder.results(
            segmentMatches: [Self.segment(meeting: spoken, ordinal: 0, text: "said aloud")],
            meetings: [spoken, titled],
            titleMatches: [titled, spoken]
        )

        #expect(results.map(\.id) == [spoken.id, titled.id])
        #expect(results[0].moments.count == 1)
        #expect(results[1].moments.isEmpty)
    }

    @Test("The row count is bounded")
    func limit() {
        let meetings = (0..<40).map { Self.meeting(index: $0) }
        let matches = meetings.map { Self.segment(meeting: $0, ordinal: 0, text: "hit") }
        let results = MeetingSearchResultBuilder.results(
            segmentMatches: matches,
            meetings: meetings
        )
        #expect(results.count == MeetingSearchResultBuilder.meetingLimit)
    }

    // MARK: - Fixtures

    private static func meeting(index: Int) -> MeetingListItem {
        MeetingListItem(
            id: UUID(),
            title: "Meeting \(index)",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600),
            duration: 1_800,
            template: .general,
            excerpt: ""
        )
    }

    private static func segment(
        meeting: MeetingListItem,
        ordinal: Int,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: "\(meeting.id.uuidString)-\(ordinal)",
            meetingID: meeting.id,
            source: .system,
            revision: 0,
            startMilliseconds: Int64(ordinal) * 1_000,
            endMilliseconds: Int64(ordinal) * 1_000 + 900,
            text: text,
            words: [],
            speakerID: nil,
            speakerName: nil,
            confidence: nil,
            stability: .final
        )
    }
}
