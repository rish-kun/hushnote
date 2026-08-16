import Foundation

/// Mints transcript identifiers that are unique by construction.
///
/// Timing-derived identifiers do not work. WhisperKit gives no guarantee that
/// `(start, end)` is unique within a source: the `.vad` path re-applies a seek
/// offset per chunk and zero-duration segments are permitted, so one decode can
/// return two segments with the same range. A single collision makes
/// `MeetingStore.validate` reject the entire transcript after ASR and
/// diarization have already succeeded.
///
/// `transcriptSegments.id` is also a database-wide primary key rather than a
/// per-meeting one, so identifiers are scoped by meeting as well as by source —
/// otherwise two meetings that both begin at t=0 collide with each other.
enum TranscriptIdentifier {
    enum Pass: String {
        /// Incremental decoding during capture.
        case live
        /// The full-file pass that runs after Stop.
        case final
    }

    /// - Parameter ordinal: A per-source counter that only ever increases within
    ///   one transcription pass. It carries no timing meaning.
    static func segment(
        meetingID: UUID,
        source: AudioSource,
        pass: Pass,
        ordinal: Int
    ) -> String {
        "\(meetingID.uuidString.lowercased())-\(pass.rawValue)-\(source.rawValue)-\(ordinal)"
    }

    /// Word identifiers derive from their owning segment, which is already
    /// unique, so words that share a start time stay distinguishable.
    static func word(segmentID: String, index: Int) -> String {
        "\(segmentID)-w\(index)"
    }
}
