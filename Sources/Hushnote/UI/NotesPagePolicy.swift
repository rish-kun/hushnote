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

    /// What an empty page invites.
    ///
    /// It read "Write notes while the meeting runs…" while the recording screen
    /// had no tab bar at all, so it described something the navigation could
    /// not reach. Now that it can, the invitation is real -- but only while a
    /// meeting is actually running, and only then is there a moment to stamp.
    nonisolated static func placeholder(isCapturing: Bool) -> String {
        isCapturing
            ? "Write while it happens…"
            : "Anything worth keeping about this meeting…"
    }
}

/// Writing a moment into a note.
///
/// A note taken during a meeting is about something that was just said, and
/// the note itself is the only place that association can live -- Hushnote has
/// no audio playback, so a stamp is a bookmark into the transcript, not a
/// scrub position.
///
/// Pure, and deliberately index-free at its boundary: a `String.Index` is
/// invalidated by the very mutation this performs, so the caret comes back as
/// a character offset for the caller to re-derive against the new text.
enum NoteStampPolicy {
    struct Stamp: Equatable, Sendable {
        var text: String
        /// Where the caret belongs afterwards, in characters from the start.
        var caretOffset: Int
    }

    /// - Parameters:
    ///   - text: the note as it stands.
    ///   - selection: what the editor has selected, or `nil` for "no caret" --
    ///     which happens when the field has never been focused.
    ///   - seconds: meeting-relative time. Must come from the transcript's own
    ///     clock (`TranscriptLineItem.end`), never from `AppViewState.elapsed`:
    ///     that is a one-second sleep accumulator that lags audio time by
    ///     seconds over a long meeting, so a stamp taken from it would point
    ///     several sentences behind the words it means.
    nonisolated static func stamping(
        _ text: String,
        selection: Range<String.Index>?,
        seconds: TimeInterval
    ) -> Stamp {
        // Collapsed to the start rather than replacing the range. Typing over
        // a selection is what typing does; a stamp is a command, and a command
        // that silently ate the paragraph you had selected is the kind of loss
        // an undo stack gets blamed for afterwards.
        let caret = selection?.lowerBound ?? text.endIndex

        // Each stamp opens its own line, so a note reads as a list of moments
        // rather than one paragraph with times buried in it. Already at the
        // start of a line, nothing is added -- pressing the shortcut twice in
        // a row must not leave a blank line behind.
        let atLineStart = caret == text.startIndex || text[text.index(before: caret)] == "\n"
        let stamp = (atLineStart ? "" : "\n") + "[\(DurationText.clock(seconds))] "

        var next = text
        next.insert(contentsOf: stamp, at: caret)
        return Stamp(
            text: next,
            caretOffset: text.distance(from: text.startIndex, to: caret) + stamp.count
        )
    }
}
