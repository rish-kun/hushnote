import Foundation
import Testing
@testable import Hushnote

/// The models screen was a hardcoded tuple array duplicating
/// `SpeechModelCatalog`, matched back to real models by lowercased substring
/// search. `grep -c '\.disabled('` over the file returned 0: the Download
/// button was always labelled "Download", carried no installed, downloading or
/// failed state, and nothing stopped it during a recording -- so a user could
/// trigger a multi-gigabyte Core ML load mid-meeting, on the same Neural Engine
/// the live transcriber was running on.
@Suite("Model list policy")
struct ModelListPolicyTests {
    @Test("The list is the catalog, not a copy of it")
    func listComesFromTheCatalog() {
        let rows = ModelListPolicy.rows(availability: [:], draft: MeetingDraft())

        #expect(rows.map(\.model.id) == SpeechModelCatalog.all.map(\.id))
    }

    /// The reason this matters: the final pass and the live transcriber both
    /// run on the Neural Engine this download would load a model onto.
    @Test("Downloading is refused while the machine is busy with a meeting")
    func downloadIsBlockedWhileBusy() {
        for phase in [RecordingPhase.recording, .paused, .preparing, .finalizing(0.5)] {
            #expect(
                ModelListPolicy.canDownload(availability: .notInstalled, phase: phase) == false
            )
        }
    }

    @Test("Downloading is allowed when nothing is in flight")
    func downloadIsAllowedWhenIdle() {
        #expect(ModelListPolicy.canDownload(availability: .notInstalled, phase: .idle))
        #expect(ModelListPolicy.canDownload(availability: .failed("no network"), phase: .idle))
    }

    @Test("A model already downloading or ready is not downloaded again")
    func downloadIsNotRepeated() {
        #expect(ModelListPolicy.canDownload(availability: .downloading(.starting), phase: .idle) == false)
        #expect(ModelListPolicy.canDownload(availability: .ready, phase: .idle) == false)
    }

    @Test("The button says which of the four states it is in")
    func labelReflectsState() {
        #expect(ModelListPolicy.downloadLabel(.notInstalled) == "Download")
        // A download in flight offers the only thing worth pressing: stop.
        #expect(ModelListPolicy.downloadLabel(.downloading(.starting)) == "Cancel")
        #expect(ModelListPolicy.downloadLabel(.ready) == "Ready")
        #expect(ModelListPolicy.downloadLabel(.failed("no network")) == "Retry")
    }

    /// Roles were part of the hardcoded table and drifted from the draft that
    /// actually selects the models.
    @Test("Roles come from the models the meeting will really use")
    func rolesFollowTheDraft() {
        let rows = ModelListPolicy.rows(availability: [:], draft: MeetingDraft())
        let live = rows.filter { $0.role == .live }
        let final = rows.filter { $0.role == .final }

        #expect(live.count == 1)
        #expect(final.count == 1)
        #expect(live.first?.model.id == SpeechModelCatalog.whisperLargeV3Turbo.id)
        #expect(final.first?.model.id == SpeechModelCatalog.whisperLargeV3.id)
    }

    /// The old name-matching fell through to Large v3 for anything it did not
    /// recognise, so asking for Tiny downloaded a three-gigabyte model instead.
    @Test("Every catalog model resolves to itself, not to a fallback")
    func resolverDoesNotFallThrough() {
        for model in SpeechModelCatalog.all {
            #expect(
                SpeechModelResolver.model(named: model.displayName).id == model.id,
                "\(model.displayName) resolved to the wrong model"
            )
        }
    }

    @Test("The draft's short names still resolve")
    func resolverHandlesDraftNames() {
        #expect(SpeechModelResolver.model(named: "large-v3-turbo").id == SpeechModelCatalog.whisperLargeV3Turbo.id)
        #expect(SpeechModelResolver.model(named: "large-v3").id == SpeechModelCatalog.whisperLargeV3.id)
        #expect(SpeechModelResolver.model(named: "small").id == SpeechModelCatalog.whisperSmall.id)
        #expect(SpeechModelResolver.model(named: "medium").id == SpeechModelCatalog.whisperMedium.id)
    }
}
