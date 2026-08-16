import Foundation
import Testing
@testable import Hushnote

/// `.onChange(of:)` fires for any value change between body evaluations, not
/// just typing. `AppCoordinator` replaces `state.transcript` wholesale on every
/// live delta, so each machine revision used to fire the transcript editor's
/// change handler and mark the line `isUserEdited`. `MeetingStore.upsertSegments`
/// then honours that flag -- `if existing?.isUserEdited == true { record.text =
/// existing!.text }` -- and discards every later ASR revision of the line. Merely
/// opening the Transcript tab froze the live transcript on the words that
/// happened to be on screen.
@Suite("Transcript edit policy")
struct TranscriptEditPolicyTests {
    @Test("A transcript still being produced is not editable")
    func liveTranscriptIsReadOnly() {
        for phase in [RecordingPhase.recording, .paused, .preparing, .finalizing(0.5)] {
            #expect(TranscriptEditPolicy.allowsEditing(phase: phase) == false)
        }
    }

    @Test("A settled transcript is editable")
    func settledTranscriptIsEditable() {
        #expect(TranscriptEditPolicy.allowsEditing(phase: .idle))
        #expect(TranscriptEditPolicy.allowsEditing(phase: .failed("finalization stopped")))
    }

    /// The whole point: a write the user did not make must not be recorded as
    /// one, however much the text changed.
    @Test("A change to an unfocused field is the model writing, not the user")
    func unfocusedChangeIsNotAHumanEdit() {
        #expect(
            TranscriptEditPolicy.isHumanEdit(
                isFocused: false,
                from: "we should ship on",
                to: "we should ship on Friday"
            ) == false
        )
    }

    @Test("A change to the focused field is the user typing")
    func focusedChangeIsAHumanEdit() {
        #expect(
            TranscriptEditPolicy.isHumanEdit(
                isFocused: true,
                from: "we should ship on Friday",
                to: "we should ship on Thursday"
            )
        )
    }

    /// Focus alone is not enough. SwiftUI re-evaluates a body for reasons that
    /// have nothing to do with the field, and a same-value write must not queue
    /// a database round trip or claim the line for the user.
    @Test("Focus without a change is not an edit")
    func focusedNonChangeIsNotAnEdit() {
        #expect(
            TranscriptEditPolicy.isHumanEdit(
                isFocused: true,
                from: "unchanged",
                to: "unchanged"
            ) == false
        )
    }
}
