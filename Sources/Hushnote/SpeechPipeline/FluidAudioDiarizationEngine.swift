import FluidAudio
import Foundation

/// The single FluidAudio entry point the diarizer depends on. Naming it lets
/// tests pin how often models are prepared without reading 21 MB of Core ML
/// weights off disk.
protocol OfflineDiarizing: Sendable {
    func prepareModels(directory: URL?) async throws
    func process(fileURL: URL) async throws -> DiarizationResult
    func process(samples: [Float]) async throws -> DiarizationResult
}

public actor FluidAudioDiarizationEngine: SpeakerDiarizationEngine {
    /// FluidAudio's manager is internally immutable after model preparation but
    /// does not yet declare Sendable. This wrapper is kept actor-confined, and
    /// `isProcessing` prevents reentrant use while its async pipeline runs.
    private struct ManagerHandle: OfflineDiarizing, @unchecked Sendable {
        let value: OfflineDiarizerManager

        func prepareModels(directory: URL?) async throws {
            try await value.prepareModels(directory: directory)
        }

        func process(fileURL: URL) async throws -> DiarizationResult {
            try await value.process(fileURL)
        }

        func process(samples: [Float]) async throws -> DiarizationResult {
            try await value.process(audio: samples)
        }
    }

    public nonisolated let descriptor = SpeechEngineDescriptor(
        id: "fluidaudio.offline-diarizer",
        displayName: "FluidAudio Speaker Diarization",
        streamingKind: .utterance,
        supportsWordTimestamps: false,
        supportedAccelerators: [.cpu, .gpu, .neuralEngine]
    )

    private let makeManager: @Sendable (DiarizationConfiguration) -> any OfflineDiarizing
    private let modelsDirectory: URL?
    private var preparedDefaultManager: (any OfflineDiarizing)?
    private var isProcessing = false

    public init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory
        makeManager = { configuration in
            var config = OfflineDiarizerConfig.default
            config.clustering.minSpeakers = configuration.minimumSpeakers
            config.clustering.maxSpeakers = configuration.maximumSpeakers
            return ManagerHandle(value: OfflineDiarizerManager(config: config))
        }
    }

    /// Test seam. Production code builds FluidAudio's own manager.
    init(
        modelsDirectory: URL? = nil,
        makeManager: @escaping @Sendable (DiarizationConfiguration) -> any OfflineDiarizing
    ) {
        self.modelsDirectory = modelsDirectory
        self.makeManager = makeManager
    }

    public func prepare() async throws {
        _ = try await manager(for: DiarizationConfiguration())
    }

    public func diarize(
        audioFileURL: URL,
        configuration: DiarizationConfiguration = DiarizationConfiguration()
    ) async throws -> [SpeakerTurn] {
        guard !isProcessing else { throw SpeechPipelineError.sessionAlreadyRunning }
        isProcessing = true
        defer { isProcessing = false }
        let manager = try await manager(for: configuration)
        let result = try await manager.process(fileURL: audioFileURL)
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
        let result = try await manager.process(samples: samples)
        return Self.map(result)
    }

    private func manager(
        for configuration: DiarizationConfiguration
    ) async throws -> any OfflineDiarizing {
        if let minimum = configuration.minimumSpeakers,
            let maximum = configuration.maximumSpeakers,
            minimum > maximum
        {
            throw SpeechPipelineError.invalidDiarizationConfiguration
        }
        // Only the default configuration is memoized: a manager prepared with a
        // speaker-count range clusters differently and cannot answer for one
        // without.
        guard configuration.minimumSpeakers == nil, configuration.maximumSpeakers == nil else {
            let manager = makeManager(configuration)
            try await manager.prepareModels(directory: modelsDirectory)
            return manager
        }
        if let preparedDefaultManager { return preparedDefaultManager }
        // Preparing re-reads and recompiles 21 MB of Core ML models, and it runs
        // immediately after the final transcription pass's memory peak, so every
        // meeting after the first has to be able to skip it.
        let manager = makeManager(configuration)
        try await manager.prepareModels(directory: modelsDirectory)
        preparedDefaultManager = manager
        return manager
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
