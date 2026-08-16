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
        transcript: [InsightTranscriptSegment]
    ) async throws -> ValidatedMeetingInsights {
        let normalized = normalized(transcript)
        let chunks = chunker.chunks(for: normalized)
        guard !chunks.isEmpty else { throw InsightPipelineError.emptyTranscript }

        var firstPass: [MeetingInsights] = []
        for chunk in chunks {
            let output = try await provider.complete(promptBuilder.extractionRequest(chunk: chunk))
            guard let draft = decode(MeetingInsights.self, from: output),
                  let validated = validator.validate(draft, against: normalized) else {
                continue
            }
            firstPass.append(validated.insights)
        }
        guard !firstPass.isEmpty else { throw InsightPipelineError.unsupportedCitations }

        let draftData = try encoder.encode(firstPass)
        guard let draftJSON = String(data: draftData, encoding: .utf8) else {
            throw InsightPipelineError.invalidProviderOutput
        }
        let finalOutput = try await provider.complete(
            promptBuilder.synthesisRequest(validatedDraftsJSON: draftJSON)
        )
        guard let finalDraft = decode(MeetingInsights.self, from: finalOutput) else {
            throw InsightPipelineError.invalidProviderOutput
        }
        guard let final = validator.validate(finalDraft, against: normalized) else {
            throw InsightPipelineError.unsupportedCitations
        }
        return final
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

