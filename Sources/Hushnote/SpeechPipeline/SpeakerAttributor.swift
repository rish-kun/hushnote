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
            // Discrete participant tracks imported from a multitrack file
            // already carry stronger identity evidence than acoustic
            // clustering. Preserve that label while diarizing an unlabeled
            // system mix beside it.
            if segment.speakerID?.hasPrefix("imported-participant-") == true {
                return segment
            }

            let best = turns
                .map { turn in (turn, intersection(turn: turn, segment: segment)) }
                // Zero is a touch, not a miss: a zero-duration segment — which
                // Whisper emits at chunk boundaries and TranscriptAssembler
                // permits — has zero overlap with the turn containing it, and a
                // segment abutting a turn exactly has zero overlap too. Only a
                // negative intersection means the two are genuinely disjoint.
                .filter { $0.1 >= 0 }
                .max {
                    if $0.1 != $1.1 { return $0.1 < $1.1 }
                    return $0.0.speakerID > $1.0.speakerID
                }?
                .0
            segment.speakerID = best?.speakerID
            segment.speakerName = best.map { displayName(forSpeakerID: $0.speakerID) }
            return segment
        }
    }

    /// Diarizers label clusters rather than people. FluidAudio uses "S1", "S2"…,
    /// so interpolating the raw identifier renders "Speaker S1" in the UI.
    static func displayName(forSpeakerID speakerID: String) -> String {
        let withoutClusterPrefix = speakerID.dropFirst()
        if speakerID.hasPrefix("S"),
            !withoutClusterPrefix.isEmpty,
            withoutClusterPrefix.allSatisfy(\.isNumber)
        {
            return "Speaker \(withoutClusterPrefix)"
        }
        return "Speaker \(speakerID)"
    }

    /// Positive when the ranges overlap, zero when they touch, negative by the
    /// size of the gap when they do not meet at all.
    private static func intersection(turn: SpeakerTurn, segment: TranscriptSegment) -> Int64 {
        min(turn.endMilliseconds, segment.endMilliseconds)
            - max(turn.startMilliseconds, segment.startMilliseconds)
    }
}
