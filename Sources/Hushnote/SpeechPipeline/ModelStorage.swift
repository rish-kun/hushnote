import FluidAudio
import Foundation

/// Resolves every downloaded model cache from one user-selected parent folder.
///
/// A nil parent deliberately preserves each dependency's existing default. A
/// custom parent gets one app-owned directory so choosing (for example) an
/// external drive never scatters implementation-specific folders at its root.
struct ModelStoragePaths: Equatable, Sendable {
    static let managedDirectoryName = "Hushnote Models"

    var parentDirectory: URL?

    init(parentDirectory: URL? = nil) {
        self.parentDirectory = parentDirectory?.standardizedFileURL
    }

    var managedDirectory: URL? {
        parentDirectory?.appending(path: Self.managedDirectoryName, directoryHint: .isDirectory)
    }

    /// Nil tells WhisperKit to keep using its own backwards-compatible default.
    var whisperDownloadBase: URL? {
        managedDirectory?.appending(path: "WhisperKit", directoryHint: .isDirectory)
    }

    /// Nil tells FluidAudio to keep using its own Application Support cache.
    var diarizationModelsDirectory: URL? {
        managedDirectory?.appending(path: "FluidAudio", directoryHint: .isDirectory)
    }

    var effectiveWhisperDownloadBase: URL {
        whisperDownloadBase ?? Self.defaultWhisperDownloadBase
    }

    var effectiveDiarizationModelsDirectory: URL {
        diarizationModelsDirectory ?? OfflineDiarizerModels.defaultModelsDirectory()
    }

    static var defaultWhisperDownloadBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface", directoryHint: .isDirectory)
    }
}

/// Read-only cache inspection. A model counts as installed only when all three
/// Core ML components WhisperKit requires are present, rather than merely when
/// a partially downloaded folder happens to have the expected name.
enum InstalledSpeechModelDiscovery {
    static func installedModels(
        at location: ModelStoragePaths,
        fileManager: FileManager = .default
    ) -> [String: URL] {
        let repository = repositoryURL(at: location)
        guard let children = try? fileManager.contentsOfDirectory(
            at: repository,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        return Dictionary(uniqueKeysWithValues: SpeechModelCatalog.all.compactMap { model in
            let matches = children.filter {
                $0.lastPathComponent.hasSuffix(model.runtimeIdentifier) && isCompleteModel(at: $0, fileManager: fileManager)
            }
            guard matches.count == 1, let folder = matches.first else { return nil }
            return (model.id, folder)
        })
    }

    static func repositoryURL(at location: ModelStoragePaths) -> URL {
        location.effectiveWhisperDownloadBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
    }

    static func isCompleteModel(at folder: URL, fileManager: FileManager) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { component in
            ["mlmodelc", "mlpackage"].contains { extensionName in
                fileManager.fileExists(
                    atPath: folder.appending(path: "\(component).\(extensionName)").path
                )
            }
        }
    }
}

enum ModelStorageOperationError: Error, LocalizedError {
    case sameLocation
    case destinationAlreadyContainsIncompleteItem(String)
    case verificationFailed(String)
    case unrecognizedModel(String)

    var errorDescription: String? {
        switch self {
        case .sameLocation: "The old and new model locations are the same."
        case .destinationAlreadyContainsIncompleteItem(let name):
            "The destination already contains an incomplete model folder named \(name)."
        case .verificationFailed(let name): "The copied model \(name) could not be verified."
        case .unrecognizedModel(let id): "No complete installed model matches \(id)."
        }
    }
}

struct ModelStorageMigrationProgress: Equatable, Sendable {
    var completedItems: Int
    var totalItems: Int
    var currentItem: String?
}

struct ModelStorageMigrationResult: Equatable, Sendable {
    var copiedSpeechModelIDs: [String]
    var copiedDiarization: Bool
}

enum ModelStorageChangePolicy {
    static func canApply(
        recordingIsBusy: Bool,
        activeDownloadCount: Int,
        isMigrating: Bool
    ) -> Bool {
        !recordingIsBusy && activeDownloadCount == 0 && !isMigrating
    }
}

/// Filesystem operations are intentionally narrower than the cache roots.
/// Whisper folders must resolve to one catalog entry and FluidAudio operations
/// touch only a validated speaker-diarization repo. Other apps may share both
/// dependencies' default caches, so removing either root is never allowed.
struct ModelStorageOperations: Sendable {
    func prepare(_ location: ModelStoragePaths) async throws {
        guard let managed = location.managedDirectory else { return }
        try await Task.detached(priority: .utility) {
            let manager = FileManager()
            try manager.createDirectory(at: managed, withIntermediateDirectories: true)
            if let whisper = location.whisperDownloadBase {
                try manager.createDirectory(at: whisper, withIntermediateDirectories: true)
            }
            if let diarization = location.diarizationModelsDirectory {
                try manager.createDirectory(at: diarization, withIntermediateDirectories: true)
            }
        }.value
    }

    func migrate(
        from source: ModelStoragePaths,
        to destination: ModelStoragePaths,
        progress: @escaping @Sendable (ModelStorageMigrationProgress) -> Void = { _ in }
    ) async throws -> ModelStorageMigrationResult {
        try await Task.detached(priority: .utility) {
            try Self.copyRecognizedModels(from: source, to: destination, progress: progress)
        }.value
    }

    func removeSpeechModel(_ model: SpeechModel, from location: ModelStoragePaths) async throws {
        try await Task.detached(priority: .utility) {
            let manager = FileManager()
            guard let folder = InstalledSpeechModelDiscovery.installedModels(
                at: location,
                fileManager: manager
            )[model.id] else {
                throw ModelStorageOperationError.unrecognizedModel(model.id)
            }
            let repository = InstalledSpeechModelDiscovery.repositoryURL(at: location).standardizedFileURL
            guard folder.deletingLastPathComponent().standardizedFileURL == repository else {
                throw ModelStorageOperationError.unrecognizedModel(model.id)
            }
            try manager.removeItem(at: folder)

            // Metadata mirrors the model's relative folder. It is safe to remove
            // only that exact child, never `.cache` or the repository itself.
            let metadata = repository
                .appending(path: ".cache/huggingface/download", directoryHint: .isDirectory)
                .appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
            if manager.fileExists(atPath: metadata.path) { try manager.removeItem(at: metadata) }
        }.value
    }

    func removeDiarizationModels(from location: ModelStoragePaths) async throws {
        try await Task.detached(priority: .utility) {
            let manager = FileManager()
            guard let folder = Self.installedDiarizationFolder(at: location, fileManager: manager) else {
                throw ModelStorageOperationError.unrecognizedModel("speaker-diarization")
            }
            let root = location.effectiveDiarizationModelsDirectory.standardizedFileURL
            guard folder.deletingLastPathComponent().standardizedFileURL == root else {
                throw ModelStorageOperationError.unrecognizedModel("speaker-diarization")
            }
            try manager.removeItem(at: folder)
        }.value
    }

    private static func copyRecognizedModels(
        from source: ModelStoragePaths,
        to destination: ModelStoragePaths,
        progress: @escaping @Sendable (ModelStorageMigrationProgress) -> Void
    ) throws -> ModelStorageMigrationResult {
        guard source != destination else { throw ModelStorageOperationError.sameLocation }
        let manager = FileManager()
        let speech = InstalledSpeechModelDiscovery.installedModels(at: source, fileManager: manager)
        let diarization = installedDiarizationFolder(at: source, fileManager: manager)
        let total = speech.count + (diarization == nil ? 0 : 1)
        var completed = 0
        var copiedIDs: [String] = []

        let destinationRepository = InstalledSpeechModelDiscovery.repositoryURL(at: destination)
        for model in SpeechModelCatalog.all {
            guard let sourceFolder = speech[model.id] else { continue }
            progress(.init(completedItems: completed, totalItems: total, currentItem: model.displayName))
            let target = destinationRepository.appending(path: sourceFolder.lastPathComponent, directoryHint: .isDirectory)
            try stagedCopy(sourceFolder, to: target, fileManager: manager) { staged in
                InstalledSpeechModelDiscovery.isCompleteModel(at: staged, fileManager: manager)
            }
            try copyWhisperMetadata(
                folderName: sourceFolder.lastPathComponent,
                source: source,
                destination: destination,
                fileManager: manager
            )
            copiedIDs.append(model.id)
            completed += 1
            progress(.init(completedItems: completed, totalItems: total, currentItem: nil))
        }

        var copiedDiarization = false
        if let sourceFolder = diarization {
            progress(.init(completedItems: completed, totalItems: total, currentItem: "Speaker diarization"))
            let target = destination.effectiveDiarizationModelsDirectory
                .appending(path: sourceFolder.lastPathComponent, directoryHint: .isDirectory)
            try stagedCopy(sourceFolder, to: target, fileManager: manager) {
                isCompleteDiarizationFolder($0, fileManager: manager)
            }
            copiedDiarization = true
            completed += 1
            progress(.init(completedItems: completed, totalItems: total, currentItem: nil))
        }
        return ModelStorageMigrationResult(
            copiedSpeechModelIDs: copiedIDs,
            copiedDiarization: copiedDiarization
        )
    }

    private static func stagedCopy(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager,
        verify: (URL) -> Bool
    ) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard verify(destination) else {
                throw ModelStorageOperationError.destinationAlreadyContainsIncompleteItem(destination.lastPathComponent)
            }
            return
        }
        let staged = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).hushnote-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let stagePrefix = ".\(destination.lastPathComponent).hushnote-staging-"
        if let siblings = try? fileManager.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) {
            for sibling in siblings where sibling.lastPathComponent.hasPrefix(stagePrefix) {
                try? fileManager.removeItem(at: sibling)
            }
        }
        do {
            try fileManager.copyItem(at: source, to: staged)
            guard verify(staged), try directoryManifest(at: source, fileManager: fileManager)
                == directoryManifest(at: staged, fileManager: fileManager) else {
                throw ModelStorageOperationError.verificationFailed(destination.lastPathComponent)
            }
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            if fileManager.fileExists(atPath: staged.path) { try? fileManager.removeItem(at: staged) }
            throw error
        }
    }

    /// Confirms every relative entry and regular-file byte length survived the
    /// copy before the staged directory is atomically promoted. Core ML bundles
    /// contain thousands of files, so this catches interrupted/truncated copies
    /// without loading model weights into memory.
    private static func directoryManifest(
        at root: URL,
        fileManager: FileManager
    ) throws -> [String: Int64] {
        let paths = try fileManager.subpathsOfDirectory(atPath: root.path)
        return try Dictionary(uniqueKeysWithValues: paths.map { relativePath in
            let attributes = try fileManager.attributesOfItem(
                atPath: root.appending(path: relativePath).path
            )
            let type = attributes[.type] as? FileAttributeType
            let marker: Int64 = if type == .typeRegular {
                (attributes[.size] as? NSNumber)?.int64Value ?? 0
            } else if type == .typeDirectory {
                -1
            } else {
                -2
            }
            return (relativePath, marker)
        })
    }

    private static func copyWhisperMetadata(
        folderName: String,
        source: ModelStoragePaths,
        destination: ModelStoragePaths,
        fileManager: FileManager
    ) throws {
        let suffix = ".cache/huggingface/download"
        let sourceMetadata = InstalledSpeechModelDiscovery.repositoryURL(at: source)
            .appending(path: suffix, directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: sourceMetadata.path) else { return }
        let destinationMetadata = InstalledSpeechModelDiscovery.repositoryURL(at: destination)
            .appending(path: suffix, directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        try stagedCopy(sourceMetadata, to: destinationMetadata, fileManager: fileManager) { _ in true }
    }

    private static let diarizationFolderNames = [
        "speaker-diarization",
        "speaker-diarization-coreml",
        "speaker-diarization-offline",
    ]

    static func installedDiarizationFolder(
        at location: ModelStoragePaths,
        fileManager: FileManager
    ) -> URL? {
        let root = location.effectiveDiarizationModelsDirectory
        return diarizationFolderNames
            .map { root.appending(path: $0, directoryHint: .isDirectory) }
            .first { isCompleteDiarizationFolder($0, fileManager: fileManager) }
    }

    private static func isCompleteDiarizationFolder(_ folder: URL, fileManager: FileManager) -> Bool {
        let models = ["Segmentation", "Embedding", "PldaRho", "FBank"]
        return models.allSatisfy {
            fileManager.fileExists(atPath: folder.appending(path: "\($0).mlmodelc").path)
        } && fileManager.fileExists(atPath: folder.appending(path: "plda-parameters.json").path)
    }
}
