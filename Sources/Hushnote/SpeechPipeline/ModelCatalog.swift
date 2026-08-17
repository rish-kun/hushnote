import Foundation
import WhisperKit

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
    // Every `runtimeIdentifier` below is a suffix of exactly one entry in
    // WhisperKit's own `Constants.knownModels`, which is what
    // `identifiersWhisperKitDoesNotList()` asserts. Nothing is added here that
    // cannot be checked against the checkout: a `runtimeIdentifier` the Hub does
    // not publish is a download that fails minutes in.
    //
    // Sizes: the compressed builds state their own artifact size in the folder
    // name (`..._632MB`) and are quoted from it. The uncompressed builds carry
    // no such figure and are quoted at float16 weight size — two bytes per
    // parameter over OpenAI's published parameter counts.

    public static let whisperTiny = SpeechModel(
        id: "whisperkit.tiny",
        displayName: "Whisper Tiny",
        provider: .whisperKit,
        runtimeIdentifier: "tiny",
        tier: .fast,
        isMultilingual: true,
        // 39M parameters at float16.
        approximateDownloadBytes: 78_000_000,
        minimumMemoryBytes: 1_000_000_000
    )

    public static let whisperTinyEnglish = SpeechModel(
        id: "whisperkit.tiny.en",
        displayName: "Whisper Tiny (English)",
        provider: .whisperKit,
        runtimeIdentifier: "tiny.en",
        tier: .fast,
        isMultilingual: false,
        approximateDownloadBytes: 78_000_000,
        minimumMemoryBytes: 1_000_000_000
    )

    public static let whisperBase = SpeechModel(
        id: "whisperkit.base",
        displayName: "Whisper Base",
        provider: .whisperKit,
        runtimeIdentifier: "base",
        tier: .fast,
        isMultilingual: true,
        // 74M parameters at float16.
        approximateDownloadBytes: 148_000_000,
        minimumMemoryBytes: 2_000_000_000
    )

    public static let whisperBaseEnglish = SpeechModel(
        id: "whisperkit.base.en",
        displayName: "Whisper Base (English)",
        provider: .whisperKit,
        runtimeIdentifier: "base.en",
        tier: .fast,
        isMultilingual: false,
        approximateDownloadBytes: 148_000_000,
        minimumMemoryBytes: 2_000_000_000
    )

    public static let whisperSmall = SpeechModel(
        id: "whisperkit.small",
        displayName: "Whisper Small",
        provider: .whisperKit,
        runtimeIdentifier: "small",
        tier: .balanced,
        isMultilingual: true,
        // 244M parameters at float16.
        approximateDownloadBytes: 488_000_000,
        minimumMemoryBytes: 4_000_000_000
    )

    public static let whisperSmallEnglish = SpeechModel(
        id: "whisperkit.small.en",
        displayName: "Whisper Small (English)",
        provider: .whisperKit,
        runtimeIdentifier: "small.en",
        tier: .balanced,
        isMultilingual: false,
        approximateDownloadBytes: 488_000_000,
        minimumMemoryBytes: 4_000_000_000
    )

    /// The one entry WhisperKit's device-support config never lists for any
    /// chip, so its presence on the Hub cannot be confirmed from the checkout.
    /// It predates this catalog and is kept rather than trusted; a download that
    /// finds nothing surfaces as a failed row rather than a silent substitution.
    public static let whisperMedium = SpeechModel(
        id: "whisperkit.medium",
        displayName: "Whisper Medium",
        provider: .whisperKit,
        runtimeIdentifier: "medium",
        tier: .balanced,
        isMultilingual: true,
        // 769M parameters at float16.
        approximateDownloadBytes: 1_538_000_000,
        minimumMemoryBytes: 6_000_000_000
    )

    /// Distil-Whisper is a distilled English-only decoder: large-v3 accuracy on
    /// English at a fraction of the decode cost. It cannot transcribe anything
    /// else, which is why it is not the recommendation.
    public static let distilLargeV3 = SpeechModel(
        id: "whisperkit.distil-large-v3",
        displayName: "Distil-Whisper Large v3 (English)",
        provider: .whisperKit,
        runtimeIdentifier: "distil-large-v3_594MB",
        tier: .balanced,
        isMultilingual: false,
        approximateDownloadBytes: 594_000_000,
        minimumMemoryBytes: 6_000_000_000
    )

    public static let distilLargeV3Turbo = SpeechModel(
        id: "whisperkit.distil-large-v3-turbo",
        displayName: "Distil-Whisper Large v3 Turbo (English)",
        provider: .whisperKit,
        runtimeIdentifier: "distil-large-v3_turbo_600MB",
        tier: .balanced,
        isMultilingual: false,
        approximateDownloadBytes: 600_000_000,
        minimumMemoryBytes: 6_000_000_000
    )

    /// Superseded by Large v3. Kept because a machine that already has it should
    /// be able to see and keep using it.
    public static let whisperLargeV2 = SpeechModel(
        id: "whisperkit.large-v2-949mb",
        displayName: "Whisper Large v2",
        provider: .whisperKit,
        runtimeIdentifier: "large-v2_949MB",
        tier: .accurate,
        isMultilingual: true,
        approximateDownloadBytes: 949_000_000,
        minimumMemoryBytes: 8_000_000_000
    )

    /// The original Large v3 compression, before the 2024-09-30 rebuild.
    public static let whisperLargeV3Legacy = SpeechModel(
        id: "whisperkit.large-v3-947mb",
        displayName: "Whisper Large v3 (2023 build)",
        provider: .whisperKit,
        runtimeIdentifier: "large-v3_947MB",
        tier: .accurate,
        isMultilingual: true,
        approximateDownloadBytes: 947_000_000,
        minimumMemoryBytes: 8_000_000_000
    )

    public static let whisperLargeV3TurboLegacy = SpeechModel(
        id: "whisperkit.large-v3-turbo-954mb",
        displayName: "Whisper Large v3 Turbo (2023 build)",
        provider: .whisperKit,
        runtimeIdentifier: "large-v3_turbo_954MB",
        tier: .accurate,
        isMultilingual: true,
        approximateDownloadBytes: 954_000_000,
        minimumMemoryBytes: 8_000_000_000
    )

    /// Declared 1.6 GB against an artifact its own identifier calls 632 MB, so
    /// the screen quoted two and a half times the real download.
    public static let whisperLargeV3Turbo = SpeechModel(
        id: "whisperkit.large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        provider: .whisperKit,
        runtimeIdentifier: "large-v3-v20240930_turbo_632MB",
        tier: .accurate,
        isMultilingual: true,
        approximateDownloadBytes: 632_000_000,
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

    /// Ordered smallest first, which is also fastest first, so the screen reads
    /// as a ladder rather than a bag.
    public static let all: [SpeechModel] = [
        whisperTiny,
        whisperTinyEnglish,
        whisperBase,
        whisperBaseEnglish,
        whisperSmall,
        whisperSmallEnglish,
        distilLargeV3,
        distilLargeV3Turbo,
        whisperLargeV3,
        whisperLargeV3Turbo,
        whisperLargeV3Legacy,
        whisperLargeV3TurboLegacy,
        whisperLargeV2,
        whisperMedium,
    ]

    public static let recommended = whisperLargeV3Turbo

    /// Builds the Hub still serves but that a newer artifact supersedes. Shown,
    /// badged, and never recommended.
    public static let legacy: Set<String> = [
        whisperLargeV2.id,
        whisperLargeV3Legacy.id,
        whisperLargeV3TurboLegacy.id,
        whisperMedium.id,
    ]

    public static func model(id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }

    /// Catalog entries whose `runtimeIdentifier` is not exactly one of the model
    /// folders WhisperKit itself lists.
    ///
    /// `WhisperKit.download(variant:)` globs `*<identifier>/*` over the repo's
    /// file listing and throws `modelsUnavailable` when that matches zero or
    /// more than one folder. `WhisperKit.knownModels` — the flattened
    /// device-support config shipped in the checkout — is the only listing
    /// available without a network call, so it is what a new entry is checked
    /// against before it is added.
    public static func identifiersWhisperKitDoesNotList() -> [String] {
        all.filter { model in
            Constants.knownModels.count { $0.hasSuffix(model.runtimeIdentifier) } != 1
        }
        .map(\.id)
    }

    /// The size Argmax baked into a compressed variant's folder name, in
    /// megabytes: `large-v3-v20240930_turbo_632MB` is a 632 MB artifact. The
    /// uncompressed variants carry no such figure and return nil.
    public static func megabytesInIdentifier(_ identifier: String) -> Int? {
        guard identifier.hasSuffix("MB") else { return nil }
        let digits = identifier
            .dropLast(2)
            .reversed()
            .prefix { $0.isNumber }
            .reversed()
        return digits.isEmpty ? nil : Int(String(digits))
    }
}
