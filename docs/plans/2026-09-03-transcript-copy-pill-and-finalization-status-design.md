# Transcript copy, reliable floating panel, and finalization status

## Decisions

The user delegated product decisions and approval for this work. Three implementation approaches were considered for each area:

- Clipboard export could duplicate formatting, copy the full meeting document, or reuse one canonical transcript formatter. Hushnote will reuse a transcript-only Markdown formatter so the action says exactly what it copies and file/clipboard output cannot drift.
- The floating panel could grow based on SwiftUI's fitting size, use a larger fixed frame, or keep deterministic sizes with an atomic screen-clamped transition. Hushnote will retain deterministic geometry and perform one native frame mutation after SwiftUI commits the expanded state.
- Finalization could keep using the global recording phase, infer state from the meeting row, or project durable queue jobs into meeting-scoped UI state. Hushnote will use the durable job projection because capture and final processing are independent and multiple sessions may belong to one meeting.

## Copy transcript as Markdown

Completed meetings expose `Copy transcript as Markdown` alongside document export. The copied document contains the meeting title and a `Transcript` section with timestamped, speaker-attributed paragraphs. It does not include summaries, decisions, action items, or open questions.

The Markdown transcript body is a single formatter reused by clipboard and Markdown file export. Clipboard access sits behind a small seam rather than being embedded in SwiftUI. The action is disabled when no transcript exists and shows a short `Copied` confirmation without changing workspace layout.

## Floating recording panel

Expansion and collapse become state-driven. Buttons change only SwiftUI expansion intent; an observed state transition notifies the controller after the view has invalidated. The controller retains its hosting view, gives it an explicit autoresizing frame, and changes the panel to one computed target frame using a single `setFrame` call. The frame preserves the compact pill's top edge where possible and clamps both size and origin to the selected display's visible frame.

The expanded header, including Collapse, is always pinned inside the panel. Detail content may adapt or scroll vertically, but it cannot push the header outside the native content bounds. If a display is physically too small for the expanded dimensions, the policy uses the largest safe size while keeping the header accessible. A phase transition out of capture forces compact geometry.

Tests cover the exact policy dimensions, atomic target-frame math, display-edge clamping, undersized displays, stale expansion callbacks, and the absence of the old two-step content-size/origin mutation.

## Meeting-scoped finalization status

Stopping first durably closes and queues audio, then capture returns to idle so another meeting may start. The queued job remains visible through a meeting-scoped projection in `AppViewState`; it is never represented by the global recording phase.

A pure presentation policy aggregates all session jobs under a meeting. Running work outranks queued work, which outranks failed work; completed jobs disappear once no work remains. Status copy is explicit:

- `Final transcription queued` — recording is safe, with ETA when available.
- `Transcribing recording`
- `Identifying speakers`
- `Updating combined transcript`
- `Final transcription needs attention` — audio is safe and Retry is available.

The selected meeting shows a persistent status banner above its completed workspace. Sidebar/library rows show a compact status and retain their date rather than silently replacing it. Progress and ETA update from the durable finalization queue, survive `markFinished()`, and remain scoped correctly while another meeting records.

## Verification

Pure policies cover Markdown output, clipboard feedback, panel target geometry, finalization aggregation, copy/tone/progress, and meeting scoping. Persistence and queue tests cover multiple sessions and transitions. The full Swift build and both test frameworks must pass; a UI launch is used only if it can inspect the panel without risking an active recording.
