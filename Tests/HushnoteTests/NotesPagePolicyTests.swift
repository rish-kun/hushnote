import Foundation
import Testing
@testable import Hushnote

/// The notes page used to print "Saved automatically to this meeting"
/// regardless of what was happening -- over an empty page, mid-write, and
/// after a failure alike. These are the three things it can now say.
@Suite("Notes page state")
struct NotesPagePolicyTests {
    @Test("An empty page has not been saved, it has nothing to save")
    func blank() {
        #expect(NotesPagePolicy.saveState(text: "", isSaving: false) == .blank)
        #expect(NotesPagePolicy.saveState(text: "   \n\t ", isSaving: false) == .blank)
    }

    @Test("A pending write outranks whatever is on the page")
    func savingWins() {
        #expect(NotesPagePolicy.saveState(text: "", isSaving: true) == .saving)
        #expect(NotesPagePolicy.saveState(text: "Ship on Friday", isSaving: true) == .saving)
    }

    @Test("Written and settled reads as saved")
    func saved() {
        #expect(NotesPagePolicy.saveState(text: "Ship on Friday", isSaving: false) == .saved)
    }

    /// Splitting on `" "` alone counted a note broken across lines as one long
    /// word, and counted surrounding space as words of its own.
    @Test("Words are separated by any whitespace, and space alone is not a word")
    func wordCount() {
        #expect(NotesPagePolicy.wordCount("") == 0)
        #expect(NotesPagePolicy.wordCount("   \n  ") == 0)
        #expect(NotesPagePolicy.wordCount("  one  ") == 1)
        #expect(NotesPagePolicy.wordCount("ship the\nrelease\ton Friday") == 5)
    }

    /// The old copy said "Write notes while the meeting runs" on a screen the
    /// navigation could not reach during a meeting. It can now -- but only
    /// while one is actually running.
    @Test("The invitation only promises what the phase can deliver")
    func placeholder() {
        #expect(NotesPagePolicy.placeholder(isCapturing: true).hasPrefix("Write while it happens"))
        #expect(
            NotesPagePolicy.placeholder(isCapturing: false)
                .hasPrefix("Anything worth keeping")
        )
    }

    @Test("One word is not one words")
    func label() {
        #expect(NotesPagePolicy.wordCountLabel(0) == "0 words")
        #expect(NotesPagePolicy.wordCountLabel(1) == "1 word")
        #expect(NotesPagePolicy.wordCountLabel(2) == "2 words")
    }
}
