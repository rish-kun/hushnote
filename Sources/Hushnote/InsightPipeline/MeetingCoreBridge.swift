import Foundation

public extension InsightTranscriptSegment {
    init(transcriptSegment: TranscriptSegment) {
        self.init(
            id: transcriptSegment.id,
            startMilliseconds: transcriptSegment.startMilliseconds,
            endMilliseconds: transcriptSegment.endMilliseconds,
            speaker: transcriptSegment.speakerName ?? transcriptSegment.speakerID,
            text: transcriptSegment.text
        )
    }
}

public extension TranscriptSnapshot {
    var insightSegments: [InsightTranscriptSegment] {
        segments.map(InsightTranscriptSegment.init(transcriptSegment:))
    }
}

public extension InsightPipeline {
    func generateInsights(
        snapshot: TranscriptSnapshot
    ) async throws -> ValidatedMeetingInsights {
        try await generateInsights(transcript: snapshot.insightSegments)
    }

    func answer(
        question: String,
        snapshot: TranscriptSnapshot
    ) async throws -> ValidatedQuestionAnswer {
        try await answer(question: question, transcript: snapshot.insightSegments)
    }
}

