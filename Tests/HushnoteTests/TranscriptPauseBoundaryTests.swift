import Foundation
import Testing
@testable import Hushnote

@Suite("Transcript pause boundaries")
struct TranscriptPauseBoundaryTests {
    @Test("Only completed pause events become apparatus")
    func completedPausesOnly() {
        let session = UUID()
        let complete = RecordingEvent(
            sessionID: session,
            kind: .pause,
            timelineMilliseconds: 12_000,
            wallClockAt: Date(),
            durationMilliseconds: 252_000
        )
        let open = RecordingEvent(
            sessionID: session,
            kind: .pause,
            timelineMilliseconds: 18_000,
            wallClockAt: Date()
        )
        let sleep = RecordingEvent(
            sessionID: session,
            kind: .sleepGap,
            timelineMilliseconds: 20_000,
            wallClockAt: Date(),
            durationMilliseconds: 500
        )

        let boundaries = TranscriptPauseBoundaryPolicy.boundaries(
            from: [sleep, open, complete]
        )
        #expect(boundaries.count == 1)
        #expect(boundaries[0].id == complete.id)
        #expect(boundaries[0].timelineSeconds == 12)
        #expect(boundaries[0].durationSeconds == 252)
    }

    @Test("A pause is placed before the first paragraph at or after its media clock")
    func placement() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, start: 0, end: 8),
            Self.line(ordinal: 1, start: 14, end: 20),
            Self.line(ordinal: 2, start: 30, end: 36),
        ])
        let event = RecordingEvent(
            sessionID: UUID(),
            kind: .pause,
            timelineMilliseconds: 14_000,
            wallClockAt: Date(),
            durationMilliseconds: 4_000
        )

        guard let second = paragraphs.first(where: { $0.start == 14 }) else {
            Issue.record("Expected a paragraph after the pause")
            return
        }
        #expect(TranscriptPauseBoundaryPolicy.boundaries(
            before: second,
            paragraphs: paragraphs,
            events: [event]
        ).map(\.id) == [event.id])
        #expect(TranscriptPauseBoundaryPolicy.trailingBoundaries(
            paragraphs: paragraphs,
            events: [event]
        ).isEmpty)
    }

    @Test("A pause after the final words remains a trailing boundary")
    func trailing() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, start: 0, end: 8),
        ])
        let event = RecordingEvent(
            sessionID: UUID(),
            kind: .pause,
            timelineMilliseconds: 9_000,
            wallClockAt: Date(),
            durationMilliseconds: 2_000
        )
        #expect(TranscriptPauseBoundaryPolicy.trailingBoundaries(
            paragraphs: paragraphs,
            events: [event]
        ).map(\.id) == [event.id])
    }

    private static func line(
        ordinal: Int,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptLineItem {
        TranscriptLineItem(
            id: UUID(),
            segmentID: "pause-segment-\(ordinal)",
            speaker: "Ada",
            start: start,
            end: end,
            text: "Paragraph \(ordinal).",
            isProvisional: false
        )
    }
}
