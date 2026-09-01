import Foundation
import Testing
@testable import Hushnote

@Suite("Global quick note")
struct QuickNotePolicyTests {
    @Test("A quick note carries the captured-media timestamp")
    func timestampedAppend() {
        #expect(QuickNotePolicy.appending(
            draft: "  Ask about launch  ",
            at: 65_432,
            to: "Opening note"
        ) == "Opening note\n[01:05] Ask about launch")
    }

    @Test("Blank input does not mutate meeting notes")
    func blankInput() {
        #expect(QuickNotePolicy.appending(draft: " \n ", at: 1_000, to: "Existing") == nil)
    }

    @Test("The global shortcut requires the exact key and required modifiers")
    func shortcutMatching() {
        let required = QuickNoteShortcutPolicy.requiredModifiers
        #expect(QuickNoteShortcutPolicy.matches(
            keyCode: QuickNoteShortcutPolicy.keyCode,
            modifierFlags: required
        ))
        #expect(!QuickNoteShortcutPolicy.matches(keyCode: 0, modifierFlags: required))
        #expect(!QuickNoteShortcutPolicy.matches(
            keyCode: QuickNoteShortcutPolicy.keyCode,
            modifierFlags: 0
        ))
    }

    @Test("Focus returns only to a different prior application")
    func focusReturn() {
        #expect(QuickNoteFocusPolicy.shouldRestore(
            previousProcessID: 42,
            currentProcessID: 7,
            hushnoteProcessID: 7
        ))
        #expect(!QuickNoteFocusPolicy.shouldRestore(
            previousProcessID: 7,
            currentProcessID: 7,
            hushnoteProcessID: 7
        ))
        #expect(!QuickNoteFocusPolicy.shouldRestore(
            previousProcessID: nil,
            currentProcessID: 7,
            hushnoteProcessID: 7
        ))
        #expect(!QuickNoteFocusPolicy.shouldRestore(
            previousProcessID: 42,
            currentProcessID: 99,
            hushnoteProcessID: 7
        ))
    }
}
