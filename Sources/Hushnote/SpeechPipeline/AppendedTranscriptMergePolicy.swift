import Foundation

enum AppendedTranscriptMergeError: Error, Equatable, Sendable {
    case mixedMeetings
    case nonFinalSegment(String)
    case duplicateSegmentID(String)
}

/// Combines one accuracy-first append pass with the already-final transcript.
///
/// Existing rows survive by value—including user edits and their revisions.
/// Only the appended session is decoded, then both sets are ordered on the one
/// continuous meeting timeline.
enum AppendedTranscriptMergePolicy {
    static func merge(
        existing: [TranscriptSegment],
        appended: [TranscriptSegment]
    ) throws -> [TranscriptSegment] {
        let combined = existing + appended
        guard let meetingID = combined.first?.meetingID else { return [] }
        guard combined.allSatisfy({ $0.meetingID == meetingID }) else {
            throw AppendedTranscriptMergeError.mixedMeetings
        }
        if let segment = combined.first(where: { $0.stability != .final }) {
            throw AppendedTranscriptMergeError.nonFinalSegment(segment.id)
        }
        var identifiers = Set<String>()
        for segment in combined where !identifiers.insert(segment.id).inserted {
            throw AppendedTranscriptMergeError.duplicateSegmentID(segment.id)
        }
        return combined.sorted {
            ($0.startMilliseconds, $0.source.rawValue, $0.id)
                < ($1.startMilliseconds, $1.source.rawValue, $1.id)
        }
    }

    /// The next final-pass ordinal per source, derived from durable identifiers
    /// rather than segment count. A removed segment may leave a gap, and count
    /// would then reuse an identifier that can still exist in history.
    static func startingOrdinals(
        meetingID: UUID,
        existing: [TranscriptSegment]
    ) -> [AudioSource: Int] {
        var result: [AudioSource: Int] = [:]
        for source in [AudioSource.system, .microphone] {
            let prefix = "\(meetingID.uuidString.lowercased())-final-\(source.rawValue)-"
            let maximum = existing
                .lazy
                .filter { $0.meetingID == meetingID && $0.source == source }
                .compactMap { segment -> Int? in
                    guard segment.id.hasPrefix(prefix) else { return nil }
                    return Int(segment.id.dropFirst(prefix.count))
                }
                .max()
            result[source] = maximum.map { $0 + 1 } ?? 0
        }
        return result
    }
}
