import Foundation
import Testing
@testable import Hushnote

@Suite("Appended transcript merge")
struct AppendedTranscriptMergePolicyTests {
    @Test("Only appended segments join existing final rows in timeline order")
    func mergesWithoutReplacingExistingRows() throws {
        let meetingID = UUID()
        var edited = segment(
            meetingID: meetingID,
            source: .system,
            ordinal: 0,
            start: 2_000,
            text: "Corrected existing text",
            revision: 8
        )
        edited.speakerName = "Renamed by user"
        let opening = segment(
            meetingID: meetingID,
            source: .microphone,
            ordinal: 0,
            start: 500,
            text: "Opening",
            revision: 3
        )
        let appended = segment(
            meetingID: meetingID,
            source: .system,
            ordinal: 1,
            start: 60_000,
            text: "Five-minute follow-up",
            revision: 9
        )

        let merged = try AppendedTranscriptMergePolicy.merge(
            existing: [edited, opening],
            appended: [appended]
        )

        #expect(merged.map(\.text) == ["Opening", "Corrected existing text", "Five-minute follow-up"])
        #expect(merged[1] == edited)
        #expect(merged[2] == appended)
    }

    @Test("Starting ordinals use the greatest durable identifier, not row count")
    func startingOrdinalsUseMaximum() {
        let meetingID = UUID()
        let existing = [
            segment(meetingID: meetingID, source: .system, ordinal: 0, start: 0, text: "One"),
            segment(meetingID: meetingID, source: .system, ordinal: 4, start: 4_000, text: "Five"),
            segment(meetingID: meetingID, source: .microphone, ordinal: 2, start: 2_000, text: "You"),
        ]

        let ordinals = AppendedTranscriptMergePolicy.startingOrdinals(
            meetingID: meetingID,
            existing: existing
        )

        #expect(ordinals[.system] == 5)
        #expect(ordinals[.microphone] == 3)
    }

    @Test("A collision is rejected before persistence")
    func rejectsDuplicateIdentity() {
        let meetingID = UUID()
        let existing = segment(
            meetingID: meetingID,
            source: .system,
            ordinal: 0,
            start: 0,
            text: "Existing"
        )
        var appended = existing
        appended.text = "Collision"
        appended.startMilliseconds = 60_000
        appended.endMilliseconds = 61_000

        #expect(throws: AppendedTranscriptMergeError.duplicateSegmentID(existing.id)) {
            _ = try AppendedTranscriptMergePolicy.merge(existing: [existing], appended: [appended])
        }
    }

    @Test("Provisional rows cannot enter a final append merge")
    func rejectsProvisionalRows() {
        let meetingID = UUID()
        var provisional = segment(
            meetingID: meetingID,
            source: .system,
            ordinal: 0,
            start: 0,
            text: "Still changing"
        )
        provisional.stability = .stable

        #expect(throws: AppendedTranscriptMergeError.nonFinalSegment(provisional.id)) {
            _ = try AppendedTranscriptMergePolicy.merge(existing: [provisional], appended: [])
        }
    }
}

private func segment(
    meetingID: UUID,
    source: AudioSource,
    ordinal: Int,
    start: Int64,
    text: String,
    revision: Int = 1
) -> TranscriptSegment {
    TranscriptSegment(
        id: TranscriptIdentifier.segment(
            meetingID: meetingID,
            source: source,
            pass: .final,
            ordinal: ordinal
        ),
        meetingID: meetingID,
        source: source,
        revision: revision,
        startMilliseconds: start,
        endMilliseconds: start + 1_000,
        text: text,
        stability: .final
    )
}
