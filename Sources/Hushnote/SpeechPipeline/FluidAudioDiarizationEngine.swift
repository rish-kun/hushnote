import FluidAudio
import Foundation

public actor FluidAudioDiarizationEngine: SpeakerDiarizationEngine {
    /// FluidAudio's manager is internally immutable after model preparation but
    /// does not yet declare Sendable. This wrapper is kept actor-confined, and
    /// `isProcessing` prevents reentrant use while its async pipeline runs.
    private struct ManagerHandle: @unchecked Sendable {
        let value: OfflineDiarizerManager
    }

    public nonisolated let descriptor = SpeechEngineDescriptor(
        id: "fluidaudio.offline-diarizer",
        displayName: "FluidAudio Speaker Diarization",
        streamingKind: .utterance,
        supportsWordTimestamps: false,
        supportedAccelerators: [.cpu, .gpu, .neuralEngine]
    )

    private var preparedDefaultManager: ManagerHandle?
    private var isProcessing = false

    public init() {}

    public func prepare() async throws {
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        preparedDefaultManager = ManagerHandle(value: manager)
    }

    public func diarize(
        audioFileURL: URL,
        configuration: DiarizationConfiguration = DiarizationConfiguration()
    ) async throws -> [SpeakerTurn] {
        guard !isProcessing else { throw SpeechPipelineError.sessionAlreadyRunning }
        isProcessing = true
        defer { isProcessing = false }
        let manager = try await manager(for: configuration)
        let result = try await manager.value.process(audioFileURL)
        return Self.map(result)
    }

    public func diarize(
        samples: [Float],
        sampleRate: Int,
        configuration: DiarizationConfiguration = DiarizationConfiguration()
    ) async throws -> [SpeakerTurn] {
        guard sampleRate == 16_000 else {
            throw SpeechPipelineError.unsupportedSampleRate(sampleRate)
        }
        guard !isProcessing else { throw SpeechPipelineError.sessionAlreadyRunning }
        isProcessing = true
        defer { isProcessing = false }
        let manager = try await manager(for: configuration)
        let result = try await manager.value.process(audio: samples)
        return Self.map(result)
    }

    private func manager(
        for configuration: DiarizationConfiguration
    ) async throws -> ManagerHandle {
        if let minimum = configuration.minimumSpeakers,
            let maximum = configuration.maximumSpeakers,
            minimum > maximum
        {
            throw SpeechPipelineError.invalidDiarizationConfiguration
        }
        if configuration.minimumSpeakers == nil,
            configuration.maximumSpeakers == nil,
            let preparedDefaultManager
        {
            return preparedDefaultManager
        }

        var fluidConfig = OfflineDiarizerConfig.default
        fluidConfig.clustering.minSpeakers = configuration.minimumSpeakers
        fluidConfig.clustering.maxSpeakers = configuration.maximumSpeakers
        let manager = OfflineDiarizerManager(config: fluidConfig)
        try await manager.prepareModels()
        return ManagerHandle(value: manager)
    }

    private static func map(_ result: DiarizationResult) -> [SpeakerTurn] {
        result.segments.enumerated().map { index, segment in
            let start = Int64((Double(segment.startTimeSeconds) * 1_000).rounded())
            let end = Int64((Double(segment.endTimeSeconds) * 1_000).rounded())
            return SpeakerTurn(
                id: "\(segment.speakerId)-\(start)-\(end)-\(index)",
                speakerID: segment.speakerId,
                startMilliseconds: start,
                endMilliseconds: end,
                confidence: segment.qualityScore
            )
        }
        .sorted {
            if $0.startMilliseconds != $1.startMilliseconds {
                return $0.startMilliseconds < $1.startMilliseconds
            }
            if $0.endMilliseconds != $1.endMilliseconds {
                return $0.endMilliseconds < $1.endMilliseconds
            }
            return $0.speakerID < $1.speakerID
        }
    }
}
