import Foundation
import Testing
import WhisperKit
@testable import Hushnote

@Suite("Model storage")
struct ModelStorageTests {
    @Test("A custom parent keeps dependency caches inside one managed folder")
    func customPaths() {
        let paths = ModelStoragePaths(parentDirectory: URL(fileURLWithPath: "/Volumes/Models/../Models"))

        #expect(paths.parentDirectory?.path == "/Volumes/Models")
        #expect(paths.whisperDownloadBase?.path == "/Volumes/Models/Hushnote Models/WhisperKit")
        #expect(paths.diarizationModelsDirectory?.path == "/Volumes/Models/Hushnote Models/FluidAudio")
    }

    @Test("Storage changes queue while recording, downloading, or migrating")
    func changeQueuePolicy() {
        #expect(ModelStorageChangePolicy.canApply(
            recordingIsBusy: false,
            activeDownloadCount: 0,
            isMigrating: false
        ))
        #expect(!ModelStorageChangePolicy.canApply(
            recordingIsBusy: true,
            activeDownloadCount: 0,
            isMigrating: false
        ))
        #expect(!ModelStorageChangePolicy.canApply(
            recordingIsBusy: false,
            activeDownloadCount: 1,
            isMigrating: false
        ))
        #expect(!ModelStorageChangePolicy.canApply(
            recordingIsBusy: false,
            activeDownloadCount: 0,
            isMigrating: true
        ))
    }

    @Test("Live transcription uses the selected cache and explicit installs stay offline")
    func liveModelConfigurations() {
        let base = URL(fileURLWithPath: "/Volumes/Models/Hushnote Models/WhisperKit")
        let downloaded = base.appending(path: "downloaded-model", directoryHint: .isDirectory)
        let downloading = WhisperKitTranscriptionEngine.modelConfiguration(
            for: SpeechModelCatalog.whisperSmall,
            modelFolder: nil,
            downloadBase: base
        )
        let installed = WhisperKitTranscriptionEngine.modelConfiguration(
            for: SpeechModelCatalog.whisperSmall,
            modelFolder: downloaded,
            downloadBase: base
        )

        #expect(downloading.downloadBase == base)
        #expect(downloading.download)
        #expect(installed.modelFolder == downloaded.path)
        #expect(installed.download == false)
    }

    @Test("Discovery ignores partial downloads and reports a complete catalog model")
    func installedDiscovery() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "hushnote-model-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = ModelStoragePaths(parentDirectory: parent)
        let repository = try #require(paths.whisperDownloadBase)
            .appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
        let complete = repository.appending(
            path: "openai_whisper-\(SpeechModelCatalog.whisperSmall.runtimeIdentifier)",
            directoryHint: .isDirectory
        )
        let partial = repository.appending(
            path: "openai_whisper-\(SpeechModelCatalog.whisperTiny.runtimeIdentifier)",
            directoryHint: .isDirectory
        )
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: complete.appending(path: "\(component).mlmodelc", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: partial.appending(path: "AudioEncoder.mlmodelc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let installed = InstalledSpeechModelDiscovery.installedModels(at: paths)

        #expect(
            installed[SpeechModelCatalog.whisperSmall.id]?.resolvingSymlinksInPath()
                == complete.resolvingSymlinksInPath()
        )
        #expect(installed[SpeechModelCatalog.whisperTiny.id] == nil)
    }

    @Test("Migration and removal touch only recognized model folders")
    func safeOperations() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "hushnote-model-operations-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = ModelStoragePaths(parentDirectory: scratch.appending(path: "source"))
        let destination = ModelStoragePaths(parentDirectory: scratch.appending(path: "destination"))
        let sourceRepository = InstalledSpeechModelDiscovery.repositoryURL(at: source)
        let model = SpeechModelCatalog.whisperSmall
        let sourceModel = sourceRepository.appending(
            path: "openai_whisper-\(model.runtimeIdentifier)",
            directoryHint: .isDirectory
        )
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: sourceModel.appending(path: "\(component).mlmodelc", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        let unrelatedWhisper = sourceRepository.appending(path: "not-a-hushnote-model")
        try Data("keep".utf8).write(to: unrelatedWhisper, options: .atomic)

        let sourceFluid = source.effectiveDiarizationModelsDirectory
        let diarization = sourceFluid.appending(path: "speaker-diarization", directoryHint: .isDirectory)
        for component in ["Segmentation", "Embedding", "PldaRho", "FBank"] {
            try FileManager.default.createDirectory(
                at: diarization.appending(path: "\(component).mlmodelc", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        try Data("parameters".utf8).write(
            to: diarization.appending(path: "plda-parameters.json"),
            options: .atomic
        )
        let unrelatedFluid = sourceFluid.appending(path: "unrelated-asr", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unrelatedFluid, withIntermediateDirectories: true)

        let result = try await ModelStorageOperations().migrate(from: source, to: destination)

        #expect(result.copiedSpeechModelIDs == [model.id])
        #expect(result.copiedDiarization)
        #expect(InstalledSpeechModelDiscovery.installedModels(at: destination)[model.id] != nil)
        #expect(FileManager.default.fileExists(
            atPath: destination.effectiveDiarizationModelsDirectory
                .appending(path: "speaker-diarization/plda-parameters.json").path
        ))
        #expect(FileManager.default.fileExists(atPath: unrelatedWhisper.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFluid.path))

        let destinationUnrelated = InstalledSpeechModelDiscovery.repositoryURL(at: destination)
            .appending(path: "keep-me")
        try Data("keep".utf8).write(to: destinationUnrelated, options: .atomic)
        try await ModelStorageOperations().removeSpeechModel(model, from: destination)
        try await ModelStorageOperations().removeDiarizationModels(from: destination)

        #expect(FileManager.default.fileExists(atPath: destinationUnrelated.path))
        #expect(FileManager.default.fileExists(atPath: sourceModel.path))
        #expect(FileManager.default.fileExists(atPath: diarization.path))
    }
}
