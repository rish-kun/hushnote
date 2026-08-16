import Foundation

public enum SpeechModelProvider: String, Codable, Sendable {
    case whisperKit
}

public enum SpeechModelTier: String, Codable, CaseIterable, Sendable {
    case fast
    case balanced
    case accurate
}

public struct SpeechModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var provider: SpeechModelProvider
    public var runtimeIdentifier: String
    public var tier: SpeechModelTier
    public var isMultilingual: Bool
    public var approximateDownloadBytes: Int64
    public var minimumMemoryBytes: Int64
    public var licenseName: String

    public init(
        id: String,
        displayName: String,
        provider: SpeechModelProvider,
        runtimeIdentifier: String,
        tier: SpeechModelTier,
        isMultilingual: Bool,
        approximateDownloadBytes: Int64,
        minimumMemoryBytes: Int64,
        licenseName: String = "MIT"
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.runtimeIdentifier = runtimeIdentifier
        self.tier = tier
        self.isMultilingual = isMultilingual
        self.approximateDownloadBytes = approximateDownloadBytes
        self.minimumMemoryBytes = minimumMemoryBytes
        self.licenseName = licenseName
    }
}

public enum SpeechModelCatalog {
    public static let whisperTiny = SpeechModel(
        id: "whisperkit.tiny",
        displayName: "Whisper Tiny",
        provider: .whisperKit,
        runtimeIdentifier: "tiny",
        tier: .fast,
        isMultilingual: true,
        approximateDownloadBytes: 75_000_000,
        minimumMemoryBytes: 1_000_000_000
    )

    public static let whisperBase = SpeechModel(
        id: "whisperkit.base",
        displayName: "Whisper Base",
        provider: .whisperKit,
        runtimeIdentifier: "base",
        tier: .fast,
        isMultilingual: true,
        approximateDownloadBytes: 150_000_000,
        minimumMemoryBytes: 2_000_000_000
    )

    public static let whisperSmall = SpeechModel(
        id: "whisperkit.small",
        displayName: "Whisper Small",
        provider: .whisperKit,
        runtimeIdentifier: "small",
        tier: .balanced,
        isMultilingual: true,
        approximateDownloadBytes: 500_000_000,
        minimumMemoryBytes: 4_000_000_000
    )

    public static let whisperMedium = SpeechModel(
        id: "whisperkit.medium",
        displayName: "Whisper Medium",
        provider: .whisperKit,
        runtimeIdentifier: "medium",
        tier: .balanced,
        isMultilingual: true,
        approximateDownloadBytes: 1_500_000_000,
        minimumMemoryBytes: 6_000_000_000
    )

    public static let whisperLargeV3Turbo = SpeechModel(
        id: "whisperkit.large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        provider: .whisperKit,
        runtimeIdentifier: "large-v3-v20240930_turbo_632MB",
        tier: .accurate,
        isMultilingual: true,
        approximateDownloadBytes: 1_600_000_000,
        minimumMemoryBytes: 8_000_000_000
    )

    /// Argmax's recommended compressed multilingual model for maximum accuracy.
    public static let whisperLargeV3 = SpeechModel(
        id: "whisperkit.large-v3-626mb",
        displayName: "Whisper Large v3",
        provider: .whisperKit,
        runtimeIdentifier: "large-v3-v20240930_626MB",
        tier: .accurate,
        isMultilingual: true,
        approximateDownloadBytes: 626_000_000,
        minimumMemoryBytes: 8_000_000_000
    )

    public static let all: [SpeechModel] = [
        whisperTiny,
        whisperBase,
        whisperSmall,
        whisperMedium,
        whisperLargeV3Turbo,
        whisperLargeV3,
    ]

    public static let recommended = whisperLargeV3Turbo

    public static func model(id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }
}
