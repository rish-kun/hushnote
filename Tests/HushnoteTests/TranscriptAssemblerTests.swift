import Foundation
import Testing
@testable import Hushnote

@Suite("Transcript assembler")
struct TranscriptAssemblerTests {
    @Test("New hypotheses replace only the mutable suffix")
    func testNewerHypothesisReplacesOnlyMutableSuffix() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 1,
                stablePrefixCount: 1,
                segments: [
                    segment("a", "Hello", 0, 500, meetingID),
                    segment("b", "word", 500, 1_000, meetingID),
                ]
            )
        )

        let snapshot = assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 2,
                stablePrefixCount: 1,
                segments: [
                    segment("a2", "This must not replace stable text", 0, 500, meetingID),
                    segment("c", "world", 500, 1_000, meetingID),
                ]
            )
        )

        #expect(snapshot.segments.map(\.id) == ["a", "c"])
        #expect(snapshot.segments.map(\.text) == ["Hello", "world"])
        #expect(snapshot.segments.map(\.stability) == [.stable, .partial])
    }

    @Test("The committed prefix moves only forward")
    func testStablePrefixOnlyMovesForward() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 1,
                stablePrefixCount: 2,
                segments: [
                    segment("a", "one", 0, 100, meetingID),
                    segment("b", "two", 100, 200, meetingID),
                    segment("c", "three", 200, 300, meetingID),
                ]
            )
        )

        let snapshot = assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 2,
                stablePrefixCount: 0,
                segments: [
                    segment("x", "changed", 0, 100, meetingID),
                    segment("y", "changed", 100, 200, meetingID),
                    segment("z", "revised tail", 200, 350, meetingID),
                ]
            )
        )

        #expect(snapshot.segments.map(\.id) == ["a", "b", "z"])
        #expect(snapshot.segments.map(\.stability) == [.stable, .stable, .partial])
    }

    @Test("Duplicate and stale revisions are ignored")
    func testOutOfOrderAndDuplicateRevisionsAreIgnored() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 3,
                stablePrefixCount: 0,
                segments: [segment("new", "new", 0, 100, meetingID)]
            )
        )
        assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 2,
                stablePrefixCount: 1,
                segments: [segment("old", "old", 0, 100, meetingID)]
            )
        )
        let snapshot = assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 3,
                stablePrefixCount: 1,
                segments: [segment("duplicate", "duplicate", 0, 100, meetingID)]
            )
        )

        #expect(snapshot.segments.map(\.id) == ["new"])
        #expect(snapshot.revision == 1)
    }

    @Test("Independent sources merge chronologically")
    func testSourcesReviseIndependentlyAndMergeChronologically() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        assembler.apply(
            delta(
                meetingID: meetingID,
                source: .system,
                revision: 1,
                stablePrefixCount: 1,
                segments: [segment("remote", "Remote", 200, 400, meetingID, .system)]
            )
        )
        let snapshot = assembler.apply(
            delta(
                meetingID: meetingID,
                source: .microphone,
                revision: 1,
                stablePrefixCount: 1,
                segments: [segment("local", "Local", 0, 150, meetingID, .microphone)]
            )
        )

        #expect(snapshot.segments.map(\.id) == ["local", "remote"])
        #expect(snapshot.segments.map(\.source) == [.microphone, .system])
    }

    @Test("A final delta commits every segment")
    func testFinalDeltaCommitsEverySegment() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        let snapshot = assembler.apply(
            TranscriptDelta(
                meetingID: meetingID,
                source: .system,
                revision: 1,
                segments: [
                    segment("a", "one", 0, 100, meetingID),
                    segment("b", "two", 100, 200, meetingID),
                ],
                stablePrefixCount: 0,
                isFinal: true
            )
        )

        #expect(snapshot.segments.map(\.stability) == [.final, .final])
    }

    @Test("Malformed and foreign segments are discarded")
    func testMalformedAndForeignSegmentsAreDiscarded() {
        let meetingID = UUID()
        let otherMeetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        let snapshot = assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 1,
                stablePrefixCount: 3,
                segments: [
                    segment("valid", "valid", 0, 100, meetingID),
                    segment("foreign", "foreign", 100, 200, otherMeetingID),
                    segment("backwards", "bad", 300, 200, meetingID),
                ]
            )
        )

        #expect(snapshot.segments.map(\.id) == ["valid"])
    }

    @Test("A delta for another meeting does not advance snapshot state")
    func foreignDeltaIsIgnoredCompletely() {
        let meetingID = UUID()
        let foreignID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)

        let before = assembler.apply(
            delta(
                meetingID: meetingID,
                revision: 1,
                stablePrefixCount: 1,
                segments: [segment("kept", "Keep me", 0, 100, meetingID)]
            )
        )
        let after = assembler.apply(
            delta(
                meetingID: foreignID,
                revision: 99,
                stablePrefixCount: 1,
                segments: [segment("foreign", "Ignore me", 0, 100, foreignID)]
            )
        )

        #expect(after == before)
    }

    @Test("Reset clears every source and advances the snapshot revision")
    func resetClearsAllSources() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)
        assembler.apply(delta(
            meetingID: meetingID,
            source: .microphone,
            revision: 1,
            stablePrefixCount: 1,
            segments: [segment("mic", "Local", 0, 100, meetingID, .microphone)]
        ))
        assembler.apply(delta(
            meetingID: meetingID,
            source: .system,
            revision: 1,
            stablePrefixCount: 1,
            segments: [segment("system", "Remote", 100, 200, meetingID, .system)]
        ))
        let revisionBeforeReset = assembler.snapshot.revision

        assembler.reset()

        #expect(assembler.snapshot.segments.isEmpty)
        #expect(assembler.snapshot.revision == revisionBeforeReset + 1)
    }

    @Test("Stable segments survive a shorter later hypothesis")
    func shorterHypothesisCannotRemoveCommittedText() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)
        assembler.apply(delta(
            meetingID: meetingID,
            revision: 1,
            stablePrefixCount: 2,
            segments: [
                segment("a", "one", 0, 100, meetingID),
                segment("b", "two", 100, 200, meetingID),
                segment("tail", "temporary", 200, 300, meetingID),
            ]
        ))

        let snapshot = assembler.apply(delta(
            meetingID: meetingID,
            revision: 2,
            stablePrefixCount: 0,
            segments: [segment("replacement", "short", 0, 100, meetingID)]
        ))

        #expect(snapshot.segments.map(\.id) == ["a", "b"])
        #expect(snapshot.segments.map(\.text) == ["one", "two"])
    }

    @Test("A hypothesis that re-cuts a frozen boundary neither duplicates nor drops")
    func reDecodedOverlapDoesNotDuplicateFrozenSegments() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)
        assembler.apply(delta(
            meetingID: meetingID,
            revision: 1,
            stablePrefixCount: 2,
            segments: [
                segment("s0", "zero", 0, 1_000, meetingID),
                segment("s1", "one", 1_000, 2_000, meetingID),
            ]
        ))

        // The next decode re-cuts the boundary: u1 starts inside frozen audio but
        // ends past it, so the engine's end-only tail filter used to let it
        // through. `normalized` then sorts it between s0 and s1, and freezing by
        // array position stopped meaning the same utterance.
        let snapshot = assembler.apply(delta(
            meetingID: meetingID,
            revision: 2,
            stablePrefixCount: 2,
            segments: [
                segment("s0", "zero", 0, 1_000, meetingID),
                segment("s1", "one", 1_000, 2_000, meetingID),
                segment("u1", "one two", 800, 2_500, meetingID),
                segment("u2", "three", 2_500, 3_500, meetingID),
            ]
        ))

        let ids = snapshot.segments.map(\.id)
        // A duplicate ID here trips MeetingStore.validate, and the coordinator
        // swallows that with `try?`, so live persistence dies for the rest of
        // the meeting.
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["s0", "s1", "u2"])
    }

    @Test("A shorter hypothesis still admits speech past the frozen boundary")
    func shorterHypothesisDoesNotBlankNewSpeech() {
        let meetingID = UUID()
        var assembler = TranscriptAssembler(meetingID: meetingID)
        assembler.apply(delta(
            meetingID: meetingID,
            revision: 1,
            stablePrefixCount: 2,
            segments: [
                segment("a", "one", 0, 1_000, meetingID),
                segment("b", "two", 1_000, 2_000, meetingID),
            ]
        ))

        // VAD merged the committed audio into one segment, so the hypothesis is
        // no longer than the frozen prefix — but it still carries new speech.
        let snapshot = assembler.apply(delta(
            meetingID: meetingID,
            revision: 2,
            stablePrefixCount: 0,
            segments: [
                segment("merged", "one two", 0, 2_000, meetingID),
                segment("c", "three", 2_000, 3_000, meetingID),
            ]
        ))

        #expect(snapshot.segments.map(\.id) == ["a", "b", "c"])
    }

    private func delta(
        meetingID: UUID,
        source: AudioSource = .system,
        revision: Int,
        stablePrefixCount: Int,
        segments: [TranscriptSegment]
    ) -> TranscriptDelta {
        TranscriptDelta(
            meetingID: meetingID,
            source: source,
            revision: revision,
            segments: segments,
            stablePrefixCount: stablePrefixCount
        )
    }

    private func segment(
        _ id: String,
        _ text: String,
        _ start: Int64,
        _ end: Int64,
        _ meetingID: UUID,
        _ source: AudioSource = .system
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: meetingID,
            source: source,
            startMilliseconds: start,
            endMilliseconds: end,
            text: text
        )
    }
}
