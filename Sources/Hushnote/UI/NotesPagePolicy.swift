import Foundation

/// What the notes page can truthfully say about itself.
///
/// The page used to print "Saved automatically to this meeting" under its
/// title: a claim about the future, made identically whether a write was in
/// flight, had just succeeded, or had never been needed. The debounce and the
/// write have always been real (`AppCoordinator.queueMeetingNotes`), so the
/// page can report them instead of promising them.
enum NotesPagePolicy {
    enum SaveState: Equatable, Sendable {
        /// Nothing written yet. Saying "Saved" over an empty page would be
        /// true and useless; there is nothing to have saved.
        case blank
        case saving
        case saved
    }

    /// - Parameters:
    ///   - text: what is on the page right now.
    ///   - isSaving: whether a debounced write for this meeting is pending.
    nonisolated static func saveState(text: String, isSaving: Bool) -> SaveState {
        if isSaving { return .saving }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .blank : .saved
    }

    /// Words, counted the way a writer counts them.
    ///
    /// Split on whitespace rather than on `" "` alone, so a note broken across
    /// lines is not one long word, and so leading or trailing space never
    /// contributes a phantom.
    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Pluralised, because "1 words" in a notebook is the kind of thing that
    /// makes a page feel unattended.
    nonisolated static func wordCountLabel(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
    }
}
