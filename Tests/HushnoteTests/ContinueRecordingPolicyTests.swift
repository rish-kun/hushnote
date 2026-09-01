import Foundation
import Testing
@testable import Hushnote

@Suite("Continue recording")
struct ContinueRecordingPolicyTests {
    @Test("Only a ready meeting can continue while capture is idle")
    func availability() {
        #expect(ContinueRecordingPolicy.canContinue(status: .ready, recordingIsBusy: false))
        #expect(!ContinueRecordingPolicy.canContinue(status: .ready, recordingIsBusy: true))
        #expect(!ContinueRecordingPolicy.canContinue(status: .failed, recordingIsBusy: false))
        #expect(!ContinueRecordingPolicy.canContinue(status: .recording, recordingIsBusy: false))
    }

    @Test("A continuation starts after both durable sessions and legacy transcript time")
    func timelineBoundary() {
        let meetingID = UUID()
        let sessions = [
            RecordingSession(
                meetingID: meetingID,
                ordinal: 0,
                origin: .live,
                wallStartedAt: Date(),
                timelineStartMilliseconds: 0,
                capturedDurationMilliseconds: 8_000,
                state: .ready
            )
        ]
        let segment = TranscriptSegment(
            id: "legacy",
            meetingID: meetingID,
            source: .system,
            revision: 1,
            startMilliseconds: 7_500,
            endMilliseconds: 9_250,
            text: "Legacy transcript extends past old session metadata",
            stability: .final
        )

        #expect(ContinueRecordingPolicy.timelineStartMilliseconds(
            sessions: sessions,
            existingTranscript: [segment]
        ) == 9_250)
    }
}
