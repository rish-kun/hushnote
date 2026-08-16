import Foundation
import Testing
@testable import Hushnote

/// `MeetingWorkspaceView` reloads on `.task(id: meetingID)`, and `loadMeeting`
/// wrote `state.meetingNotes[id] = meeting.notes` unconditionally -- before the
/// `guard state.activeMeetingID != id` that protects the transcript, and with
/// nothing protecting the notes at all. Type a note, navigate away inside the
/// 350 ms save debounce, navigate back, and the stale row was read over the
/// newer text; the next keystroke then wrote the stale buffer back. Silent,
/// non-deterministic, and it looked like the app had simply forgotten.
@Suite("Note reload policy")
struct NoteReloadPolicyTests {
    @Test("A meeting opened for the first time adopts what is stored")
    func firstOpenAdoptsStoredNotes() {
        #expect(
            NoteReloadPolicy.shouldAdopt(
                stored: "Agenda: pricing",
                current: nil,
                hasPendingSave: false
            )
        )
    }

    /// The bug. The buffer is newer than the row it would be overwritten with.
    @Test("A note still waiting to be saved is not overwritten by the old row")
    func unsavedTextSurvivesAReload() {
        #expect(
            NoteReloadPolicy.shouldAdopt(
                stored: "Agenda: pricing",
                current: "Agenda: pricing, and the migration plan",
                hasPendingSave: true
            ) == false
        )
    }

    @Test("Once the save has landed, the stored row is authoritative again")
    func savedTextIsAdopted() {
        #expect(
            NoteReloadPolicy.shouldAdopt(
                stored: "Agenda: pricing, and the migration plan",
                current: "Agenda: pricing",
                hasPendingSave: false
            )
        )
    }

    /// Re-assigning an identical value would publish an observation change and
    /// re-render the editor for nothing.
    @Test("An unchanged note is not written back over itself")
    func identicalNotesAreNotRewritten() {
        #expect(
            NoteReloadPolicy.shouldAdopt(
                stored: "Agenda: pricing",
                current: "Agenda: pricing",
                hasPendingSave: false
            ) == false
        )
    }

    /// Emptiness is a real value a user can have typed, and must not be treated
    /// as "nothing loaded yet".
    @Test("A deliberately emptied note is not refilled from the row")
    func emptiedNoteIsNotRefilled() {
        #expect(
            NoteReloadPolicy.shouldAdopt(
                stored: "Agenda: pricing",
                current: "",
                hasPendingSave: true
            ) == false
        )
    }
}
