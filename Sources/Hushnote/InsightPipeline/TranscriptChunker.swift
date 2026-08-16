import Foundation

public struct TranscriptChunk: Equatable, Sendable, Identifiable {
    public let id: Int
    public let segments: [InsightTranscriptSegment]

    public init(id: Int, segments: [InsightTranscriptSegment]) {
        self.id = id
        self.segments = segments
    }
}

public struct TranscriptChunker: Sendable {
    public let maximumCharacters: Int
    public let overlapSegments: Int

    public init(maximumCharacters: Int = 12_000, overlapSegments: Int = 1) {
        precondition(maximumCharacters > 0)
        precondition(overlapSegments >= 0)
        self.maximumCharacters = maximumCharacters
        self.overlapSegments = overlapSegments
    }

    public func chunks(for transcript: [InsightTranscriptSegment]) -> [TranscriptChunk] {
        let expanded = transcript.flatMap(splitIfNeeded)
        guard !expanded.isEmpty else { return [] }

        var result: [TranscriptChunk] = []
        var current: [InsightTranscriptSegment] = []
        var count = 0

        for segment in expanded {
            let segmentCost = segment.text.count + 96
            if !current.isEmpty, count + segmentCost > maximumCharacters {
                result.append(TranscriptChunk(id: result.count, segments: current))
                current = Array(current.suffix(overlapSegments))
                count = current.reduce(0) { $0 + $1.text.count + 96 }
            }
            current.append(segment)
            count += segmentCost
        }

        if !current.isEmpty {
            result.append(TranscriptChunk(id: result.count, segments: current))
        }
        return result
    }

    private func splitIfNeeded(_ segment: InsightTranscriptSegment) -> [InsightTranscriptSegment] {
        let textBudget = max(1, maximumCharacters - 96)
        guard segment.text.count > textBudget else { return [segment] }

        var pieces: [InsightTranscriptSegment] = []
        var remainder = segment.text[...]
        while !remainder.isEmpty {
            var end = remainder.index(remainder.startIndex, offsetBy: min(textBudget, remainder.count))
            if end != remainder.endIndex,
               let boundary = remainder[..<end].lastIndex(where: { $0.isWhitespace }) {
                end = boundary
            }
            let piece = remainder[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append(
                    InsightTranscriptSegment(
                        id: segment.id,
                        startMilliseconds: segment.startMilliseconds,
                        endMilliseconds: segment.endMilliseconds,
                        speaker: segment.speaker,
                        text: piece
                    )
                )
            }
            remainder = remainder[end...].drop(while: { $0.isWhitespace })
        }
        return pieces
    }
}

