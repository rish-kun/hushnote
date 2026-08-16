import Foundation

/// Applies full per-source hypotheses while preserving every committed prefix.
public struct TranscriptAssembler: Sendable {
    private struct SourceState: Sendable {
        var lastRevision = -1
        var frozen: [TranscriptSegment] = []
        var mutable: [TranscriptSegment] = []
    }

    public let meetingID: UUID
    private var sourceStates: [AudioSource: SourceState] = [:]
    private var snapshotRevision = 0

    public init(meetingID: UUID) {
        self.meetingID = meetingID
    }

    @discardableResult
    public mutating func apply(_ delta: TranscriptDelta) -> TranscriptSnapshot {
        guard delta.meetingID == meetingID else { return snapshot }

        var state = sourceStates[delta.source] ?? SourceState()
        guard delta.revision > state.lastRevision else { return snapshot }

        let incoming = normalized(delta.segments, for: delta)
        let requestedStableCount = delta.isFinal
            ? incoming.count
            : min(max(0, delta.stablePrefixCount), incoming.count)

        // A provider emits a complete source hypothesis. Audio already frozen is
        // intentionally ignored, even if a later hypothesis tries to re-cut it.
        //
        // The boundary is a time, not an array position. `normalized` re-sorts
        // every hypothesis, so a re-decoded segment that starts inside frozen
        // audio shifts every later index by one: position k stops meaning the
        // same utterance, which duplicated a frozen segment under its own ID and
        // dropped the new speech that had taken its place. Identifiers are
        // deduplicated for the same reason — a duplicate makes
        // `MeetingStore.validate` reject the whole write.
        let frozenEnd = state.frozen.last?.endMilliseconds
        var seenIDs = Set(state.frozen.map(\.id))
        var newlyStable: [TranscriptSegment] = []
        var mutable: [TranscriptSegment] = []
        for (index, segment) in incoming.enumerated() {
            if let frozenEnd, segment.startMilliseconds < frozenEnd { continue }
            guard seenIDs.insert(segment.id).inserted else { continue }
            if index < requestedStableCount {
                newlyStable.append(withStability(segment, delta.isFinal ? .final : .stable))
            } else {
                mutable.append(withStability(segment, delta.isFinal ? .final : .partial))
            }
        }
        // Freezing happens whether or not the hypothesis grew. A hypothesis that
        // is merely shorter — trailing silence, VAD dropping a low-energy tail —
        // used to blank the whole mutable tail and add nothing back.
        state.frozen.append(contentsOf: newlyStable)
        state.mutable = mutable

        if delta.isFinal {
            state.frozen = state.frozen.map { withStability($0, .final) }
            state.mutable = []
        }

        state.lastRevision = delta.revision
        sourceStates[delta.source] = state
        snapshotRevision += 1
        return snapshot
    }

    public var snapshot: TranscriptSnapshot {
        let combined = sourceStates.values
            .flatMap { $0.frozen + $0.mutable }
            .sorted(by: Self.segmentOrder)
        return TranscriptSnapshot(
            meetingID: meetingID,
            revision: snapshotRevision,
            segments: combined
        )
    }

    public mutating func reset() {
        sourceStates.removeAll(keepingCapacity: true)
        snapshotRevision += 1
    }

    private func normalized(
        _ segments: [TranscriptSegment],
        for delta: TranscriptDelta
    ) -> [TranscriptSegment] {
        segments
            .filter {
                $0.meetingID == meetingID
                    && $0.source == delta.source
                    && $0.startMilliseconds >= 0
                    && $0.endMilliseconds >= $0.startMilliseconds
            }
            .sorted(by: Self.segmentOrder)
            .map { segment in
                var segment = segment
                segment.revision = delta.revision
                return segment
            }
    }

    private func withStability(
        _ segment: TranscriptSegment,
        _ stability: TranscriptStability
    ) -> TranscriptSegment {
        var segment = segment
        segment.stability = max(segment.stability, stability)
        return segment
    }

    private static func segmentOrder(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        if lhs.source != rhs.source {
            return lhs.source.rawValue < rhs.source.rawValue
        }
        return lhs.id < rhs.id
    }
}
