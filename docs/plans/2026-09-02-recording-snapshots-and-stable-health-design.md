# Recording snapshots and stable system-audio health

## Goal

Make the floating recording panel calmer and more useful during a meeting. System-audio health should verify capture once per take instead of oscillating with ordinary silence, and the expanded panel should let the user save a visual snapshot without interrupting recording.

## System-audio verification

Each system-audio take begins in `arming`. The first system-audio buffer that is successfully written verifies the take and moves the visible state to `healthy`. Ordinary low levels and silence do not demote that state. The level meter remains live, but the health label is stable.

Real transport and persistence problems still surface: missing callbacks, dropped buffers, writer failure, device loss, and format changes may move the source into a warning or reconnecting state. A recreated take returns to `arming` and verifies again from its first successfully written buffer. Microphone health remains independently dynamic because the user can enable, disable, or retry that source during capture.

The event reducer must prevent a late generic readiness event from overwriting a stronger failure state. Recording startup is verified by a system-audio buffer, not by a microphone buffer or merely by successful device setup.

## Snapshot capture

The expanded recording panel adds a `Snapshot` action in its controls row. A click captures one still image of the display containing the mouse pointer. Hushnote's own application windows, including the floating panel, are excluded from the capture. Audio capture, transcription, timers, and panel visibility continue unchanged.

Screen capture uses ScreenCaptureKit's one-shot screenshot API rather than a continuous stream. Screen Recording permission is requested lazily on the first snapshot attempt and is kept separate from System Audio Recording and Microphone permissions. Permission denial produces a calm, actionable message with a route to System Settings. Snapshot failures never affect the recording lifecycle.

The action has deterministic states: `Snapshot`, `Saving…`, and a brief `Saved` confirmation. While a request is in flight, duplicate requests are ignored. The fixed panel sizing contract remains authoritative; source diagnostics stack vertically so long microphone states and actions do not clip.

## Persistence and timeline

PNG files are staged and atomically installed under:

`Application Support/Hushnote/Screenshots/<meeting UUID>/<snapshot UUID>.png`

A dedicated database record stores the snapshot ID, meeting ID, recording-session ID when available, relative file path, audio sample-clock timestamp, wall-clock capture time, display ID, and pixel dimensions. The sample clock is read immediately before screen capture so the attachment remains anchored to captured audio even if image encoding takes time.

Soft deletion preserves screenshots. Permanent meeting deletion removes screenshot files before deleting their database rows so a filesystem failure leaves the meeting recoverable for retry. Screenshot bytes are accounted for as meeting data by storage reporting.

## Architecture and testing

Screen access and image production sit behind injectable protocols. A capture service owns display selection, Hushnote exclusion, permission handling, PNG staging, validation, and atomic installation. `AppCoordinator` only snapshots active meeting/session/timeline context and coordinates the service and store.

Pure policies cover availability, display selection, button state, and system-health transitions. Tests use fake capture and permission implementations, migration round trips, deletion cleanup, stale-event protection, and deterministic panel-size assertions. Build and tests must not launch or restart the app; visual verification is a separate final step only if necessary.
