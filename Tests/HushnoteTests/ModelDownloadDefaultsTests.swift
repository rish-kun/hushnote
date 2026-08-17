import Foundation
import Testing
@testable import Hushnote

/// A model chosen on the models screen used to last exactly as long as the
/// process: `MeetingDraft` was built from its own literals on every launch and
/// nothing ever wrote the choice down.
@Suite("Speech model defaults")
struct ModelDownloadDefaultsTests {
    private func scratchDefaults() -> UserDefaults {
        let suite = "dev.rishit.hushnote.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A chosen model survives the launch that follows")
    func choiceRoundTrips() {
        let defaults = scratchDefaults()
        SpeechModelDefaults.store(
            liveModelID: SpeechModelCatalog.whisperSmall.id,
            finalModelID: SpeechModelCatalog.whisperMedium.id,
            in: defaults
        )
        var draft = MeetingDraft()
        SpeechModelDefaults.apply(to: &draft, from: defaults)

        #expect(draft.liveModel == SpeechModelCatalog.whisperSmall.id)
        #expect(draft.finalModel == SpeechModelCatalog.whisperMedium.id)
    }

    @Test("Nothing stored leaves the app's own choices standing")
    func emptyDefaultsChangeNothing() {
        var draft = MeetingDraft()
        let original = draft
        SpeechModelDefaults.apply(to: &draft, from: scratchDefaults())

        #expect(draft == original)
    }

    /// The resolver falls through to Large v3 for a name it does not recognise,
    /// so a stored identifier that the catalog has since dropped would silently
    /// become a three-gigabyte model rather than the choice the user last made.
    @Test("An identifier the catalog no longer has is ignored, not resolved")
    func staleIdentifiersAreIgnored() {
        let defaults = scratchDefaults()
        SpeechModelDefaults.store(
            liveModelID: "whisperkit.a-model-that-was-removed",
            finalModelID: SpeechModelCatalog.whisperSmall.id,
            in: defaults
        )
        var draft = MeetingDraft()
        SpeechModelDefaults.apply(to: &draft, from: defaults)

        #expect(draft.liveModel == MeetingDraft().liveModel)
        #expect(draft.finalModel == SpeechModelCatalog.whisperSmall.id)
    }

    @Test("The stored value is a catalog identifier, so it round-trips through the resolver")
    func storedValuesResolveToThemselves() {
        let defaults = scratchDefaults()
        for model in SpeechModelCatalog.all {
            SpeechModelDefaults.store(liveModelID: model.id, finalModelID: model.id, in: defaults)
            var draft = MeetingDraft()
            SpeechModelDefaults.apply(to: &draft, from: defaults)

            #expect(SpeechModelResolver.model(named: draft.liveModel).id == model.id)
            #expect(SpeechModelResolver.model(named: draft.finalModel).id == model.id)
        }
    }
}
