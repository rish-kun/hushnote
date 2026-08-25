# Notes and Transcript: two pages that forgot they were pages

*2026-08-25. Supplements `2026-08-24-unified-sidebar-meeting-canvas-design.md`;
does not replace it.*

The unified-canvas work gave every route one background and one page language.
Two workspace tabs did not receive it. This document says what is wrong with
them and what replaces it.

## What is actually wrong

### Notes

1. **The writing surface is a form field.** `MeetingNotesView` fences its
   `TextEditor` in a `RoundedRectangle` with a `paperRaised` fill and a `rule`
   stroke, floating on the shell's paper. It is the last unmistakably-platform
   control in the app: every other route writes directly on the page. A box
   with a stroke says "fill this in"; a notebook says "write".
2. **Nine hundred points of nothing.** The column is capped at
   `transcriptMeasure` and then left-anchored in the full pane. Transcript and
   Ask both put an index or a rail in that space. Notes puts a void.
3. **A decorative pencil.** `Image(systemName: "square.and.pencil")` in moss,
   at the right edge of the column, is not a button and does nothing. It is the
   only object in the void.
4. **The subtitle is a promise, not a state.** "Saved automatically to this
   meeting" is a claim about the future. `AppCoordinator.queueMeetingNotes`
   already debounces at 350 ms and tracks in-flight writes in
   `pendingNoteTasks`; the page could say what is true right now and does not.
5. **The placeholder describes something impossible.** "Write notes while the
   meeting runs…" — while a meeting runs, `MeetingWorkspaceView` routes to
   `ActiveMeetingView`, which has no tab bar and therefore no Notes tab. The
   copy advertises a feature the navigation does not reach.
6. **A redundant title.** `HushnotePageHeader` above already names the meeting
   and the tab bar already says "Notes". "Working notes" is a third label for
   the same thing. The Transcript tab carries no in-body title and reads
   better for it.

### Transcript

1. **A hole between the prose and its index.** `TranscriptView` lets the reader
   `ScrollView` expand to `.infinity` and pins the rail to the trailing edge.
   At a 1650 pt pane that is a 792 pt column at the left, a 232 pt rail at the
   right, and roughly 470 pt of nothing in between — with the reader's own
   scroll indicator stranded in the middle of the page. `AskMeetingView`
   already does the correct thing (column, 44 pt, rail, all left-anchored); the
   transcript is the outlier.
2. **The first chapter header is an orphan.** `TranscriptChapterHeader` draws a
   full-measure rule with `padding(.top, 48)`, so every transcript opens with a
   horizontal line ruled across the top of the page with nothing above it. A
   document begins; it is not ruled off from what precedes it.
3. **`00:00` is printed twice**, seventy points apart — once in that header,
   once in the first paragraph's margin.
4. **The index is louder than the text it indexes.** Each rail entry is a
   filled selectable row carrying a moss `TimestampButton` capsule, a speaker
   list, and two lines of preview prose. Seven stacked is a second column of
   body copy competing with the first, and the speaker lists read
   "Speaker 1, Speaker 2 / Speaker 2 / Speaker 2, Speaker 1" — repetition, not
   information. An index is scanned, not read.
5. **A button inside a button.** The `TimestampButton` sits inside
   `HushnoteSelectableRow`'s own button, giving one row two overlapping
   targets that do the same thing.

## What replaces it

### One spread, three tabs

Notes, Transcript and Ask resolve the same geometry and left-anchor it at the
gutter: **apparatus margin (64) · gap (24) · measure (704) · gap (44) ·
rail (232)**. Switching tabs no longer moves the text sideways. Whatever the
container has beyond the spread stays outside it as page margin — the way an
over-widened document window looks — rather than opening a hole in the middle.

`TranscriptLayout` grows a `railGap` (44, matching Ask) in place of
`railMinimumGap`, and a `readerWidth` that is finite exactly when an index sits
beside the prose. Nothing about the measure changes: 704 is why the transcript
is readable, and widening the window must never widen it.

### Notes

- **No box.** The editor writes on the page: no fill, no stroke, no corner
  radius, full page height.
- **The margin is kept and left empty.** It costs nothing and it is what makes
  notes prose start at the same x as transcript prose.
- **No in-body title, no pencil.** The tab bar names the tab.
- **A rail that says something true.** `NOTES` — the live save state and a word
  count. `THIS MEETING` — duration, line count, whether a summary exists;
  the same three facts Ask's rail shows, so the two agree.
- **`AppViewState.notesSaving`** carries the in-flight write out of the
  coordinator so "Saving…" / "Saved" is observed state rather than a promise.
  `NotesPagePolicy` holds the decision and the word count, and is tested.
- **Honest placeholder copy.** Reaching Notes during a recording is a real
  missing feature — `ActiveMeetingView` has no tab bar — but it is a
  navigation change, not a visual one, and is out of scope here. Until it
  exists the placeholder stops advertising it.

### Transcript

- **The index follows the text.** The reader pane is capped at
  `gutter + column + railGap`, so the rail sits beside the prose it indexes and
  the scroll indicator returns to the edge of the column.
- **The opening chapter draws no header** — only a zero-height anchor, so the
  index still points at it and `TranscriptChapterVisibility` still measures
  from it. The rule and the duplicate `00:00` are gone.
- **Rail rows are one line**: time, then the chapter's opening words,
  truncated. Speakers move out of the row (they were noise) and survive in the
  foot's voice count. The nested `TimestampButton` is gone; the row is the
  target.

## Second pass: the deferred items, done

The three items below were deferred in the first pass. Two are now built; the
third stays deferred, and one bug the investigation turned up is fixed.

### Notes during a recording — built

`ActiveMeetingView` now carries `MeetingWorkspaceTabBar`. The recording header,
the level-meter strip and the notice banner stay *above* it: they belong to the
capture, not to whichever tab is open over it. `recordingHeader` and
`meetingHeader` deliberately stay separate — rename, folder-move and export are
invalid mid-capture, and `canExportAudio` gates on a `MeetingAudioTrack` row
that `stopMeeting` does not write until the end.

Two things this forced:

- **A re-render hazard that already existed.** `ActiveMeetingView.body` read
  `state.transcript.isEmpty` directly, so it was already rebuilding its header
  and level strip on every live ASR delta — harmless until a text editor joined
  them. The transcript read moved into `ActiveTranscriptTab` and the rail's
  reads into `NotesRail`, so the body that owns the editor depends on nothing
  written at speaking cadence.
- **Summary and Ask must not be offered mid-recording.** Both are gated only on
  the transcript being non-empty, which it is during capture. A summary
  generated then cites segments the final pass is about to re-mint.
  `WorkspaceTabAvailability` restricts a busy phase to `[.notes, .transcript]`
  and resolves a stored tab read-only, so the preference survives.
  `governingPhase` keeps this per-meeting: the phase is global, and reading it
  directly hid Summary and Ask on unrelated finished meetings.

### Timestamp stamping — built, natively

`TextEditor(text:selection:)` is macOS 15 and the package targets macOS 15, so
`NoteStampPolicy` splices at the caret with no AppKit bridge. `⌘⇧T`, offered
only while capturing. The time comes from `state.transcript.last?.end` — the
audio sample clock — and never from `AppViewState.elapsed`, a one-second sleep
accumulator that lags real time by seconds over a long meeting.

A selection is collapsed to its start rather than replaced: typing over a
selection is what typing does, but a stamp is a command, and one that silently
ate a selected paragraph is a loss the undo stack gets blamed for.

### An unflushed note could be lost to ⌘Q — fixed

Found while wiring the above, and pre-existing. `queueMeetingNotes` waits
350 ms; `TerminationGuard` had no case for it, so a note typed and then quit
within that window never reached the database.
`TerminationDecision.flushPendingNotes` now defers the reply long enough for
`AppCoordinator.flushPendingNotes()` to write it, and every other terminating
branch flushes on its way out.

### Tappable timestamps — still deferred, and should stay that way

It needs three things that do not exist: a parser over note text, a
seconds→segment resolver, and a rich-text editor. `AttributedString` editing is
macOS 26, so the only way to render a tappable run today is the `NSTextView`
wrapper — which would have to re-earn the placeholder, undo, spell-check,
dark-mode text colour, and the "a focused field belongs to the user" rule that
`TranscriptRowText.reseededDraft` exists to enforce. The stamp is a durable
plain-text convention instead. There is also no audio playback in this app, so
a stamp can only ever mean "scroll the transcript there".

### A notes edit timestamp — still not built

Nothing persists one, and inventing one to fill a rail line would be
decoration.
