import Foundation
import Testing
@testable import Hushnote

/// Writing a moment into a note at the caret. The caret comes back as a
/// character offset rather than a `String.Index` because the insertion that
/// just happened invalidated every index the caller was holding.
@Suite("Note moment stamps")
struct NoteStampPolicyTests {
    private func index(_ text: String, _ offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: offset)
    }

    @Test("An empty page takes the stamp with no line break before it")
    func emptyPage() {
        let stamped = NoteStampPolicy.stamping("", selection: nil, seconds: 0)
        #expect(stamped.text == "[00:00] ")
        #expect(stamped.caretOffset == 8)
    }

    @Test("A stamp mid-line opens a line of its own")
    func breaksTheLine() {
        let text = "Ship on Friday"
        let caret = index(text, text.count)
        let stamped = NoteStampPolicy.stamping(
            text, selection: caret..<caret, seconds: 754
        )
        #expect(stamped.text == "Ship on Friday\n[12:34] ")
        #expect(stamped.caretOffset == stamped.text.count)
    }

    /// Pressing the shortcut twice must not leave a blank line behind, so a
    /// caret already at the start of a line gets no second break.
    @Test("A caret already at the start of a line gets no extra break")
    func noDoubleBreak() {
        let text = "Ship on Friday\n"
        let caret = index(text, text.count)
        let stamped = NoteStampPolicy.stamping(
            text, selection: caret..<caret, seconds: 65
        )
        #expect(stamped.text == "Ship on Friday\n[01:05] ")
    }

    @Test("A stamp at the very start of the page takes no break either")
    func atStart() {
        let text = "Ship on Friday"
        let caret = text.startIndex
        let stamped = NoteStampPolicy.stamping(
            text, selection: caret..<caret, seconds: 5
        )
        #expect(stamped.text == "[00:05] Ship on Friday")
        #expect(stamped.caretOffset == 8)
    }

    /// A stamp is a command, not typed input. Replacing the selection the way
    /// a keystroke would means a shortcut can silently eat a paragraph.
    @Test("A selection is collapsed to its start, never replaced")
    func neverDeletes() {
        let text = "Ship on Friday"
        let selection = index(text, 5)..<index(text, 7)
        let stamped = NoteStampPolicy.stamping(text, selection: selection, seconds: 0)

        #expect(stamped.text == "Ship \n[00:00] on Friday")
        #expect(stamped.text.contains("on Friday"))
    }

    /// The offset has to address the *new* string, because that is the only
    /// one that still exists by the time the caller uses it.
    @Test("The reported caret lands just past the stamp in the new text")
    func caretIsUsableAfterTheMutation() {
        let text = "one\ntwo"
        let caret = index(text, 4)
        let stamped = NoteStampPolicy.stamping(
            text, selection: caret..<caret, seconds: 3_661
        )
        let landed = stamped.text.index(stamped.text.startIndex, offsetBy: stamped.caretOffset)

        #expect(stamped.text == "one\n[1:01:01] two")
        #expect(String(stamped.text[landed...]) == "two")
    }

    @Test("No caret at all stamps at the end of the page")
    func noSelection() {
        let stamped = NoteStampPolicy.stamping("one", selection: nil, seconds: 0)
        #expect(stamped.text == "one\n[00:00] ")
    }
}
