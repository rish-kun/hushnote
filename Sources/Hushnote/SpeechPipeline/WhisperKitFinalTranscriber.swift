import Foundation
import WhisperKit

public enum FinalTranscriptionProgress: Sendable {
    case loadingModel
    case transcribing
}

/// The single WhisperKit entry point the final pass depends on. It deliberately
/// keeps the per-path `Result`, because partial success is the whole point when
/// recovering a damaged recording.
protocol FinalSpeechDecoder: Sendable {
    func decodeFiles(
        paths: [String],
        options: DecodingOptions
    ) async -> [Result<[TranscriptionResult], any Error>]
}

/// `WhisperKit` is a non-Sendable class. The transcriber builds one, keeps it
/// actor-confined for the length of one pass, and then releases it.
private struct WhisperKitFileDecoder: FinalSpeechDecoder, @unchecked Sendable {
    let kit: WhisperKit

    func decodeFiles(
        paths: [String],
        options: DecodingOptions
    ) async -> [Result<[TranscriptionResult], any Error>] {
        await kit.transcribeWithResults(audioPaths: paths, decodeOptions: options)
    }
}

/// Accuracy-first full-file ASR used after capture stops. It owns its model so
/// the live engine can be released before finalization begins.
public actor WhisperKitFinalTranscriber {
    private let injectedDecoder: (any FinalSpeechDecoder)?
    private let downloadBase: URL?

    public init(downloadBase: URL? = nil) {
        injectedDecoder = nil
        self.downloadBase = downloadBase
    }

    /// Test seam. Production code always loads a real model.
    init(decoder: some FinalSpeechDecoder) {
        injectedDecoder = decoder
        downloadBase = nil
    }

    static func modelConfiguration(
        for model: SpeechModel,
        downloadBase: URL? = nil
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            model: model.runtimeIdentifier,
            downloadBase: downloadBase,
            verbose: false,
            // Prewarming halves peak compilation memory at the cost of doubling
            // load time. This model is loaded, used for one pass and released,
            // so the user only ever sees the cost.
            prewarm: false,
            load: true,
            download: true
        )
    }

    public func transcribe(
        meetingID: UUID,
        tracks: [MeetingAudioTrack],
        model: SpeechModel,
        languageCode: String? = nil,
        revision: Int,
        startingOrdinals: [AudioSource: Int] = [:],
        progress: (@Sendable (FinalTranscriptionProgress) async -> Void)? = nil
    ) async throws -> TranscriptSnapshot {
        await progress?(.loadingModel)
        let decoder: any FinalSpeechDecoder
        if let injectedDecoder {
            decoder = injectedDecoder
        } else {
            decoder = WhisperKitFileDecoder(
                kit: try await WhisperKit(Self.modelConfiguration(for: model, downloadBase: downloadBase))
            )
        }
        await progress?(.transcribing)
        let ordered = tracks.sorted {
            ($0.source.rawValue, $0.timelineStartMilliseconds, $0.fileURL.path)
                < ($1.source.rawValue, $1.timelineStartMilliseconds, $1.fileURL.path)
        }
        let results = await decoder.decodeFiles(
            paths: ordered.map { $0.fileURL.path },
            // See the live engine: `skipSpecialTokens` defaults to false, which
            // leaves `<|startoftranscript|>` and the `<|6.88|>` timestamp
            // tokens inside the decoded segment text.
            options: DecodingOptions(
                language: languageCode,
                skipSpecialTokens: true,
                wordTimestamps: true,
                // Left unset this inherits WhisperKit's macOS default of 16,
                // which is more decoder state than a 16 GB machine has room
                // for. See `FinalDecodeConcurrency`.
                concurrentWorkerCount: FinalDecodeConcurrency.workerCount(
                    physicalMemory: ProcessInfo.processInfo.physicalMemory
                ),
                chunkingStrategy: .vad
            )
        )

        var segments: [TranscriptSegment] = []
        var failures: [any Error] = []
        // Appended sessions transcribe only their new takes. Their caller seeds
        // each source above the ordinals already present in the meeting so the
        // final-pass primary keys remain unique without decoding old audio.
        var nextOrdinal = startingOrdinals.mapValues { max(0, $0) }
        for (index, result) in results.enumerated() {
            guard index < ordered.count else { continue }
            let source = ordered[index].source
            let transcription: [TranscriptionResult]
            switch result {
            case .success(let value):
                transcription = value
            case .failure(let error):
                // WhisperKit reports one result per path so a partially damaged
                // recording can still be salvaged. Throwing on the first failure
                // discarded every track that had decoded successfully, which is
                // total data loss on exactly the recordings that need recovery.
                failures.append(error)
                continue
            }
            // One counter per source across every take. Whisper's `(start,
            // end)` is not unique, and a toggled microphone can contribute
            // several files with the same source role.
            var ordinal = nextOrdinal[source, default: 0]
            let timelineOffset = ordered[index].timelineStartMilliseconds
            for item in transcription {
                segments.append(contentsOf: item.segments.map { segment in
                    let start = timelineOffset + milliseconds(segment.start)
                    let end = timelineOffset + milliseconds(segment.end)
                    let id = TranscriptIdentifier.segment(
                        meetingID: meetingID,
                        source: source,
                        pass: .final,
                        ordinal: ordinal
                    )
                    ordinal += 1
                    let words = (segment.words ?? []).enumerated().map { wordIndex, word in
                        TranscriptWord(
                            id: TranscriptIdentifier.word(segmentID: id, index: wordIndex),
                            text: WhisperSpecialToken.cleanedWordText(word.word),
                            startMilliseconds: timelineOffset + milliseconds(word.start),
                            endMilliseconds: timelineOffset + milliseconds(word.end),
                            confidence: word.probability
                        )
                    }
                    // A word that was nothing but control tokens carries no
                    // speech, so it is dropped rather than stored empty.
                    .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return TranscriptSegment(
                        id: id,
                        meetingID: meetingID,
                        source: source,
                        revision: revision,
                        startMilliseconds: start,
                        endMilliseconds: end,
                        text: WhisperSpecialToken.cleanedSegmentText(segment.text),
                        words: words,
                        confidence: exp(segment.avgLogprob),
                        stability: .final
                    )
                }.filter { !$0.text.isEmpty })
            }
            nextOrdinal[source] = ordinal
        }

        guard !segments.isEmpty else {
            if let failure = failures.first { throw failure }
            throw SpeechPipelineError.noTranscriptionResult
        }
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
