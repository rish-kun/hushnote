import Foundation
import WhisperKit

/// The single WhisperKit entry point the live engine depends on. Naming it lets
/// tests drive buffering, windowing, cancellation and identifier minting without
/// downloading a Core ML model.
protocol LiveSpeechDecoder: Sendable {
    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult]
}

/// `WhisperKit` is a non-Sendable class. The engine holds exactly one instance,
/// keeps it actor-confined, and never hands it to another isolation domain.
private struct WhisperKitDecoder: LiveSpeechDecoder, @unchecked Sendable {
    let kit: WhisperKit

    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }
}

public actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    private struct SourceBuffer: Sendable {
        /// Only the audio that is still in play. Committed samples are physically
        /// dropped, so a decode never re-encodes the whole meeting.
        var samples: [Float] = []
        /// Meeting time of `samples[0]`, added back to every emitted timestamp.
        var windowOriginMilliseconds: Int64?
        var lastSequenceNumber: Int64?
        var lastDecodedSampleCount = 0
        var revision = 0
        /// Monotonic within one session; see `TranscriptIdentifier`.
        var nextSegmentOrdinal = 0
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

    private var decoder: (any LiveSpeechDecoder)?
    private var configuration: TranscriptionSessionConfiguration?
    private var buffers: [AudioSource: SourceBuffer] = [:]
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    /// Decoding runs in tasks the engine owns, so it can be cancelled and waited
    /// on. One per source, because sources decode independently.
    private var decodeTasks: [AudioSource: Task<Void, Never>] = [:]
    /// Identifies the session a decode was started for. A decode that outlives
    /// its session must not write its stale buffer back over a live one.
    private var sessionToken = UUID()
    private var isFinishing = false

    public init() {}

    /// Test seam. Production code reaches the engine through `load(model:)`.
    init(decoder: some LiveSpeechDecoder) {
        self.decoder = decoder
    }

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
        decoder = WhisperKitDecoder(kit: try await WhisperKit(config))
    }

    public func start(
        configuration: TranscriptionSessionConfiguration
    ) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        guard decoder != nil else {
            throw SpeechPipelineError.modelNotLoaded
        }
        guard self.configuration == nil else {
            throw SpeechPipelineError.sessionAlreadyRunning
        }

        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        self.configuration = configuration
        sessionToken = UUID()
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
        buffer.windowOriginMilliseconds = buffer.windowOriginMilliseconds
            ?? frame.startMilliseconds
        buffer.lastSequenceNumber = frame.sequenceNumber
        buffer.samples.append(contentsOf: frame.samples)

        buffers[frame.source] = buffer
        // Enqueue only. The capture side consumes an AsyncStream that buffers
        // the newest 256 chunks, so awaiting a decode here makes the ring
        // overflow and silently discard audio that is already safe on disk.
        startDecodeIfNeeded(source: frame.source)
    }

    private func startDecodeIfNeeded(source: AudioSource) {
        guard let configuration, !isFinishing else { return }
        guard var buffer = buffers[source], !buffer.isDecoding else { return }
        let addedSamples = buffer.samples.count - buffer.lastDecodedSampleCount
        let requiredSamples = Self.samples(
            milliseconds: configuration.minimumDecodeIntervalMilliseconds
        )
        guard addedSamples >= requiredSamples else { return }

        buffer.isDecoding = true
        buffers[source] = buffer
        let token = sessionToken
        decodeTasks[source] = Task { [weak self] in
            await self?.runDecode(source: source, final: false, token: token)
        }
    }

    private func runDecode(source: AudioSource, final: Bool, token: UUID) async {
        do {
            try await decode(source: source, final: final, token: token)
        } catch is CancellationError {
            // The session that owned this decode is already torn down.
        } catch {
            guard token == sessionToken else { return }
            continuation?.finish(throwing: error)
            clearSession()
        }
    }

    public func finish() async throws {
        guard configuration != nil else { throw SpeechPipelineError.sessionNotRunning }
        let token = sessionToken

        do {
            for source in buffers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                try await decode(source: source, final: true, token: token)
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
        // The decode keeps a reference to nothing but its session token, so a
        // late completion is discarded rather than written back into the
        // dictionary `clearSession` just emptied.
        for task in decodeTasks.values { task.cancel() }
        decodeTasks.removeAll()
        continuation?.finish()
        clearSession()
    }

    private func decode(source: AudioSource, final: Bool, token: UUID) async throws {
        guard token == sessionToken else { throw CancellationError() }
        try Task.checkCancellation()
        guard let decoder, let configuration, var buffer = buffers[source] else {
            throw SpeechPipelineError.sessionNotRunning
        }
        guard !buffer.samples.isEmpty else {
            buffer.isDecoding = false
            buffers[source] = buffer
            return
        }

        // Committed audio is dropped after each decode, so the window only grows
        // past the cap when nothing commits — long silence, or VAD finding no
        // speech. Enforce the cap here rather than after the decode so the
        // decoder itself never sees more than one Whisper window. Never discard
        // audio a decode has not seen yet.
        let capSamples = Self.samples(milliseconds: Self.maximumWindowMilliseconds)
        if buffer.samples.count > capSamples {
            let excess = min(buffer.samples.count - capSamples, buffer.lastDecodedSampleCount)
            if excess > 0 {
                buffer.samples.removeFirst(excess)
                let trimmedOrigin = (buffer.windowOriginMilliseconds ?? 0)
                    + Self.milliseconds(samples: excess)
                buffer.windowOriginMilliseconds = trimmedOrigin
                buffer.lastDecodedSampleCount -= excess
                // Audio that is gone can no longer be revised.
                buffer.stablePrefixCount = max(
                    buffer.stablePrefixCount,
                    buffer.segments.prefix { $0.endMilliseconds <= trimmedOrigin }.count
                )
                buffers[source] = buffer
            }
        }

        // `clipTimestamps` is deliberately absent: WhisperKit clears it
        // unconditionally on the `.vad` path (`WhisperKit.swift`, the
        // `chunkedOptions?.clipTimestamps = []` line in `transcribe(audioArray:)`),
        // so asking it to skip committed audio never worked. The window itself
        // is trimmed instead.
        let options = DecodingOptions(
            language: configuration.languageCode,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )

        let frozenPrefix = Array(buffer.segments.prefix(buffer.stablePrefixCount))

        // Keep an immutable view of the samples being decoded. The actor can be
        // re-entered while Core ML is running, so later frames may already have
        // been appended to the live source buffer when this call returns.
        let decodedSamples = buffer.samples
        let result = try await decoder.decodeWindow(
            samples: decodedSamples,
            options: options
        )
        // The session may have ended while Core ML was running. Everything below
        // writes back into engine state, so a dead session stops here rather
        // than resurrecting the buffers `clearSession` just emptied.
        guard token == sessionToken else { throw CancellationError() }
        try Task.checkCancellation()
        let origin = buffer.windowOriginMilliseconds ?? 0
        // Every decoded segment consumes one ordinal whether or not it survives
        // filtering, so an identifier is never handed out twice.
        let decoded = result.flatMap(\.segments)
        var nextOrdinal = buffer.nextSegmentOrdinal + decoded.count
        // Keep the dependency segment type inferred here because this target's
        // domain model intentionally has the same concise name.
        let mapped: [TranscriptSegment] = decoded.enumerated().map { offset, segment in
            let start = origin + milliseconds(segment.start)
            let end = origin + milliseconds(segment.end)
            let id = TranscriptIdentifier.segment(
                meetingID: configuration.meetingID,
                source: source,
                pass: .live,
                ordinal: buffer.nextSegmentOrdinal + offset
            )
            let words = (segment.words ?? []).enumerated().map { index, word in
                TranscriptWord(
                    id: TranscriptIdentifier.word(segmentID: id, index: index),
                    text: word.word,
                    startMilliseconds: origin + milliseconds(word.start),
                    endMilliseconds: origin + milliseconds(word.end),
                    confidence: word.probability
                )
            }
            return TranscriptSegment(
                id: id,
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
        // Clip on start, not end. A re-decoded segment that starts inside
        // committed audio repeats text the frozen prefix already holds, and it
        // sorts ahead of a frozen segment, which breaks any consumer that treats
        // the prefix as positional.
        let tail = mapped.filter { $0.startMilliseconds >= boundary }
        var hypothesis = frozenPrefix + tail

        // Preserve a text-only result from unusual decoding paths that do not
        // produce timestamped segments.
        if hypothesis.isEmpty,
            let text = result.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        {
            let duration = Int64(Double(decodedSamples.count) / 16.0)
            let id = TranscriptIdentifier.segment(
                meetingID: configuration.meetingID,
                source: source,
                pass: .live,
                ordinal: nextOrdinal
            )
            nextOrdinal += 1
            hypothesis = [
                TranscriptSegment(
                    id: id,
                    meetingID: configuration.meetingID,
                    source: source,
                    revision: buffer.revision + 1,
                    startMilliseconds: origin,
                    endMilliseconds: origin + duration,
                    text: text
                )
            ]
        }

        let stablePrefixCount = final
            ? hypothesis.count
            : max(
                buffer.stablePrefixCount,
                hypothesis.count - configuration.confirmationLagSegments
            )

        // Everything before the committed boundary is settled, so its audio is
        // dropped. Without this the buffer grows for the whole meeting and each
        // decode re-runs the encoder from t=0, which crosses a real-time factor
        // of 1.0 within minutes and never recovers.
        let windowEnd = origin + Self.milliseconds(samples: decodedSamples.count)
        let committedEnd = hypothesis.prefix(stablePrefixCount).last?.endMilliseconds ?? origin
        let droppedSamples = min(
            decodedSamples.count,
            Self.samples(milliseconds: max(0, min(committedEnd, windowEnd) - origin))
        )

        // Read the live buffer rather than falling back to the local copy: the
        // fallback reinstated a buffer that no longer exists.
        guard var updatedBuffer = buffers[source] else { throw CancellationError() }
        updatedBuffer.revision = buffer.revision + 1
        updatedBuffer.nextSegmentOrdinal = nextOrdinal
        updatedBuffer.samples.removeFirst(droppedSamples)
        updatedBuffer.windowOriginMilliseconds = origin + Self.milliseconds(samples: droppedSamples)
        updatedBuffer.lastDecodedSampleCount = decodedSamples.count - droppedSamples
        updatedBuffer.segments = hypothesis
        updatedBuffer.stablePrefixCount = stablePrefixCount
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

    /// Upper bound on uncommitted audio. Matching WhisperKit's own 30s window
    /// (`Constants.defaultWindowSamples`) keeps a capped window off the VAD
    /// chunking path, which is the expensive branch.
    private static let maximumWindowMilliseconds: Int64 = 30_000

    private static func milliseconds(samples: Int) -> Int64 {
        Int64(samples) * 1_000 / Int64(WhisperKit.sampleRate)
    }

    private static func samples(milliseconds: Int64) -> Int {
        Int(milliseconds * Int64(WhisperKit.sampleRate) / 1_000)
    }

    private func clearSession() {
        configuration = nil
        buffers.removeAll(keepingCapacity: true)
        continuation = nil
        isFinishing = false
        // Retiring the token is what makes a decode that is still inside Core ML
        // harmless: it can no longer match, so it cannot write anything back.
        sessionToken = UUID()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
