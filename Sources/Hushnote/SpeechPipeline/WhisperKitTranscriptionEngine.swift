import Foundation
import WhisperKit

public actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    private struct SourceBuffer: Sendable {
        var samples: [Float] = []
        var firstFrameStartMilliseconds: Int64?
        var lastSequenceNumber: Int64?
        var lastDecodedSampleCount = 0
        var revision = 0
        var stablePrefixCount = 0
        var segments: [TranscriptSegment] = []
        var isDecoding = false
    }

    public nonisolated let descriptor = SpeechEngineDescriptor(
        id: "whisperkit",
        displayName: "WhisperKit",
        streamingKind: .slidingWindow,
        supportsWordTimestamps: true,
        supportedAccelerators: [.cpu, .gpu, .neuralEngine]
    )

    private var whisperKit: WhisperKit?
    private var selectedModel: SpeechModel?
    private var configuration: TranscriptionSessionConfiguration?
    private var buffers: [AudioSource: SourceBuffer] = [:]
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?

    public init() {}

    public func load(model: SpeechModel) async throws {
        guard configuration == nil else { throw SpeechPipelineError.sessionAlreadyRunning }
        guard model.provider == .whisperKit else { throw SpeechPipelineError.modelNotLoaded }

        let config = WhisperKitConfig(
            model: model.runtimeIdentifier,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        selectedModel = model
    }

    public func start(
        configuration: TranscriptionSessionConfiguration
    ) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        guard whisperKit != nil, selectedModel != nil else {
            throw SpeechPipelineError.modelNotLoaded
        }
        guard self.configuration == nil else {
            throw SpeechPipelineError.sessionAlreadyRunning
        }

        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        self.configuration = configuration
        buffers.removeAll(keepingCapacity: true)
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel() }
        }
        return pair.stream
    }

    public func push(_ frame: AudioFrame) async throws {
        guard let configuration else { throw SpeechPipelineError.sessionNotRunning }
        guard frame.meetingID == configuration.meetingID else {
            throw SpeechPipelineError.meetingMismatch
        }
        guard frame.sampleRate == WhisperKit.sampleRate else {
            throw SpeechPipelineError.unsupportedSampleRate(frame.sampleRate)
        }

        var buffer = buffers[frame.source] ?? SourceBuffer()
        if let last = buffer.lastSequenceNumber, frame.sequenceNumber <= last {
            throw SpeechPipelineError.invalidFrameSequence
        }
        buffer.firstFrameStartMilliseconds = buffer.firstFrameStartMilliseconds
            ?? frame.startMilliseconds
        buffer.lastSequenceNumber = frame.sequenceNumber
        buffer.samples.append(contentsOf: frame.samples)

        let addedSamples = buffer.samples.count - buffer.lastDecodedSampleCount
        let requiredSamples = Int(
            (Double(configuration.minimumDecodeIntervalMilliseconds) / 1_000.0)
                * Double(WhisperKit.sampleRate)
        )
        let shouldDecode = addedSamples >= requiredSamples && !buffer.isDecoding
        if shouldDecode { buffer.isDecoding = true }
        buffers[frame.source] = buffer

        guard shouldDecode else { return }
        do {
            try await decode(source: frame.source, final: false)
        } catch {
            continuation?.finish(throwing: error)
            clearSession()
            throw error
        }
    }

    public func finish() async throws {
        guard configuration != nil else { throw SpeechPipelineError.sessionNotRunning }

        do {
            for source in buffers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                try await decode(source: source, final: true)
            }
            continuation?.finish()
            clearSession()
        } catch {
            continuation?.finish(throwing: error)
            clearSession()
            throw error
        }
    }

    public func cancel() async {
        continuation?.finish()
        clearSession()
    }

    private func decode(source: AudioSource, final: Bool) async throws {
        guard let whisperKit, let configuration, var buffer = buffers[source] else {
            throw SpeechPipelineError.sessionNotRunning
        }
        guard !buffer.samples.isEmpty else {
            buffer.isDecoding = false
            buffers[source] = buffer
            return
        }

        var options = DecodingOptions(
            language: configuration.languageCode,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )

        let frozenPrefix = Array(buffer.segments.prefix(buffer.stablePrefixCount))
        if let frozenEnd = frozenPrefix.last?.endMilliseconds,
            let origin = buffer.firstFrameStartMilliseconds
        {
            options.clipTimestamps = [Float(frozenEnd - origin) / 1_000]
        }

        // Keep an immutable view of the samples being decoded. The actor can be
        // re-entered while Core ML is running, so later frames may already have
        // been appended to the live source buffer when this call returns.
        let decodedSamples = buffer.samples
        let result = try await whisperKit.transcribe(
            audioArray: decodedSamples,
            decodeOptions: options
        )
        let origin = buffer.firstFrameStartMilliseconds ?? 0
        // Keep the dependency segment type inferred here because this target's
        // domain model intentionally has the same concise name.
        let mapped: [TranscriptSegment] = result.flatMap(\.segments).map { segment in
            let start = origin + milliseconds(segment.start)
            let end = origin + milliseconds(segment.end)
            let words = (segment.words ?? []).enumerated().map { index, word in
                TranscriptWord(
                    id: "\(source.rawValue)-\(milliseconds(word.start) + origin)-\(index)",
                    text: word.word,
                    startMilliseconds: origin + milliseconds(word.start),
                    endMilliseconds: origin + milliseconds(word.end),
                    confidence: word.probability
                )
            }
            return TranscriptSegment(
                id: "\(source.rawValue)-\(start)-\(end)",
                meetingID: configuration.meetingID,
                source: source,
                revision: buffer.revision + 1,
                startMilliseconds: start,
                endMilliseconds: end,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: words,
                confidence: min(1, max(0, exp(segment.avgLogprob))),
                stability: .partial
            )
        }
        .filter { !$0.text.isEmpty && $0.endMilliseconds >= $0.startMilliseconds }
        .sorted {
            if $0.startMilliseconds != $1.startMilliseconds {
                return $0.startMilliseconds < $1.startMilliseconds
            }
            if $0.endMilliseconds != $1.endMilliseconds {
                return $0.endMilliseconds < $1.endMilliseconds
            }
            return $0.id < $1.id
        }

        let boundary = frozenPrefix.last?.endMilliseconds ?? Int64.min
        let tail = mapped.filter { $0.endMilliseconds > boundary }
        var hypothesis = frozenPrefix + tail

        // Preserve a text-only result from unusual decoding paths that do not
        // produce timestamped segments.
        if hypothesis.isEmpty,
            let text = result.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        {
            let duration = Int64(Double(decodedSamples.count) / 16.0)
            hypothesis = [
                TranscriptSegment(
                    id: "\(source.rawValue)-\(origin)-\(origin + duration)",
                    meetingID: configuration.meetingID,
                    source: source,
                    revision: buffer.revision + 1,
                    startMilliseconds: origin,
                    endMilliseconds: origin + duration,
                    text: text
                )
            ]
        }

        var updatedBuffer = buffers[source] ?? buffer
        updatedBuffer.revision = buffer.revision + 1
        updatedBuffer.lastDecodedSampleCount = decodedSamples.count
        updatedBuffer.segments = hypothesis
        updatedBuffer.stablePrefixCount = final
            ? hypothesis.count
            : max(
                buffer.stablePrefixCount,
                hypothesis.count - configuration.confirmationLagSegments
            )
        updatedBuffer.isDecoding = false
        buffers[source] = updatedBuffer

        continuation?.yield(
            TranscriptDelta(
                meetingID: configuration.meetingID,
                source: source,
                revision: updatedBuffer.revision,
                segments: hypothesis,
                stablePrefixCount: updatedBuffer.stablePrefixCount,
                isFinal: final
            )
        )
    }

    private func milliseconds(_ seconds: Float) -> Int64 {
        Int64((Double(seconds) * 1_000).rounded())
    }

    private func clearSession() {
        configuration = nil
        buffers.removeAll(keepingCapacity: true)
        continuation = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
