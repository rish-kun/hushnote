import Foundation

enum QuickNotePolicy {
    static func appending(
        draft: String,
        at timelineMilliseconds: Int64,
        to existing: String
    ) -> String? {
        let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        let seconds = Double(max(0, timelineMilliseconds)) / 1_000
        let line = "[\(DurationText.clock(seconds))] \(note)"
        guard !existing.isEmpty else { return line }
        return existing.hasSuffix("\n") ? existing + line : existing + "\n" + line
    }
}

enum QuickNoteShortcutPolicy {
    static let keyCode: UInt16 = 45 // ANSI N
    static let requiredModifiers: UInt = 1 << 18 | 1 << 19 // control + option

    static func matches(keyCode: UInt16, modifierFlags: UInt) -> Bool {
        keyCode == self.keyCode
            && modifierFlags & requiredModifiers == requiredModifiers
    }
}

enum QuickNoteFocusPolicy {
    static func shouldRestore(
        previousProcessID: Int32?,
        currentProcessID: Int32,
        hushnoteProcessID: Int32
    ) -> Bool {
        guard let previousProcessID else { return false }
        return currentProcessID == hushnoteProcessID
            && previousProcessID != hushnoteProcessID
    }
}
