import Foundation
import WhisperKit

public enum FinalTranscriptionProgress: Sendable {
    case loadingModel
    case transcribing
}

/// Accuracy-first full-file ASR used after capture stops. It owns its model so
/// the live engine can be released before finalization begins.
public actor WhisperKitFinalTranscriber {
    public init() {}

    public func transcribe(
        meetingID: UUID,
        tracks: [MeetingAudioTrack],
        model: SpeechModel,
        languageCode: String? = nil,
        revision: Int,
        progress: (@Sendable (FinalTranscriptionProgress) async -> Void)? = nil
    ) async throws -> TranscriptSnapshot {
        await progress?(.loadingModel)
        let kit = try await WhisperKit(WhisperKitConfig(
            model: model.runtimeIdentifier,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        ))
        await progress?(.transcribing)
        let ordered = tracks.sorted { $0.source.rawValue < $1.source.rawValue }
        let results = await kit.transcribeWithResults(
            audioPaths: ordered.map { $0.fileURL.path },
            decodeOptions: DecodingOptions(
                language: languageCode,
                wordTimestamps: true,
                chunkingStrategy: .vad
            )
        )

        var segments: [TranscriptSegment] = []
        for (index, result) in results.enumerated() {
            guard index < ordered.count else { continue }
            let source = ordered[index].source
            let transcription = try result.get()
            for item in transcription {
                segments.append(contentsOf: item.segments.map { segment in
                    let start = milliseconds(segment.start)
                    let end = milliseconds(segment.end)
                    let words = (segment.words ?? []).enumerated().map { wordIndex, word in
                        TranscriptWord(
                            id: "final-\(source.rawValue)-\(milliseconds(word.start))-\(wordIndex)",
                            text: word.word,
                            startMilliseconds: milliseconds(word.start),
                            endMilliseconds: milliseconds(word.end),
                            confidence: word.probability
                        )
                    }
                    return TranscriptSegment(
                        id: "final-\(source.rawValue)-\(start)-\(end)",
                        meetingID: meetingID,
                        source: source,
                        revision: revision,
                        startMilliseconds: start,
                        endMilliseconds: end,
                        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        words: words,
                        confidence: exp(segment.avgLogprob),
                        stability: .final
                    )
                }.filter { !$0.text.isEmpty })
            }
        }

        guard !segments.isEmpty else { throw SpeechPipelineError.noTranscriptionResult }
        return TranscriptSnapshot(
            meetingID: meetingID,
            revision: revision,
            segments: segments.sorted {
                ($0.startMilliseconds, $0.source.rawValue, $0.id)
                    < ($1.startMilliseconds, $1.source.rawValue, $1.id)
            }
        )
    }

    private func milliseconds(_ seconds: Float) -> Int64 {
        Int64((Double(seconds) * 1_000).rounded())
    }
}
