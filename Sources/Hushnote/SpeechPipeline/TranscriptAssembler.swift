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

        // A provider emits a complete source hypothesis. Positions already frozen
        // are intentionally ignored, even if a later hypothesis tries to alter them.
        if incoming.count > state.frozen.count {
            let newlyStableEnd = max(state.frozen.count, requestedStableCount)
            if newlyStableEnd > state.frozen.count {
                state.frozen.append(contentsOf: incoming[state.frozen.count..<newlyStableEnd].map {
                    withStability($0, delta.isFinal ? .final : .stable)
                })
            }

            state.mutable = incoming.dropFirst(newlyStableEnd).map {
                withStability($0, delta.isFinal ? .final : .partial)
            }
        } else {
            state.mutable = []
        }

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
