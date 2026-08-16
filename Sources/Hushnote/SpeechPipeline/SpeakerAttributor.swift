import Foundation

public enum SpeakerAttributor {
    /// Assigns each transcript segment to the speaker turn with maximum overlap.
    /// Microphone speech can be labelled directly as the local user, avoiding
    /// needless diarization of the separately captured local track.
    public static func assign(
        turns: [SpeakerTurn],
        to segments: [TranscriptSegment],
        microphoneSpeakerID: String = "local-user",
        microphoneSpeakerName: String = "You"
    ) -> [TranscriptSegment] {
        segments.map { segment in
            var segment = segment
            if segment.source == .microphone {
                segment.speakerID = microphoneSpeakerID
                segment.speakerName = microphoneSpeakerName
                return segment
            }

            let best = turns
                .map { turn in (turn, overlap(turn: turn, segment: segment)) }
                .filter { $0.1 > 0 }
                .max {
                    if $0.1 != $1.1 { return $0.1 < $1.1 }
                    return $0.0.speakerID > $1.0.speakerID
                }?
                .0
            segment.speakerID = best?.speakerID
            segment.speakerName = best.map { "Speaker \($0.speakerID)" }
            return segment
        }
    }

    private static func overlap(turn: SpeakerTurn, segment: TranscriptSegment) -> Int64 {
        max(
            0,
            min(turn.endMilliseconds, segment.endMilliseconds)
                - max(turn.startMilliseconds, segment.startMilliseconds)
        )
    }
}
