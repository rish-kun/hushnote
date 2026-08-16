# Local-First macOS Meeting Transcriber Design

This document records the approved design. The complete implementation specification is the plan approved on 2026-08-12.

## Product

A personal Apple-Silicon macOS app that captures microphone and system audio without a meeting bot, transcribes both locally in realtime, refines and diarizes the result after the meeting, and generates evidence-backed notes through an explicitly selected local or cloud model.

## Architecture

- Native SwiftUI modular monolith targeting macOS 15 and Apple Silicon.
- ScreenCaptureKit provides synchronized system and microphone capture into separate crash-recoverable local tracks.
- WhisperKit provides live and final Core ML ASR; FluidAudio provides native VAD and post-meeting diarization.
- GRDB/SQLite stores meetings and revision-aware transcript state; Keychain stores provider keys.
- Insight providers share a structured contract for local llama.cpp, OpenAI, Anthropic, and ChatGPT via Codex App Server.

## Product constraints

- Recording requires a consent confirmation and persistent indicator.
- Audio is recoverable during processing but deleted after successful finalization by default.
- No transcript or audio leaves the Mac without an explicit provider action.
- V1 excludes calendar automation, cloud sync, collaboration, billing, and App Store distribution.

## Validation

The prototype must compile and test as a native macOS application, record separate local tracks, survive interrupted sessions, revise provisional transcript text safely, search/export completed meetings, and isolate provider credentials and failures.

