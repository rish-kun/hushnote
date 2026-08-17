import Foundation
import Testing
@testable import Hushnote

/// The catalog is the only thing standing between a click on "Download" and a
/// multi-gigabyte fetch of the wrong artifact. WhisperKit resolves a
/// `runtimeIdentifier` by globbing `*<identifier>/*` over the repo's file list
/// and throws `modelsUnavailable` when that matches zero or several folders, so
/// an identifier that is not exactly one published folder name is a download
/// that fails minutes in rather than a typo caught here.
@Suite("Speech model catalog integrity")
struct ModelCatalogIntegrityTests {
    @Test("Every runtime identifier names exactly one model folder WhisperKit lists")
    func identifiersResolveToOneKnownVariant() {
        // `medium` is the one entry WhisperKit's own device-support config never
        // lists for any chip, so its existence on the Hub cannot be verified
        // from the checkout. It predates this catalog and is kept, not trusted.
        #expect(SpeechModelCatalog.identifiersWhisperKitDoesNotList() == ["whisperkit.medium"])
    }

    /// `whisperLargeV3Turbo` declared 1.6 GB while its own identifier says the
    /// artifact is 632 MB, so the screen quoted a number two and a half times
    /// the real download.
    @Test("A size baked into an identifier is the size the catalog quotes")
    func declaredSizesMatchTheIdentifiers() {
        for model in SpeechModelCatalog.all {
            guard let stated = SpeechModelCatalog.megabytesInIdentifier(model.runtimeIdentifier) else {
                continue
            }
            let declared = Double(model.approximateDownloadBytes) / 1_000_000
            #expect(
                abs(declared - Double(stated)) <= 1,
                "\(model.id) declares \(declared) MB but its identifier says \(stated) MB"
            )
        }
    }

    @Test("Identifiers and display names are unique and non-empty")
    func identifiersAreDistinct() {
        let models = SpeechModelCatalog.all
        #expect(Set(models.map(\.id)).count == models.count)
        #expect(Set(models.map(\.runtimeIdentifier)).count == models.count)
        #expect(Set(models.map(\.displayName)).count == models.count)
        #expect(models.allSatisfy { !$0.runtimeIdentifier.isEmpty })
        #expect(models.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("Sizes are plausible for a Core ML Whisper build")
    func sizesAreSane() {
        for model in SpeechModelCatalog.all {
            #expect(model.approximateDownloadBytes >= 50_000_000, "\(model.id) is implausibly small")
            #expect(model.approximateDownloadBytes <= 3_000_000_000, "\(model.id) is implausibly large")
            #expect(model.minimumMemoryBytes >= model.approximateDownloadBytes, "\(model.id) claims to need less memory than it downloads")
        }
    }

    /// The screen was showing six models when the Hub publishes far more, and
    /// English-only builds are the cheapest real accuracy win for an
    /// English meeting.
    @Test("The catalog carries the English-only and distilled builds too")
    func catalogCoversThePublishedFamily() {
        let identifiers = Set(SpeechModelCatalog.all.map(\.runtimeIdentifier))

        #expect(identifiers.isSuperset(of: ["tiny", "base", "small", "medium"]))
        #expect(identifiers.isSuperset(of: ["tiny.en", "base.en", "small.en"]))
        #expect(identifiers.contains("distil-large-v3_594MB"))
        #expect(identifiers.contains("distil-large-v3_turbo_600MB"))
        #expect(identifiers.contains("large-v2_949MB"))
        #expect(SpeechModelCatalog.all.contains { !$0.isMultilingual })
    }
}
