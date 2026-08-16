# Hushnote

Hushnote is a local-first meeting transcriber for Apple Silicon Macs. It records system audio, produces a revision-aware live transcript, finalizes speaker-labelled notes locally, and can generate cited meeting insights through a user-selected model provider.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 26 or newer

## Development

Open `Package.swift` in Xcode or run:

```sh
swift build
swift test
swift run Hushnote
```

To create a launchable, ad-hoc signed application bundle:

```sh
./scripts/build-app.sh release
open .build/Hushnote.app
```

The first launch requires System Audio Recording Only access. Model files are downloaded only after explicit selection.

## Privacy defaults

- Raw audio stays local and is removed after successful finalization unless retention is enabled.
- API credentials are stored in macOS Keychain.
- Cloud insight providers receive transcript text only and run only after explicit selection.

## Implemented prototype flow

- Create a persistent meeting note first, write free-form notes, then start transcription from that workspace.
- Keep a global recording pill visible across the app with elapsed time, source levels, pause, and immediate Stop.
- Stop capture before model work, then show Finalizing while ASR, diarization, and configured summary generation complete.
- ScreenCaptureKit system-audio capture with crash-recoverable CAF writing.
- WhisperKit live decoding with stable-prefix revisions, followed by a selectable full-file final pass.
- FluidAudio post-meeting diarization and source-aware speaker attribution.
- GRDB/SQLite history, migrations, user-edit preservation, FTS5 transcript search, insight snapshots, and provider-run history.
- Cited summaries and Q&A through a managed local `llama-server`, OpenAI API, Anthropic API, or ChatGPT via Codex App Server.
- Markdown, SRT, and JSON export from the completed transcript workspace.

This is a developer-signed prototype. Real Zoom/Meet capture quality, long-session drift, thermals, model realtime factor, permission revocation, and sleep/wake behavior still require the hardware acceptance matrix described in `docs/PRODUCT_ARCHITECTURE.md`; deterministic software tests cannot substitute for those Mac-level checks.
