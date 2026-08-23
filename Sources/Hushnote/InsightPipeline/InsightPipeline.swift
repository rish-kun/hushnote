import Foundation

public enum InsightPipelineError: Error, Equatable, LocalizedError, Sendable {
    case emptyTranscript
    case invalidProviderOutput
    case unsupportedCitations

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: "The transcript does not contain any text."
        case .invalidProviderOutput: "The selected provider did not return the required insight schema."
        case .unsupportedCitations: "The selected provider returned no transcript-supported result."
        }
    }
}

/// Stable milestones a caller can render while a multi-pass summary is running.
/// The callback is intentionally observational: it cannot alter validation or
/// provider selection.
public enum InsightPipelineProgress: Equatable, Sendable {
    case preparing
    case extracting(current: Int, total: Int)
    case synthesizing
    case validating
    case completed
}

public struct InsightPipeline: Sendable {
    private let provider: any InsightProvider
    private let chunker: TranscriptChunker
    private let promptBuilder: InsightPromptBuilder
    private let validator: CitationValidator
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        provider: any InsightProvider,
        chunker: TranscriptChunker = TranscriptChunker(),
        promptBuilder: InsightPromptBuilder = InsightPromptBuilder(),
        validator: CitationValidator = CitationValidator()
    ) {
        self.provider = provider
        self.chunker = chunker
        self.promptBuilder = promptBuilder
        self.validator = validator
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Generates insights with two local citation gates: once per extraction chunk and again after synthesis.
    public func generateInsights(
        transcript: [InsightTranscriptSegment],
        progress: @escaping @Sendable (InsightPipelineProgress) async -> Void = { _ in }
    ) async throws -> ValidatedMeetingInsights {
        await progress(.preparing)
        let normalized = normalized(transcript)
        let chunks = chunker.chunks(for: normalized)
        guard !chunks.isEmpty else { throw InsightPipelineError.emptyTranscript }

        var firstPass: [ValidatedMeetingInsights] = []
        var decodedProviderOutput = false
        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await progress(.extracting(current: offset + 1, total: chunks.count))
            let output = try await provider.complete(promptBuilder.extractionRequest(chunk: chunk))
            guard let draft = decode(MeetingInsights.self, from: output) else {
                continue
            }
            decodedProviderOutput = true
            guard let validated = validator.validate(draft, against: normalized) else { continue }
            firstPass.append(validated)
        }
        guard !firstPass.isEmpty else {
            throw decodedProviderOutput
                ? InsightPipelineError.unsupportedCitations
                : InsightPipelineError.invalidProviderOutput
        }

        // Most meetings fit in one chunk. Its extraction has already passed
        // the complete local citation gate, so a second model call can only add
        // latency or damage its grounding.
        if firstPass.count == 1 {
            await progress(.validating)
            await progress(.completed)
            return firstPass[0]
        }

        let draftData = try encoder.encode(firstPass.map(\.insights))
        guard let draftJSON = String(data: draftData, encoding: .utf8) else {
            throw InsightPipelineError.invalidProviderOutput
        }
        try Task.checkCancellation()
        await progress(.synthesizing)
        let finalOutput = try await provider.complete(
            promptBuilder.synthesisRequest(validatedDraftsJSON: draftJSON)
        )
        await progress(.validating)
        guard let finalDraft = decode(MeetingInsights.self, from: finalOutput),
              let final = validator.validate(finalDraft, against: normalized) else {
            // Synthesis is an optional presentation pass over facts that have
            // already been validated. If it loses the schema or citations,
            // return those facts directly instead of turning a sound
            // extraction into a failed meeting summary.
            let fallback = conservativeFallback(from: firstPass)
            await progress(.completed)
            return fallback
        }
        await progress(.completed)
        return final
    }

    private func conservativeFallback(
        from drafts: [ValidatedMeetingInsights]
    ) -> ValidatedMeetingInsights {
        let insights = drafts.map(\.insights)
        let reports = drafts.map(\.validation)
        return ValidatedMeetingInsights(
            insights: MeetingInsights(
                overview: insights[0].overview,
                keyPoints: unique(insights.flatMap(\.keyPoints)),
                decisions: unique(insights.flatMap(\.decisions)),
                actionItems: unique(insights.flatMap(\.actionItems)),
                openQuestions: unique(insights.flatMap(\.openQuestions)),
                risks: unique(insights.flatMap(\.risks)),
                topics: unique(insights.flatMap(\.topics))
            ),
            validation: InsightValidationReport(
                rejectedClaims: reports.reduce(0) { $0 + $1.rejectedClaims },
                rejectedCitations: reports.reduce(0) { $0 + $1.rejectedCitations }
            )
        )
    }

    private func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var ids: Set<T.ID> = []
        return values.filter { ids.insert($0.id).inserted }
    }

    public func answer(
        question: String,
        transcript: [InsightTranscriptSegment]
    ) async throws -> ValidatedQuestionAnswer {
        let normalized = normalized(transcript)
        guard !normalized.isEmpty else { throw InsightPipelineError.emptyTranscript }
        let output = try await provider.complete(
            promptBuilder.answerRequest(question: question, transcript: normalized)
        )
        guard let answer = decode(MeetingQuestionAnswer.self, from: output) else {
            throw InsightPipelineError.invalidProviderOutput
        }
        guard let validated = validator.validate(answer, against: normalized) else {
            throw InsightPipelineError.unsupportedCitations
        }
        return validated
    }

    private func normalized(_ transcript: [InsightTranscriptSegment]) -> [InsightTranscriptSegment] {
        transcript.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.endMilliseconds >= segment.startMilliseconds else { return nil }
            return InsightTranscriptSegment(
                id: segment.id,
                startMilliseconds: segment.startMilliseconds,
                endMilliseconds: segment.endMilliseconds,
                speaker: segment.speaker,
                text: text
            )
        }.sorted {
            ($0.startMilliseconds, $0.endMilliseconds, $0.id)
                < ($1.startMilliseconds, $1.endMilliseconds, $1.id)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        let trimmed = stripMarkdownFence(from: string)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func stripMarkdownFence(from value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }
        if let firstLineEnd = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: firstLineEnd)...])
        }
        if result.hasSuffix("```") {
            result.removeLast(3)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
