import Foundation

/// Reduces a live transcript snapshot to the segments a write would actually
/// change.
///
/// `TranscriptAssembler.snapshot` is the whole meeting, every time. Upserting
/// its stable prefix on each delta therefore rewrote minute one's segments for
/// every delta of the following twenty — 549 transactions and ~163 MB of WAL to
/// persist 217 KB of transcript, growing with the square of the meeting. This
/// keeps the segments that have reached disk and hands back only the difference.
///
/// The comparison is by identity and by value, not by count or position. A
/// count would be wrong the moment a hypothesis re-cuts audio, and value
/// equality is what makes a segment corrected after it froze — or re-timed,
/// re-attributed, or promoted to `.final` — reach disk anyway. Nothing here
/// assumes the transcript only grows.
///
/// It is deliberately a ledger of what was *written*, not of what was *seen*:
/// `confirm` runs after the store accepts the write, so a failed transaction
/// leaves its segments pending for the next delta instead of losing them for
/// the rest of the session.
struct LiveTranscriptWriteSet: Sendable {
    /// Anything below this is still being revised; persisting it would write a
    /// row the next delta replaces.
    static let minimumStability: TranscriptStability = .stable

    private var meetingID: UUID?
    private var written: [String: TranscriptSegment] = [:]

    init() {}

    /// The segments of `snapshot` that are committed enough to store and are not
    /// already stored in exactly this form.
    ///
    /// A snapshot for another meeting is entirely unwritten: identifiers are only
    /// unique within a meeting, and the final pass mints new ones regardless, so
    /// a stale ledger can never suppress a segment it has not seen.
    func unwritten(in snapshot: TranscriptSnapshot) -> [TranscriptSegment] {
        guard snapshot.meetingID == meetingID else {
            return snapshot.segments.filter { $0.stability >= Self.minimumStability }
        }
        return snapshot.segments.filter {
            $0.stability >= Self.minimumStability && written[$0.id] != $0
        }
    }

    /// Records segments the store has accepted. Segments from a different
    /// meeting replace the ledger rather than joining it.
    mutating func confirm(_ segments: [TranscriptSegment]) {
        guard let first = segments.first else { return }
        if first.meetingID != meetingID {
            meetingID = first.meetingID
            written.removeAll(keepingCapacity: true)
        }
        for segment in segments where segment.meetingID == first.meetingID {
            written[segment.id] = segment
        }
    }

    /// Forgets the session. The next one starts from an empty database as far as
    /// this is concerned, so nothing a previous meeting wrote can suppress it.
    mutating func reset() {
        meetingID = nil
        written.removeAll(keepingCapacity: true)
    }
}
