import Foundation
import Testing
@testable import Hushnote

@Suite("Transcript marker placement")
struct TranscriptMarkerPolicyTests {
    @Test("Markers attach to the first paragraph at or after their clock")
    func placesByTimeline() throws {
        let first = Self.paragraph(start: 0, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = Self.paragraph(start: 30, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let marker = RecordingMarker(
            meetingID: UUID(), sessionID: UUID(), type: .decision,
            timelineMilliseconds: 12_000
        )

        let placed = TranscriptMarkerPolicy.placements(
            markers: [marker], paragraphs: [first, second]
        )

        #expect(placed[first.id] == nil)
        #expect(placed[second.id] == [marker])
    }

    @Test("Markers after the final paragraph remain visible at the end")
    func keepsTrailingMarker() throws {
        let paragraph = Self.paragraph(start: 10, id: UUID())
        let marker = RecordingMarker(
            meetingID: UUID(), sessionID: UUID(), type: .followUp,
            timelineMilliseconds: 120_000
        )

        #expect(TranscriptMarkerPolicy.placements(markers: [marker], paragraphs: [paragraph])[paragraph.id] == [marker])
    }

    private static func paragraph(start: TimeInterval, id: UUID) -> TranscriptParagraph {
        let line = TranscriptLineItem(
            id: id, segmentID: id.uuidString, speaker: "You", start: start,
            end: start + 2, text: "A thought.", isProvisional: false
        )
        return TranscriptGrouping.paragraphs([line])[0]
    }
}
