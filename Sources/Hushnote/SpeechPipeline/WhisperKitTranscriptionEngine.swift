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
    /// How to build the decoder again. The engine keeps the recipe rather than
    /// only the result, because the model is released at the end of every
    /// session and `start` has to be able to put it back without the caller
    /// having to know it went away.
    private var makeDecoder: (@Sendable () async throws -> any LiveSpeechDecoder)?
    /// Rebuilding costs hundreds of megabytes, so two overlapping starts must
    /// not each pay for one.
    private var isRebuildingDecoder = false
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

    /// Test seam. Production code reaches the engine through `load(model:)`,
    /// which installs a closure of exactly this shape, so a test exercises the
    /// same release-and-rebuild path a real session does.
    init(makeDecoder: @escaping @Sendable () async throws -> any LiveSpeechDecoder) {
        self.makeDecoder = makeDecoder
    }

    public func load(model: SpeechModel) async throws {
        try await load(model: model, modelFolder: nil, downloadBase: nil)
    }

    /// - Parameter modelFolder: artifacts already fetched by
    ///   `SpeechModelDownloading`. Loading used to mean downloading too, which
    ///   is why the models screen could not show a fetch that was 24% done:
    ///   the download was buried inside one opaque await that also prewarmed
    ///   and compiled. Given a folder, WhisperKit loads from it and resolves
    ///   nothing over the network.
    public func load(
        model: SpeechModel,
        modelFolder: URL?,
        downloadBase: URL? = nil
    ) async throws {
        guard configuration == nil else { throw SpeechPipelineError.sessionAlreadyRunning }
        guard model.provider == .whisperKit else { throw SpeechPipelineError.modelNotLoaded }

        let build: @Sendable () async throws -> any LiveSpeechDecoder = {
            let config = Self.modelConfiguration(
                for: model,
                modelFolder: modelFolder,
                downloadBase: downloadBase
            )
            return WhisperKitDecoder(kit: try await WhisperKit(config))
        }
        // Load eagerly: a caller that asked for a model wants to hear here that
        // it could not be compiled, not at the start of a meeting.
        decoder = try await build()
        makeDecoder = build
    }

    static func modelConfiguration(
        for model: SpeechModel,
        modelFolder: URL?,
        downloadBase: URL?
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            model: modelFolder == nil ? model.runtimeIdentifier : nil,
            downloadBase: downloadBase,
            modelFolder: modelFolder?.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: modelFolder == nil
        )
    }

    public func start(
        configuration: TranscriptionSessionConfiguration
    ) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        guard self.configuration == nil, !isRebuildingDecoder else {
            throw SpeechPipelineError.sessionAlreadyRunning
        }
        if decoder == nil {
            guard let makeDecoder else { throw SpeechPipelineError.modelNotLoaded }
            isRebuildingDecoder = true
            defer { isRebuildingDecoder = false }
            decoder = try await makeDecoder()
        }
        // Rebuilding suspends, so a session can have been opened meanwhile.
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

        // WhisperKit holds mutable timing and decoder state and makes no
        // re-entrancy promise, so the final decode has to wait for the live one.
        // Ordering matters too: a late non-final delta arriving after the final
        // delta would un-finalize the transcript.
        isFinishing = true
        for task in decodeTasks.values { _ = await task.value }
        decodeTasks.removeAll()
        // An in-flight decode can fail, which tears the session down.
        guard token == sessionToken, configuration != nil else {
            isFinishing = false
            throw SpeechPipelineError.sessionNotRunning
        }

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
        // `skipSpecialTokens` defaults to false, which makes WhisperKit decode
        // the control vocabulary into the segment text it hands back:
        // `<|startoftranscript|><|en|><|transcribe|>` on the first segment of a
        // decode and a `<|6.88|>` timestamp token on either side of every one
        // (`SegmentSeeker.swift`, the `options.skipSpecialTokens ? wordTokens :
        // slicedTokens` lines). That text is what the app renders, stores,
        // exports and cites, so it has to be asked for clean.
        let options = DecodingOptions(
            language: configuration.languageCode,
            skipSpecialTokens: true,
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
                    text: WhisperSpecialToken.cleanedWordText(word.word),
                    startMilliseconds: origin + milliseconds(word.start),
                    endMilliseconds: origin + milliseconds(word.end),
                    confidence: word.probability
                )
            }
            // A word that was nothing but control tokens carries no speech.
            // Keeping it would store an empty row that scrubbing can seek to.
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return TranscriptSegment(
                id: id,
                meetingID: configuration.meetingID,
                source: source,
                revision: buffer.revision + 1,
                startMilliseconds: start,
                endMilliseconds: end,
                text: WhisperSpecialToken.cleanedSegmentText(segment.text),
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
            let text = WhisperSpecialToken
                .cleanedSegmentText(result.map(\.text).joined(separator: " "))
                .nilIfEmpty
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
        // Handles only, never live work: `cancel` cancels before clearing, and
        // the failure path runs inside the task being dropped. This keeps a new
        // session from waiting on a dead one's decode.
        decodeTasks.removeAll()
        // Retiring the token is what makes a decode that is still inside Core ML
        // harmless: it can no longer match, so it cannot write anything back.
        sessionToken = UUID()
        // The live model is ~600 MB and the final pass loads a different
        // artifact of its own, so a session that has ended must not keep its
        // weights resident across finalization. A decode still inside Core ML
        // captured the instance before its first suspension and finishes on
        // that; the retired token discards its result exactly as before.
        decoder = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
