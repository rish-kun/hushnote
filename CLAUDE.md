# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
has repeatedly produced false regression reports. Roughly 7 files use XCTest;
the other ~50 use swift-testing.

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
  `DatabaseMigrations.swift`, currently through `v6`.
- **`App/`** — `AppCoordinator` (the hub that owns every pipeline and writes to
  view state), `AppViewState` (`@Observable`, the single source of UI truth),
  `HushnoteTheme`, `MeetingExporter`.
- **`UI/`** — SwiftUI views only. Pure decision logic lives in testable
  `enum` policy types beside the views (`ModelListPolicy`,
  `TranscriptEditPolicy`, `TranscriptGrouping`, `LiveTranscriptionPolicy`), which
  is how UI behaviour gets covered without driving a view hierarchy.

### Testing seams

Device- and network-bound work sits behind injectable protocols
(`SystemAudioCapturing`, `SpeechModelDownloading`, `FinalSpeechDecoder`,
`AgentProcessRunner`). Tests drive those, never the real thing.

**`AppCoordinator` cannot be unit-tested.** Its initializer calls `fatalError`
if it cannot open the real SQLite database, and no test constructs one. Anything
that must be verified has to be pushed down into a pure seam underneath it;
coordinator wiring itself is verified only by reading.

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
not on its value changing — name only the columns that actually changed.

**Driving the agent CLIs.** Only inspecting commands are safe to run:
`--help`, `--version`, `models`, `agent list`, `providers list`, `auth status`.
Never send a prompt (`claude -p`, `codex exec`, `opencode run` with text) — it
spends the user's quota and can execute tools. Never run anything that changes
auth. Tests must parse fixture strings, never invoke a real CLI. Model discovery
differs sharply per CLI: only `opencode models` enumerates; Claude's names are
buried in `--model`'s help text; Codex enumerates nothing. A typed model field
must always work, because for Codex it is the only control.

## Design

`.impeccable.md` holds the project's design context and is authoritative for UI
work: a calm, precise, private "quiet editorial workspace" — warm paper
neutrals, ink typography, a single vermilion recording accent, light mode with a
complete dark appearance via semantic materials. Explicitly avoid neon AI
gradients, glass dashboards, uniform card grids, and generic chatbot styling.
Use `HushnoteTheme` tokens (paper, ink, vermilion, moss, rule); never raw colors.

`docs/plans/` holds dated design documents for major features.
