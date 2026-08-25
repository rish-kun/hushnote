# AGENTS.md

Canonical agent-facing guidance for this repository.

## Commands

```sh
swift build                              # 0 warnings is the standard here
swift test                               # see "Counting tests" below
swift run Hushnote
./scripts/build-app.sh                   # debug bundle -> .build/Hushnote.app
./scripts/build-app.sh release           # release bundle
```

Run one suite or test by name (works for both test frameworks):

```sh
swift test --filter "Agent CLI model choice"      # a swift-testing @Suite display name
swift test --filter TranscriptRowBindingTests     # an XCTest class
```

### Counting tests

The suite runs **two frameworks**. `swift test` prints a separate count line for
each — an `Executed N tests` line for XCTest and a `Test run with N tests` line
for swift-testing — and **the real total is their sum**. Quoting only one line
has repeatedly produced false regression reports. 8 files use XCTest; the other
~63 use swift-testing.

### Warnings

Incremental builds do not re-emit warnings for unchanged files, so a clean
`swift build` after a small edit proves nothing. Force a full recompile before
claiming zero warnings:

```sh
find Sources Tests -name '*.swift' -exec touch {} + && swift build
```

One warning is baseline and not ours: FluidAudio's `benchmark.md` unhandled-file
warning from the dependency checkout.

### Commits

Write commit messages to a temp file and use `git commit -F <file>`. The `-m`
form under zsh has mangled quoted messages and silently truncated commits in
this repository. Style: imperative, sentence case, no Conventional Commits
prefix, no emoji.

## Architecture

macOS SwiftUI app, Swift 6 language mode with strict concurrency, SwiftPM
executable target. Everything runs locally except explicitly chosen cloud
summarizers.

### The pipeline layering

Capture, speech, and insight are three independent pipelines. `App/` is the only
layer that knows about all three.

- **`AudioPipeline/`** — an `actor` owning one capture session. Records system
  audio **via CoreAudio process taps** (`AudioHardwareCreateProcessTap`,
  `CATapDescription`). The README says ScreenCaptureKit; that is stale — the
  distinction matters because the governing privacy permission is *System Audio
  Recording Only*, not screen recording. Writes a normalized 48 kHz mono LPCM CAF
  incrementally so an abrupt termination still leaves a playable file.
- **`SpeechPipeline/`** — WhisperKit (vendored as the `argmax-oss-swift`
  package). Two decoders: a live streaming engine during capture, and
  `WhisperKitFinalTranscriber` for an accuracy-first full-file pass after Stop.
  FluidAudio does post-meeting diarization.
- **`InsightPipeline/`** — pluggable summarizers behind one protocol: a managed
  local `llama-server`, OpenAI, Anthropic, ChatGPT via Codex App Server, and
  three coding-agent CLIs driven as subprocesses (`claude`, `codex`, `opencode`).
- **`Persistence/`** — GRDB/SQLite. Numbered migrations in
  `DatabaseMigrations.swift`, currently through `v8` (`v8_meeting_folders`).
- **`App/`** — the hub layer, the only one that knows about every pipeline:
  - `AppCoordinator` owns every pipeline and writes to view state.
  - `AppViewState` (`@Observable`) is the single source of UI truth.
  - `AppPreferences` is durable, non-secret `UserDefaults`-backed state
    (provider choice, retained-audio default, appearance mode, sidebar
    destination, per-meeting workspace tab, model storage location).
    Credentials never live here — they stay in the data-protection Keychain.
  - `HushnoteTheme` holds the semantic palette, typography, and the adaptive
    layout policy (below).
  - `HushnoteApp` is the SwiftUI `App` entry point: it maps the persisted
    appearance preference to `preferredColorScheme`, owns the window/menu-bar
    scenes, and constructs the floating recording panel.
  - `HushnoteAppDelegate` / `TerminationGuard` intercept `NSApp.terminate` so
    a reflexive ⌘Q cannot destroy in-flight capture, finalization, or an
    unsaved summary edit (see load-bearing constraints below).
  - `FloatingRecordingPanelController` owns the always-on-top `NSPanel` that
    shows `RecordingPill` outside the main window, including multi-display
    position restore/clamping (`FloatingPanelPositioning`).
  - `StorageAccountingService` walks model, recording, and database
    directories off the main actor to build the Storage screen's byte report
    (`StorageReport`), counting filesystem allocation (`st_blocks`), not
    logical length, and deduplicating hard-linked files by device/inode.
  - `MeetingAudioExportService` copies or transcodes a meeting's recording
    (original CAF or M4A) to a user-chosen destination via a staged temp file
    plus atomic install, so a failed export never leaves a partial file at the
    destination path.
  - `BoundedWait` races arbitrary async work against a deadline and abandons
    (does not cancel) the loser — used where structured concurrency's
    task-group semantics would block a deadline on a hung child.
  - `HushnoteBrand` holds the vector brand mark, menu-bar template image, and
    the About window.
  - `MeetingExporter` (pre-existing) handles document-style exports.
- **`UI/`** — SwiftUI views only. Pure decision logic lives in testable
  `enum` policy types beside the views (`ModelListPolicy`,
  `TranscriptEditPolicy`, `TranscriptGrouping`, `LiveTranscriptionPolicy`,
  `AdaptiveLayoutPolicy`, `NotesPagePolicy`, `AskSuggestionPolicy`), which is
  how UI behaviour gets covered without driving a view hierarchy.

### The workspace reading spread

`TranscriptLayout` (`UI/TranscriptGrouping.swift`) is the geometry the meeting
workspace reads on, shared by the Transcript and Notes tabs so switching
between them never slides the text sideways. Ask composes the same measure and
rail gap by hand.

    gutter · margin (64) · gap (24) · measure (704) · railGap (44) · rail (232) · gutter

Container-aware rather than tier-aware: the apparatus margin appears at 856pt
and the index at 1180pt, neither of which is an `AdaptiveLayoutPolicy`
boundary.

**`readerWidth` is load-bearing.** It is finite exactly when an index sits
beside the prose, and the reading pane must be capped to it. Letting the reader
expand to the pane while the index stayed pinned to the trailing edge is what
put ~470pt of nothing between a paragraph and the entry indexing it at a
1650pt window, and stranded the reader's scroll indicator mid-page. The surplus
belongs *outside* the spread as page margin, not inside it. Never widen
`measure` to fill a container either — 704 is why the transcript is readable,
and `TranscriptLayoutTests` asserts it does not move.

Two more rules the transcript encodes:

- **The opening chapter draws no header.** `TranscriptChapterHeader(isOpening:)`
  renders a zero-height anchor instead of its rule and clock. A document begins
  rather than being ruled off from what is above it, and the first paragraph's
  margin already carries `00:00`. The anchor must stay: `ChapterOffsetKey` and
  `TranscriptChapterVisibility` still measure the reader's position from it.
- **The index is one line per chapter** — time, then opening words. It carried
  a `TimestampButton` capsule nested inside `HushnoteSelectableRow`'s own
  button (two hit targets doing one thing) plus a speaker list and two lines of
  preview prose, which made it a second column of body copy competing with the
  transcript. Voices survive as a count in the rail's foot.

### Scroll indicators

Every scroll container in the meeting workspace is suppressed with
`.scrollIndicators(.never)`, and the modifier is not interchangeable with
`.hidden`:

- **`.hidden` does nothing here.** It suppresses the indicator only under the
  *overlay* scroller style. `NSScroller.preferredScrollerStyle` resolves to
  `.legacy` whenever a mouse is attached — not only when the user sets "Show
  scroll bars: Always" — and under `.legacy` `.hidden` leaves
  `hasVerticalScroller == true` and the scroller reserves ~17pt of width.
  `.never` was measured to win under all three `AppleShowScrollBars` states.
- **`TextEditor` does honour it.** Its internal `AppKitScrollView` reads the
  SwiftUI environment, so the notes and summary editors need no AppKit bridge.
  Do not reach for one: a representable attached with `.background` is a
  *sibling* of that scroll view, so `NSView.enclosingScrollView` returns nil,
  and a version that climbs and descends to find it loses a race with SwiftUI,
  which re-asserts `hasVerticalScroller` afterwards. The measured result was an
  invisible scroller still consuming 17pt — nondeterministically.
- **Suppress the transcript and the notes editor together.** Removing a
  scroller returns ~17pt of width, and the Notes/Transcript x-alignment that
  `TranscriptLayout` exists to protect depends on both reclaiming it.

`TranscriptView`'s `readerBottomInset` (96) is load-bearing twice over: with no
indicator it is the only "you have reached the end" signal, and
`TranscriptFollow.isFollowing` must be told about it. The auto-scroll aligns the
last paragraph's *bottom* with the viewport, leaving the inset below it — so an
inset larger than the tolerance makes every auto-scroll read as the user
scrolling away, and "Jump to latest" lights on the first segment and never goes
out. That shipped for one release at 34 against a tolerance of 24, then got
worse at 96.

### The notes page

`MeetingNotesView` writes directly on the page: no fill, no stroke, no corner
radius. The stroked, raised `RoundedRectangle` it used to sit in was the last
unmistakably-platform control in the app, on the one route whose whole purpose
is writing. Its apparatus margin is deliberately empty — it exists only to
align notes prose with transcript prose.

`AppViewState.notesSaving` carries `AppCoordinator`'s in-flight debounced write
out to the view, so the page reports "Saving…" / "Saved" instead of printing
the standing promise "Saved automatically to this meeting". `NotesPagePolicy`
holds that decision and the word count.

### Notes during a recording

`ActiveMeetingView` carries `MeetingWorkspaceTabBar` too, so Notes and
Transcript are both reachable while capturing. Three things about it are
load-bearing:

- **`ActiveMeetingView.body` must never read `state.transcript`.** It is
  replaced on every live ASR delta, and SwiftUI attributes that dependency to
  whichever `body` reads it — so a read there rebuilds the header, the level
  strip and *the notes editor* every time somebody speaks. The live transcript
  and its empty state live in `ActiveTranscriptTab`, and the notes rail lives
  in `NotesRail`, for exactly this reason. Same discipline as `SystemLevelMeter`
  and `ElapsedTimeLabel`.
- **`WorkspaceTabAvailability` decides which tabs a phase offers**, and a busy
  phase offers only `[.notes, .transcript]`. Summary and Ask are gated only on
  the transcript being non-empty, which it is during live capture — offering
  them mid-recording would generate against provisional text whose segment
  identifiers the final pass is about to re-mint, leaving every citation
  dangling. Resolution of a stored tab is **read-only** (`resolved(_:during:)`):
  starting a recording on a meeting whose stored tab is Summary must not
  overwrite that preference.
- **`governingPhase` is not `state.recordingPhase`.** The phase is global but
  only one meeting owns the capture session; reading it directly hid Summary
  and Ask on every *other* meeting for the length of an unrelated recording.

### Stamping a moment into a note

`NoteStampPolicy` splices `[MM:SS] ` at the caret. `TextEditor(text:selection:)`
is macOS 15 and the package targets macOS 15, so this needs **no AppKit bridge
and no availability fence** — `TextSelection.Indices` yields real
`Range<String.Index>` values into the bound string. Do not reach for an
`NSTextView` wrapper here; it would have to re-earn the placeholder, undo,
spell-check, dark-mode text colour, and the "a focused field belongs to the
user" rule that `TranscriptRowText.reseededDraft` had to be written for.

Two constraints:

- **The clock is `state.transcript.last?.end`, never `AppViewState.elapsed`.**
  `elapsed` is a one-second `Task.sleep` accumulator that lags audio time by
  seconds over a long meeting; a stamp taken from it points several sentences
  behind the words it means. When nothing has been transcribed there is no
  honest time and the stamp is refused.
- **A `String.Index` does not survive the insertion.** The policy returns a
  character offset for the caller to re-derive against the new string.

Tappable timestamps are deliberately **not** built: they would need a note-text
parser, a seconds→segment resolver, and a rich-text editor that macOS 15 does
not have (`AttributedString` editing is macOS 26). The stamp is a durable
plain-text convention.

### Notes and termination

`queueMeetingNotes` waits 350 ms before writing so a sentence is one write
rather than forty, and quitting is exactly when that window is open.
`TerminationDecision.flushPendingNotes` defers the reply long enough for
`AppCoordinator.flushPendingNotes()` to land it. It raises no alert — an
unwritten note is not a question anyone needs to answer — so it ranks *below*
`confirmUnsavedSummary` and `confirmFinalizing`, both of which flush notes on
their own way out. Every branch of `applicationShouldTerminate` that ends in
the process dying goes through `flushNotesThenReply()`.

### Meeting management: folders, unfiled, and Recently Deleted

- A meeting belongs to zero or one `MeetingFolder` (`Meeting.folderID`, `nil`
  means Unfiled). Folders are flat — no nesting, color, or manual order — and
  list alphabetically by a normalized (case- and diacritic-folded) name that
  SQLite also enforces uniqueness on, because `localizedStandardCompare` can
  change with the user's locale between two writes.
- Folder deletion is a durable soft delete (`deletedAt`): every member meeting
  is bulk-moved to Unfiled (including meetings already in the trash), and the
  move deliberately does not touch the meeting's `updatedAt` so reorganizing
  never reorders a chronological list. See `MeetingStore.deleteMeetingFolder`.
- Meeting deletion is likewise soft (`Meeting.deletedAt`) via
  `softDeleteMeeting`/`restoreMeeting`. `MeetingStore.recentlyDeleted(since:)`
  and `purgeDeletedMeetings(olderThan:)` both default their window to **30
  days**; nothing purges automatically — a caller invokes
  `purgeDeletedMeetings` explicitly. Permanent deletion removes audio files
  before the relational row so a filesystem failure always leaves the meeting
  recoverable for a retry.
- Renaming a meeting or a folder validates and trims first
  (`updateMeetingTitle`, `renameMeetingFolder`); both enforce a length cap (200
  / 80 characters) and reject an all-whitespace name.
- `SidebarDestination` (`AppViewState.swift`) covers `.meetings`, `.unfiled`,
  `.folder(UUID)`, `.recentlyDeleted`, `.models`, `.storage`, `.settings`, and
  `.meeting(UUID)`, persisted through `AppPreferences.sidebarDestination` as a
  string (`folder:<uuid>`, `meeting:<uuid>`, etc.). A persisted meeting or
  folder ID that no longer exists is resolved back to `.meetings` before
  SwiftUI ever renders it (`AppViewState.resolvedSidebarDestination`), because
  a stale UUID would otherwise become an empty, unreachable destination.

### Adaptive layout

`AdaptiveLayoutPolicy` (`App/HushnoteTheme.swift`) is a container-width policy,
not a device policy, so the same tiers apply inside a narrow split view, full
screen, or a future secondary window:

- `.compact` below 760pt, `.regular` from 760–1099pt, `.wide` from 1100pt.
- Each tier owns a gutter (24 / 32 / 56), a content max width (`.infinity` /
  1,040 / `HushnoteTheme.contentMaxWidth` = 1,240), and whether it shows a
  right rail (`.wide` only).
- `AdaptivePageScaffold` is the shared detail-canvas container: it measures
  available width via `GeometryReader`, picks the tier, and lays out content
  plus an optional rail. `AdaptiveLayoutPolicy.finiteMinimumHeight(for:)`
  exists because a vertical `ScrollView` can propose an unbounded height to
  its child — turning that proposal directly into a minimum frame convinces
  the scroll view its content already fits and clips whatever scrolls below
  the fold, so an infinite proposal is floored to 0 instead.

### Semantic theme tokens

`HushnoteTheme.Token` has grown beyond the original five roles. Current set:
`paper`, `paperRaised`, `ink`, `secondaryInk`, `vermilion`, `vermilionInk`,
`moss`, `rule`, `inkFill`, plus the newer split-view roles — `canvas` (the
product-owned app background behind every split-view column),
`navigationSurface` (the sidebar's own shade, deliberately close to but
distinct from detail paper), `controlSurface` (fields and low-emphasis
controls), and `selectionSurface` (the selected navigation row — moss-based,
because selection is an app meaning, not a borrowed system blue). Every token
is defined for both light and dark appearance in one `palette(_:_:)` switch,
with light/dark contrast verified in `ThemeContrastTests`.

### Appearance preference (System / Light / Dark)

`AppearanceMode` (`App/AppPreferences.swift`) is a real, wired preference, not
aspirational: `AppPreferences.appearance` persists it under
`appearance.mode`/`AppPreferences.appearanceUserDefaultsKey`, missing or
malformed values resolve to `.system` (no migration prompt for existing
installs), and `HushnoteApp` reads the same `@AppStorage` key at the root scene
to compute `preferredColorScheme` (`nil` / `.light` / `.dark`) applied to both
the main window and the About window. Settings exposes it through
`AppearanceModeControl`, a `HushnoteSegmentedControl` bound to the same
`@AppStorage` key — there is deliberately one persistence path shared by the
root scene and Settings' observing control, not two.

### Surface ownership: one continuous detail canvas

`AppShellView` is the sole owner of the split-view **detail** background,
including the failed-recording banner: it applies exactly one `.paperBackground()`
from beneath the header through the scrollable body, and individual routes
(Models, Storage, Settings, the meeting library, the workspace) own only their
own content geometry inside that paper, never a second background layer. The
sidebar instead uses `.utilityCanvas()`/`navigationSurface`, kept visually
distinct from, but adjacent to, the detail paper, separated by exactly one
`HushnoteTheme.rule` divider.

**Never nest `.utilityCanvas()` inside `.paperBackground()` (or vice versa) on
the same route.** Applying both produces a visible seam — a band where the
generic app canvas shows through between a route's header, tabs, and body —
which is precisely the bug the 2026-08-24 unified-sidebar-and-canvas redesign
(`docs/plans/2026-08-24-unified-sidebar-meeting-canvas-design.md`) exists to
remove. `AdaptivePageScaffold` on a utility page and the shell's
`.paperBackground()` on a meeting route are each a single ownership level;
picking the wrong one for a given route reintroduces the dark/light moat.

### Window toolbar ownership

**The sidebar toggle is not a toolbar item.** Every toolbar placement macOS
offers inside a `NavigationSplitView` is resolved against a *column* edge:
`.navigation` re-homes into whichever column is showing, and `.automatic` is
measured from the detail column's leading edge. Either way the toggle slides
horizontally the moment the sidebar collapses. `AppSidebarToggle` is therefore
hosted by `SidebarToggleTitlebarAccessory`, an
`NSTitlebarAccessoryViewController` with `layoutAttribute = .leading`. The
window positions that accessory, immediately after the traffic lights, so the
control holds one constant position in both states. Do not move the toggle
back into `.toolbar`.

Two details are load-bearing:

- `.toolbar(removing: .sidebarToggle)` must be applied to **the sidebar column
  itself**, at the `SidebarNavigationView(...)` call site inside
  `NavigationSplitView`. Applied to a container that merely *wraps* the split
  view it silently does nothing, and the app renders two sidebar buttons side
  by side — the stock one and ours.
- `AppSidebarToggle` carries no `keyboardShortcut`. A view hosted in a titlebar
  accessory is outside the key window's menu responder chain, so the shortcut
  would look present and never fire. The View menu owns it:
  `CommandGroup(after: .sidebar)` in `App/HushnoteApp.swift` posts
  `.hushnoteToggleSidebar`, and the shell performs the same transition.

`AppShellWindowToolbar` remains the sole owner of what is left in the toolbar
(the collapsed-state New Transcription button and search), wrapping
`NavigationSplitView` in a concrete `ZStack` rather than being applied to it.
`WindowToolbarOwnershipTests` guards all of this by parsing
`AppShellView.swift`'s source directly — SwiftUI exposes no toolbar-placement
introspection, and `AppShellView` cannot be constructed in a test because
`AppCoordinator` requires the real database.

### Shared component vocabulary

`UI/Components.swift` is the app's control vocabulary; new UI composes these
rather than reaching for raw platform-styled controls (`Button()` with no
style, a bare `TextField`, `.toggleStyle(.switch)`, `Picker` with
`.segmented`), because that vocabulary is what keeps every screen off
platform-blue and inside the paper/ink/vermilion palette:

- `HushnoteButtonStyle` / `View.hushnoteButton(_:)` — `.primary` (ink fill,
  white label), `.secondary` (ruled outline), `.quiet` (no fill), `.recording`
  (vermilion fill), `.destructive` (vermilion label and border, no fill). A
  capsule shape throughout. Deliberately an extension on `View`, not `Button`:
  the narrower form could not be applied after `.disabled()`, nor to a `Menu`,
  which is why ~30 call sites had fallen back to `.bordered`.
- `HushnoteFieldStyle` — the standard bordered `TextFieldStyle` — and
  `View.hushnoteField()` for the controls a `TextFieldStyle` cannot reach:
  `SecureField`, `TextEditor`, `TextField(axis:)`. The two apply the chrome
  separately because `TextFieldStyle._body` is nonisolated and cannot route
  through a `ViewModifier` under strict concurrency; `HushnoteFieldMetrics`
  holds the shared measurements so they cannot drift.
- `HushnoteToggleStyle` — a moss/rule capsule switch built on a plain
  `Button`, not `.toggleStyle(.switch)`, so it never carries a system tint.
- `HushnoteSegmentedControl<Selection, Label>` — a 2–4 option chooser built
  from real `Button`s (keyboard- and VoiceOver-reachable) rather than
  `Picker(.segmented)`, so selection stays on `selectionSurface`/moss instead
  of system blue. Used for the Appearance choice among others.
- `RecordingPill` — the one recording-state control, shared by the floating
  panel, sidebar footer, and workspace header so they cannot again disagree
  about wording (see `RecordingStatusText`).
- `LevelMeter` / `SystemLevelMeter` — the audio-level bars; `SystemLevelMeter`
  is a leaf specifically so its high-frequency `systemLevel` observation
  dependency never reaches a parent body that also renders the live
  transcript.
- `TimestampButton` — a meeting-relative timestamp that renders as a plain
  label when constructed with no action, and as a real button only when one is
  supplied, so a timestamp with nowhere to jump never pretends to be
  interactive.

Structural components, each of which replaced several hand-written copies:

- `HushnoteRule` / `View.hushnoteBottomRule(opacity:)` — the app's one
  hairline. Never use `Divider()` for a layout rule: it renders the platform
  separator colour, a cooler grey than `rule` that does not track the palette.
  `Divider()` inside a `Menu` is a real menu separator and stays.
- `HushnoteEyebrow` — the one section label. Pass a sentence-case string; it
  uppercases via `textCase`, because a literal `"CLEANUP INVENTORY"` cannot be
  translated. Tracking comes from `HushnoteTheme.eyebrowTracking`; it had been
  authored at 0.7, 0.75, 1.2 and 1.3 across four files.
- `HushnoteSection` — eyebrow, optional trailing action, content.
- `HushnoteInventoryRow` with `HushnoteRowDate` / `HushnoteRowIdentity` — the
  ruled row behind meetings, deleted meetings, search results, models and
  storage entries. It owns its own bottom rule, so call sites must not
  interleave separators in a `ForEach`. `InventoryRowLayout` is the pure seam
  holding its compact adaptation, and is what `InventoryRowLayoutTests` covers.
- `HushnoteSelectableRow` — the selectable row behind the sidebar, the provider
  inventory and search results, which had drawn the same affordance at corner
  radius 6, 7 and 8. Counts and menus belong in its `trailing` slot, outside
  the button; the sidebar reserves that slot on every row so folder counts and
  Library counts land on the same axis.
- `HushnotePageHeader` — title, subtitle and optional trailing actions, with
  its own bottom rule. Every route uses it.
- `HushnoteEmptyState` (+ `HushnoteGlyph`) — replaces `ContentUnavailableView`,
  which is unmistakably a system control on a page that is otherwise not.
- `HushnoteBadge`, `HushnoteStatusLine`, `HushnoteMetric`,
  `HushnoteDisclosure`, `HushnotePathDisclosure`.

### Testing seams

Device- and network-bound work sits behind injectable protocols
(`SystemAudioCapturing`, `SpeechModelDownloading`, `FinalSpeechDecoder`,
`AgentProcessRunner`, `StorageAccounting`, `MeetingAudioM4AConverting`). Tests
drive those, never the real thing.

**`AppCoordinator` cannot be unit-tested.** Its initializer calls `fatalError`
if it cannot open the real SQLite database, and no test constructs one. Anything
that must be verified has to be pushed down into a pure seam underneath it;
coordinator wiring itself is verified only by reading.

Pure policy/decision types sit beside their views or coordinator and carry
their own tests, independent of any view hierarchy — e.g. `AdaptiveLayoutPolicy`
(`AdaptiveLayoutPolicyTests`), `SidebarScrollerConfiguration`
(`SidebarScrollerConfigurationTests`, which asserts on the `.navigation`
preset only — nothing covers the `NSViewRepresentable` probe's behaviour),
`TerminationGuard` (`TerminationGuardTests`), `RecordingStorageCleanupPolicy`,
`MeetingAudioRetentionPolicy`, and `FloatingPanelPositioning`
(`FloatingPanelPositioningTests`). `WindowToolbarOwnershipTests` is the one
exception that cannot be a behavioral test — SwiftUI toolbar placement has no
introspectable seam — so it asserts on `AppShellView.swift`'s source text
directly; treat a failure there as a real ownership violation, not test noise
to silence.

## Constraints that are load-bearing

Each of these encodes a bug that already happened. Changing the surrounding code
without understanding them will reintroduce it.

**Never hand SwiftUI an index-derived binding into `state.transcript`.**
`ForEach($state.transcript)` produces per-element bindings that resolve by
position. The array is replaced wholesale in four places in `AppCoordinator`,
and the final pass mints entirely new segment identifiers. A focused `TextField`
reading back through a stale index traps in `Array._checkSubscript` — a real
crash in a real user's crash report. Rows take their value **by value** and hold
their own `@State` draft; edits resolve by identity at the moment of the edit.

**Whisper control tokens are stripped at three layers.** `skipSpecialTokens:
true` on both `DecodingOptions`, `WhisperSpecialToken` sanitizing engine output,
and again at render/grouping time. Keep all three — the option is one library
default away from flipping back, and the text is persisted, exported, and fed to
summarizers, so one leak is permanent and visible everywhere.
`WhisperSpecialToken`'s token-body check deliberately requires an unbroken run of
`[A-Za-z0-9._-]` so legitimate speech containing `<`, `|`, or `<| ... |>` with
spaces survives. Do not widen it, and never strip tokens with SQL `replace()`.

**`AVAudioFile(forWriting:)` truncates at open, before a single frame is
written.** Each capture attempt therefore allocates its own take
(`system-<n>.caf`) so a retry cannot destroy the previous attempt's audio.
`AudioPipeline.longestTake(in:)` is what picks the one worth keeping.

**Scope FTS-triggering updates.** The `v5` trigger's delete is a full scan of the
FTS5 shadow tables, so a migration touching every row is quadratic-ish on a long
history. SQLite also fires `UPDATE OF` on a column's *presence in the SET list*,
not on its value changing — name only the columns that actually changed. The
`v6_repair_transcript_pollution` migration and `MeetingStore.upsertSegments`
(`updateChanges(db, from:)`) both apply this: a row whose repair or upsert is a
no-op is never written at all, and a write names only the columns that changed.

**Driving the agent CLIs.** Only inspecting commands are safe to run:
`--help`, `--version`, `models`, `agent list`, `providers list`, `auth status`.
Never send a prompt (`claude -p`, `codex exec`, `opencode run` with text) — it
spends the user's quota and can execute tools. Never run anything that changes
auth. Tests must parse fixture strings, never invoke a real CLI. Model discovery
differs sharply per CLI: only `opencode models` enumerates; Claude's names are
buried in `--model`'s help text; Codex enumerates nothing. A typed model field
must always work, because for Codex it is the only control.

**Never apply both `.utilityCanvas()` and `.paperBackground()` to a route and
its ancestor.** Doing so leaves the generic app `canvas` token visible as a
band between that route's header, tabs, and body. `AppShellView` owns exactly
one continuous `.paperBackground()` per detail route; a route composes its own
content inside that, never a second background. See "Surface ownership" above.

**The sidebar toggle lives in a `.leading` titlebar accessory, not in the
toolbar.** Every toolbar placement inside `NavigationSplitView` is measured
from a split-view column edge, so a toolbar-hosted toggle drifts sideways when
the sidebar collapses. Separately, `.toolbar(removing: .sidebarToggle)` only
suppresses the stock item when applied to the sidebar *column*; applied to a
wrapper around the split view it does nothing and two toggles render. See
"Window toolbar ownership" above.

## Design

`.impeccable.md` holds the project's design context and is authoritative for UI
work: a calm, precise, private "quiet editorial workspace" — warm paper
neutrals, ink typography, a single vermilion recording accent, light mode with a
complete dark appearance via semantic materials. Explicitly avoid neon AI
gradients, glass dashboards, uniform card grids, and generic chatbot styling.
Use `HushnoteTheme` tokens (paper, ink, vermilion, moss, rule, canvas,
navigationSurface, controlSurface, selectionSurface); never raw colors.

`docs/plans/` holds dated design documents for major features. The three
current ones — `2026-08-23-folders-responsive-redesign-design.md`,
`2026-08-24-unified-sidebar-meeting-canvas-design.md` and
`2026-08-25-notes-and-transcript-reading-design.md` — describe the folder/
Recently Deleted information architecture, the single-detail-canvas surface
contract, and the workspace reading spread respectively. Each supplements
rather than replaces the one before it.
