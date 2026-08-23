import FluidAudio
import Foundation
import Testing
@testable import Hushnote

/// Preparing the diarizer re-reads and recompiles 21 MB of Core ML models, and
/// it happens immediately after the final transcription pass's memory peak. The
/// engine memoizes a prepared manager; these pin that the memoization is on the
/// path that actually runs.
@Suite("Diarization model preparation")
struct DiarizationPreparationTests {
    @Test("A second diarization reuses the prepared models instead of loading them again")
    func prepareModelsOncePerEngine() async throws {
        let recorder = PreparationRecorder()
        let engine = FluidAudioDiarizationEngine(
            makeManager: { configuration in StubDiarizer(configuration: configuration, recorder: recorder) }
        )

        _ = try await engine.diarize(samples: silence, sampleRate: 16_000)
        _ = try await engine.diarize(audioFileURL: URL(fileURLWithPath: "/tmp/meeting.caf"))

        #expect(await recorder.preparedConfigurations.count == 1)
    }

    @Test("prepare puts the models the first meeting will use in place")
    func prepareSeedsTheSameCache() async throws {
        let recorder = PreparationRecorder()
        let engine = FluidAudioDiarizationEngine(
            makeManager: { configuration in StubDiarizer(configuration: configuration, recorder: recorder) }
        )

        try await engine.prepare()
        _ = try await engine.diarize(samples: silence, sampleRate: 16_000)

        #expect(await recorder.preparedConfigurations.count == 1)
    }

    @Test("A requested speaker range never borrows the models prepared without one")
    func doesNotReuseTheDefaultManagerForABoundedRange() async throws {
        let recorder = PreparationRecorder()
        let engine = FluidAudioDiarizationEngine(
            makeManager: { configuration in StubDiarizer(configuration: configuration, recorder: recorder) }
        )
        let bounded = DiarizationConfiguration(minimumSpeakers: 2, maximumSpeakers: 3)

        _ = try await engine.diarize(samples: silence, sampleRate: 16_000)
        _ = try await engine.diarize(samples: silence, sampleRate: 16_000, configuration: bounded)

        // A manager built without a speaker range clusters differently, so it
        // cannot stand in for one that was asked for two to three speakers.
        #expect(await recorder.preparedConfigurations == [DiarizationConfiguration(), bounded])
    }

    @Test("An impossible speaker range is refused before any model is touched")
    func refusesAnInvertedSpeakerRange() async throws {
        let recorder = PreparationRecorder()
        let engine = FluidAudioDiarizationEngine(
            makeManager: { configuration in StubDiarizer(configuration: configuration, recorder: recorder) }
        )

        await #expect(throws: SpeechPipelineError.invalidDiarizationConfiguration) {
            try await engine.diarize(
                samples: silence,
                sampleRate: 16_000,
                configuration: DiarizationConfiguration(minimumSpeakers: 4, maximumSpeakers: 2)
            )
        }
        #expect(await recorder.preparedConfigurations.isEmpty)
    }

    @Test("Diarization uses the selected model directory")
    func selectedDirectory() async throws {
        let recorder = PreparationRecorder()
        let directory = URL(fileURLWithPath: "/Volumes/Models/Hushnote Models/FluidAudio")
        let engine = FluidAudioDiarizationEngine(
            modelsDirectory: directory,
            makeManager: { configuration in StubDiarizer(configuration: configuration, recorder: recorder) }
        )

        try await engine.prepare()

        #expect(await recorder.preparedDirectories == [directory])
    }
}

// MARK: - Fixtures

private let silence = [Float](repeating: 0, count: 16_000)

private actor PreparationRecorder {
    private(set) var preparedConfigurations: [DiarizationConfiguration] = []
    private(set) var preparedDirectories: [URL?] = []

    func prepared(_ configuration: DiarizationConfiguration, directory: URL?) {
        preparedConfigurations.append(configuration)
        preparedDirectories.append(directory)
    }
}

/// Stands in for FluidAudio's manager so preparation can be counted without a
/// Core ML model on disk.
private struct StubDiarizer: OfflineDiarizing {
    let configuration: DiarizationConfiguration
    let recorder: PreparationRecorder

    func prepareModels(directory: URL?) async throws {
        await recorder.prepared(configuration, directory: directory)
    }

    func process(fileURL: URL) async throws -> DiarizationResult {
        DiarizationResult(segments: [])
    }

    func process(samples: [Float]) async throws -> DiarizationResult {
        DiarizationResult(segments: [])
    }
}
