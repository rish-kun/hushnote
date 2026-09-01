import Foundation

/// Places durable user emphasis beside the first paragraph at or after its
/// sample-clock position. Markers never become transcript prose and remain
/// visible even when the marker falls in a paragraph's middle.
enum TranscriptMarkerPolicy {
    nonisolated static func placements(
        markers: [RecordingMarker],
        paragraphs: [TranscriptParagraph]
    ) -> [UUID: [RecordingMarker]] {
        guard !paragraphs.isEmpty else { return [:] }
        var result: [UUID: [RecordingMarker]] = [:]
        for marker in markers.sorted(by: sort) {
            let seconds = Double(marker.timelineMilliseconds) / 1_000
            let paragraph = paragraphs.first(where: { $0.start >= seconds }) ?? paragraphs.last!
            result[paragraph.id, default: []].append(marker)
        }
        return result
    }

    private nonisolated static func sort(_ lhs: RecordingMarker, _ rhs: RecordingMarker) -> Bool {
        if lhs.timelineMilliseconds != rhs.timelineMilliseconds {
            return lhs.timelineMilliseconds < rhs.timelineMilliseconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
