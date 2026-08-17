import Foundation
import Testing
@testable import Hushnote

/// The models screen had no way of saying which model a meeting would actually
/// use, no way of choosing one, and a Download button that flipped to a
/// spinner and told the user nothing else for the length of a multi-hundred-
/// megabyte fetch. Everything the screen decides is resolved here so it can be
/// held to a shape without a view.
@Suite("Model screen policy")
struct ModelDownloadScreenPolicyTests {
    @Test("Exactly the models a meeting will use are marked active")
    func activeFollowsTheDraft() {
        let rows = ModelListPolicy.rows(availability: [:], draft: MeetingDraft())
        let active = rows.filter { $0.badges.contains(.active) }

        #expect(active.count == 2)
        #expect(active.contains { $0.model.id == SpeechModelCatalog.whisperLargeV3Turbo.id })
        #expect(active.contains { $0.model.id == SpeechModelCatalog.whisperLargeV3.id })
    }

    /// One model doing both jobs is one active row, not two half-labelled ones.
    @Test("A model set as the default holds both roles on one row")
    func oneDefaultCollapsesBothRoles() {
        var draft = MeetingDraft()
        draft.liveModel = SpeechModelCatalog.whisperSmall.id
        draft.finalModel = SpeechModelCatalog.whisperSmall.id
        let rows = ModelListPolicy.rows(availability: [:], draft: draft)
        let active = rows.filter { $0.badges.contains(.active) }

        #expect(active.count == 1)
        #expect(active.first?.model.id == SpeechModelCatalog.whisperSmall.id)
        #expect(active.first?.role == .both)
    }

    @Test("The badges say what is recommended, what is superseded, and what cannot hear another language")
    func badgesDescribeTheCatalog() {
        let rows = ModelListPolicy.rows(availability: [:], draft: MeetingDraft())
        func badges(_ model: SpeechModel) -> [ModelBadge] {
            rows.first { $0.model.id == model.id }?.badges ?? []
        }

        #expect(badges(SpeechModelCatalog.whisperLargeV2).contains(.legacy))
        #expect(badges(SpeechModelCatalog.distilLargeV3).contains(.englishOnly))
        #expect(badges(SpeechModelCatalog.whisperTinyEnglish).contains(.englishOnly))
        #expect(badges(SpeechModelCatalog.whisperLargeV3).contains(.legacy) == false)
        // The recommendation is already in use out of the box, and a row does
        // not need to be told twice.
        #expect(badges(SpeechModelCatalog.whisperSmall).contains(.recommended) == false)
    }

    @Test("The recommendation is badged when it is not already the active model")
    func recommendationIsBadgedWhenItIsNotActive() {
        var draft = MeetingDraft()
        draft.liveModel = SpeechModelCatalog.whisperSmall.id
        draft.finalModel = SpeechModelCatalog.whisperSmall.id
        let rows = ModelListPolicy.rows(availability: [:], draft: draft)
        let recommended = rows.first { $0.model.id == SpeechModelCatalog.recommended.id }

        #expect(recommended?.badges.contains(.recommended) == true)
    }

    @Test("What is on disk and what is not are two lists")
    func partitionSplitsOnWhatIsInstalled() {
        let availability: [String: ModelAvailability] = [
            SpeechModelCatalog.whisperTiny.id: .ready,
            SpeechModelCatalog.whisperSmall.id: .ready,
            SpeechModelCatalog.whisperBase.id: .downloading(.starting),
            SpeechModelCatalog.whisperMedium.id: .failed("no network"),
        ]
        let split = ModelListPolicy.partition(
            ModelListPolicy.rows(availability: availability, draft: MeetingDraft())
        )

        #expect(split.downloaded.map(\.model.id) == [
            SpeechModelCatalog.whisperTiny.id,
            SpeechModelCatalog.whisperSmall.id,
        ])
        // A download in flight has not landed, and a failed one never did.
        #expect(split.available.contains { $0.model.id == SpeechModelCatalog.whisperBase.id })
        #expect(split.available.contains { $0.model.id == SpeechModelCatalog.whisperMedium.id })
        #expect(split.downloaded.count + split.available.count == SpeechModelCatalog.all.count)
    }

    @Test("The catalog order survives the split")
    func partitionPreservesCatalogOrder() {
        let availability = Dictionary(
            uniqueKeysWithValues: SpeechModelCatalog.all.map { ($0.id, ModelAvailability.ready) }
        )
        let split = ModelListPolicy.partition(
            ModelListPolicy.rows(availability: availability, draft: MeetingDraft())
        )

        #expect(split.downloaded.map(\.model.id) == SpeechModelCatalog.all.map(\.id))
        #expect(split.available.isEmpty)
    }

    /// Ordinal, not a benchmark. The meters say "this one is more accurate than
    /// that one" from the tier the catalog already assigns and the size of the
    /// artifact, which are the only two things about a model this app knows
    /// without running an evaluation it has no data for.
    @Test("The meters stay inside the bars they are drawn with")
    func metersAreInRange() {
        for model in SpeechModelCatalog.all {
            #expect((1...5).contains(ModelListPolicy.accuracyMeter(model)), "\(model.id) accuracy")
            #expect((1...5).contains(ModelListPolicy.speedMeter(model)), "\(model.id) speed")
        }
    }

    @Test("The meters order the catalog the way the catalog is ordered")
    func metersFollowTierAndSize() {
        let tiny = SpeechModelCatalog.whisperTiny
        let large = SpeechModelCatalog.whisperLargeV3

        #expect(ModelListPolicy.accuracyMeter(large) > ModelListPolicy.accuracyMeter(tiny))
        #expect(ModelListPolicy.speedMeter(tiny) > ModelListPolicy.speedMeter(large))
    }

    /// A turbo build is the same weights behind a faster decoder, which is the
    /// entire reason Argmax publishes it, so it cannot rank slower than the
    /// build it was derived from.
    @Test("A turbo build is never ranked slower than the build it came from")
    func turboIsNotSlowerThanItsSource() {
        #expect(
            ModelListPolicy.speedMeter(SpeechModelCatalog.whisperLargeV3Turbo)
                >= ModelListPolicy.speedMeter(SpeechModelCatalog.whisperLargeV3)
        )
        #expect(
            ModelListPolicy.speedMeter(SpeechModelCatalog.distilLargeV3Turbo)
                >= ModelListPolicy.speedMeter(SpeechModelCatalog.distilLargeV3)
        )
    }

    @Test("The action button says what pressing it will do")
    func actionLabels() {
        #expect(ModelListPolicy.downloadLabel(.notInstalled) == "Download")
        #expect(ModelListPolicy.downloadLabel(.downloading(.starting)) == "Cancel")
        #expect(ModelListPolicy.downloadLabel(.ready) == "Ready")
        #expect(ModelListPolicy.downloadLabel(.failed("no network")) == "Retry")
    }

    @Test("Only a download in flight can be cancelled")
    func cancellableStates() {
        #expect(ModelListPolicy.canCancel(.downloading(.starting)))
        #expect(ModelListPolicy.canCancel(.notInstalled) == false)
        #expect(ModelListPolicy.canCancel(.ready) == false)
        #expect(ModelListPolicy.canCancel(.failed("no network")) == false)
    }

    /// Cancelling is the one action that has to work during a meeting: a
    /// download started before Record is still saturating the same link, and
    /// refusing to stop it because the machine is busy is the wrong way round.
    @Test("A download can be cancelled while a meeting is being captured")
    func cancellingIsNotBlockedByARecording() {
        #expect(ModelListPolicy.canCancel(.downloading(.starting)))
        #expect(
            ModelListPolicy.canDownload(availability: .downloading(.starting), phase: .recording) == false
        )
    }

    @Test("The progress a row carries is the progress it shows")
    func rowsCarryProgress() {
        let progress = ModelDownloadProgress(fraction: 0.24, bytesPerSecond: 9_800_000)
        let rows = ModelListPolicy.rows(
            availability: [SpeechModelCatalog.whisperBase.id: .downloading(progress)],
            draft: MeetingDraft()
        )
        let row = rows.first { $0.model.id == SpeechModelCatalog.whisperBase.id }

        #expect(row?.availability == .downloading(progress))
        #expect(ModelDownloadText.percentage(progress.fraction) == "Downloading 24%")
        #expect(ModelDownloadText.rate(progress.bytesPerSecond) == "9.8 MB/s")
    }
}
