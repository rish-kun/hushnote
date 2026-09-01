import Foundation

enum ContinueRecordingPolicy {
    static func canContinue(status: MeetingStatus, recordingIsBusy: Bool) -> Bool {
        status == .ready && !recordingIsBusy
    }

    /// The next session begins after every durable captured session. Transcript
    /// time is a fallback for older ready meetings whose session graph is absent
    /// or incomplete; it may extend the boundary, never move it backwards.
    static func timelineStartMilliseconds(
        sessions: [RecordingSession],
        existingTranscript: [TranscriptSegment]
    ) -> Int64 {
        max(
            sessions.map {
                $0.timelineStartMilliseconds + $0.capturedDurationMilliseconds
            }.max() ?? 0,
            existingTranscript.map(\.endMilliseconds).max() ?? 0
        )
    }
}
