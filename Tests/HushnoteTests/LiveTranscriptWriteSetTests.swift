import Foundation
import Testing
@testable import Hushnote

/// The live loop applied every delta to the whole meeting and re-upserted the
/// entire stable prefix, so a segment frozen in minute one was rewritten for
/// every delta of the following twenty. These pin the ledger that reduces each
/// delta's write to the segments whose stored form would actually differ.
@Suite("The live loop persists only what a delta changed")
struct LiveTranscriptWriteSetTests {
    private let meetingID = UUID()

    private func segment(
        _ id: String,
        start: Int64,
        text: String,
        stability: TranscriptStability = .stable,
        revision: Int = 1,
        meetingID: UUID? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: meetingID ?? self.meetingID,
            source: .system,
            revision: revision,
            startMilliseconds: start,
            endMilliseconds: start + 1_000,
            text: text,
            words: [
                TranscriptWord(
                    id: "\(id)-w1",
                    text: text,
                    startMilliseconds: start,
                    endMilliseconds: start + 500
                )
            ],
            stability: stability
        )
    }

    private func snapshot(_ segments: [TranscriptSegment], revision: Int = 1) -> TranscriptSnapshot {
        TranscriptSnapshot(meetingID: meetingID, revision: revision, segments: segments)
    }

    @Test("Audio still being revised is not written to disk")
    func partialSegmentsAreHeldBack() {
        let ledger = LiveTranscriptWriteSet()
        let pending = ledger.unwritten(in: snapshot([
            segment("s1", start: 0, text: "Committed", stability: .stable),
            segment("s2", start: 1_000, text: "Still moving", stability: .partial)
        ]))

        #expect(pending.map(\.id) == ["s1"])
    }

    @Test("A segment already on disk in this exact form is not rewritten")
    func confirmedSegmentsAreNotRewritten() {
        var ledger = LiveTranscriptWriteSet()
        let first = segment("s1", start: 0, text: "Committed")
        ledger.confirm(ledger.unwritten(in: snapshot([first])))

        #expect(ledger.unwritten(in: snapshot([first])).isEmpty)
    }

    @Test("Only the newly stable tail is written as the meeting grows")
    func eachDeltaWritesOnlyItsOwnSegments() {
        var ledger = LiveTranscriptWriteSet()
        var segments: [TranscriptSegment] = []
        var writes = 0

        for index in 0..<200 {
            segments.append(segment(
                "s\(index)",
                start: Int64(index) * 1_000,
                text: "Line \(index)"
            ))
            let pending = ledger.unwritten(in: snapshot(segments, revision: index))
            #expect(pending.map(\.id) == ["s\(index)"])
            writes += pending.count
            ledger.confirm(pending)
        }

        #expect(writes == 200)
    }

    @Test("A segment corrected after it froze is written again")
    func correctedSegmentsAreRewritten() {
        var ledger = LiveTranscriptWriteSet()
        let original = segment("s1", start: 0, text: "Wee ship Friday")
        ledger.confirm(ledger.unwritten(in: snapshot([original])))

        var corrected = original
        corrected.text = "We ship Friday"
        corrected.revision = 2

        #expect(ledger.unwritten(in: snapshot([corrected])) == [corrected])
    }

    @Test("A speaker or timing change reaches disk even when the text is identical")
    func nonTextChangesAreRewritten() {
        var ledger = LiveTranscriptWriteSet()
        let original = segment("s1", start: 0, text: "We ship Friday")
        ledger.confirm(ledger.unwritten(in: snapshot([original])))

        var named = original
        named.speakerName = "Rhea"
        var retimed = original
        retimed.words[0].endMilliseconds = 900

        #expect(ledger.unwritten(in: snapshot([named])) == [named])
        #expect(ledger.unwritten(in: snapshot([retimed])) == [retimed])
    }

    @Test("Promotion to final is a change the transcript keeps")
    func finalStabilityIsRewrittenOnce() {
        var ledger = LiveTranscriptWriteSet()
        let stable = segment("s1", start: 0, text: "We ship Friday")
        ledger.confirm(ledger.unwritten(in: snapshot([stable])))

        var finalized = stable
        finalized.stability = .final
        let pending = ledger.unwritten(in: snapshot([finalized]))
        ledger.confirm(pending)

        #expect(pending == [finalized])
        #expect(ledger.unwritten(in: snapshot([finalized])).isEmpty)
    }

    @Test("A write that never landed stays pending for the next delta")
    func unconfirmedWritesAreRetried() {
        let ledger = LiveTranscriptWriteSet()
        let first = segment("s1", start: 0, text: "Committed")
        _ = ledger.unwritten(in: snapshot([first]))

        #expect(ledger.unwritten(in: snapshot([first])) == [first])
    }

    @Test("A new meeting writes from scratch even when identifiers repeat")
    func anotherMeetingIsNeverSuppressed() {
        var ledger = LiveTranscriptWriteSet()
        let first = segment("s1", start: 0, text: "Committed")
        ledger.confirm(ledger.unwritten(in: snapshot([first])))

        let otherMeeting = UUID()
        let reused = segment("s1", start: 0, text: "Committed", meetingID: otherMeeting)
        let otherSnapshot = TranscriptSnapshot(
            meetingID: otherMeeting,
            revision: 1,
            segments: [reused]
        )

        #expect(ledger.unwritten(in: otherSnapshot) == [reused])
        ledger.confirm([reused])
        #expect(ledger.unwritten(in: otherSnapshot).isEmpty)
        // The previous meeting's entries are gone, so returning to it would
        // rewrite rather than silently skip.
        #expect(ledger.unwritten(in: snapshot([first])) == [first])
    }

    @Test("Resetting for a new session forgets what the last one wrote")
    func resetClearsTheLedger() {
        var ledger = LiveTranscriptWriteSet()
        let first = segment("s1", start: 0, text: "Committed")
        ledger.confirm(ledger.unwritten(in: snapshot([first])))

        ledger.reset()

        #expect(ledger.unwritten(in: snapshot([first])) == [first])
    }

    @Test("The final pass's minted identifiers are never suppressed")
    func finalPassIdentifiersAreAlwaysWritten() {
        var ledger = LiveTranscriptWriteSet()
        let live = (0..<5).map { segment("live-\($0)", start: Int64($0) * 1_000, text: "Line \($0)") }
        ledger.confirm(ledger.unwritten(in: snapshot(live)))

        // The final pass re-runs VAD: new identifiers, new boundaries, same audio.
        let final = (0..<3).map {
            segment(
                "final-\($0)",
                start: Int64($0) * 1_700,
                text: "Paragraph \($0)",
                stability: .final,
                revision: 9
            )
        }

        #expect(ledger.unwritten(in: snapshot(final, revision: 9)) == final)
    }
}
