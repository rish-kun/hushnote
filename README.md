<img src="Resources/Hushnote.iconset/icon_256x256.png" width="128" alt="Hushnote app icon">

# Hushnote

A local-first meeting notebook for Apple Silicon Macs. It records the audio your
Mac is playing, transcribes it on-device, attributes speakers, and keeps the
result in a workspace built for reading and writing rather than for watching a
dashboard.

Nothing leaves the machine unless you choose a cloud summarizer or publish a
share link, and both are explicit, per-use decisions.

## What it does

- **Records system audio** — whatever is coming out of your Mac, so a call in
  any app is capturable without a virtual audio device.
- **Transcribes live, then again properly.** A streaming decoder gives you text
  during the meeting; an accuracy-first full-file pass replaces it after Stop.
- **Labels speakers** by diarizing the finished recording.
- **Lets you write while it listens.** Notes are a first-class page, available
  during capture, and `⇧⌘T` stamps the current transcript time at the caret so
  a thought stays anchored to the sentence that prompted it.
- **Summarizes with citations** — every claim points back at the transcript
  segment it came from, through whichever model provider you pick.
- **Answers questions** about a meeting, with the same citation discipline.
- **Organizes** meetings into flat folders, with Unfiled and a 30-day Recently
  Deleted.
- **Exports** to Markdown, SubRip, or JSON, and the recording itself to M4A or
  the original CAF.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 26 or newer (to build)

## Running it

```sh
./scripts/build-app.sh release
open .build/Hushnote.app
```

Or, for development, `swift run Hushnote`.

The first launch asks for **System Audio Recording Only** — not screen
recording. Speech models are downloaded only after you pick one on the Models
screen; there is no bundled model and no download before you ask for one.

## How it works

Three pipelines run independently. Only `App/` knows about all of them.

### Capture — `AudioPipeline/`

An actor owning one capture session, recording system audio through **CoreAudio
process taps** (`AudioHardwareCreateProcessTap`, `CATapDescription`). Audio is
normalized to 48 kHz mono LPCM and written to a CAF incrementally, so a crash
or a force-quit still leaves a playable file rather than a zero-byte one.

Each capture attempt writes its own numbered take. `AVAudioFile(forWriting:)`
truncates the moment it opens — before a single frame is written — so a retry
that shared a filename would destroy the audio it was retrying.

### Speech — `SpeechPipeline/`

WhisperKit, with two decoders for two different jobs:

- a **live streaming engine** during capture, emitting stable-prefix revisions
  so the text settles instead of flickering;
- **`WhisperKitFinalTranscriber`**, an accuracy-first pass over the whole file
  after Stop, which re-mints every segment.

FluidAudio then diarizes the finished recording and attributes speakers.

### Insight — `InsightPipeline/`

Pluggable summarizers behind one protocol, chosen per install:

| Provider | Transcript leaves the Mac |
|---|---|
| Managed local `llama-server` | No |
| OpenAI API | Yes |
| Anthropic API | Yes |
| ChatGPT via Codex App Server | Yes |
| `claude` / `codex` / `opencode` CLIs | Depends on the CLI's own account |

Summaries and answers are **cited**: a claim that cannot be tied to a transcript
segment is rejected rather than shown.

### Storage — `Persistence/`

GRDB over SQLite, with numbered migrations through `v9`. Transcript search is
FTS5. User edits to transcript text survive re-runs of the final pass, and
insight snapshots keep provider-run history.

Audio is deleted after successful finalization unless you turn on retention.

## The meeting workspace

Four tabs over one document: **Notes**, **Transcript**, **Summary**, **Ask**.

Notes and Transcript share one reading geometry — the same measure and margins —
so switching tabs never slides the text sideways. The transcript is chaptered,
with an index rail beside it at wide widths; the reading column is capped at 704
points because that is the width that makes it readable, and surplus window goes
to the page margin rather than into the line length.

Summary and Ask are available once there is a transcript to cite, but not during
live capture: the final pass is about to re-mint every segment identifier, and
citations generated against provisional text would all dangle.

## Sharing

A meeting can be published to a link, choosing per share which of transcript,
notes, and summary travel — content you exclude never leaves the Mac. A share
can carry a password, and can be revoked. Ownership is a device token in the
Keychain; there are no accounts.

**Status: the Mac side is complete; the web app that serves the links is not
built yet.** `web/` currently holds only pinned dependencies, so no link can
actually be created. The design is specced in
`docs/plans/2026-08-25-meeting-share-links-design.md`.

## Privacy defaults

- Raw audio stays local, and is removed after successful finalization unless
  retention is enabled.
- API credentials live in the data-protection Keychain, never in preferences.
- Cloud providers receive transcript text only, and only after you select one.
- Published shares are readable by the server; a password is an access check,
  not encryption. The spec states this plainly rather than implying otherwise.

## Development

```sh
swift build                              # zero warnings is the standard
swift test
swift run Hushnote
./scripts/build-app.sh                   # debug bundle -> .build/Hushnote.app
```

Two test frameworks run: `swift test` prints a separate count for XCTest
(`Executed N tests`) and for swift-testing (`Test run with N tests`), and **the
real total is their sum**. Quoting one line has repeatedly produced false
regression reports.

Incremental builds do not re-emit warnings for unchanged files, so force a full
recompile before claiming a clean build:

```sh
find Sources Tests -name '*.swift' -exec touch {} + && swift build
```

One warning is baseline and not ours: FluidAudio's `benchmark.md` unhandled-file
warning from the dependency checkout.

`AGENTS.md` is the canonical guide to the architecture and to the constraints
that are load-bearing — each one encodes a bug that already happened. Read it
before changing the pipelines, the workspace layout, or the termination guard.
Design documents for major features live in `docs/plans/`.

## Status

A developer-signed prototype. Deterministic tests cannot stand in for hardware
behaviour: real call-app capture quality, long-session drift, thermals, model
realtime factor, permission revocation, and sleep/wake all still need checking
on actual Macs.
