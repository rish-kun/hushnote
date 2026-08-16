# Direct Recording Controls

## Goal

Make the recording lifecycle obvious and available from the primary window without a consent or setup modal.

## Interaction

- Idle: show a prominent **Start Recording** control in the toolbar, empty state, and menu bar.
- Preparing: keep the same control visible as disabled **Starting…** feedback.
- Recording/paused: replace it with a prominent red **Stop Recording** control. Pause remains secondary.
- Finalizing: show disabled **Finalizing…** feedback while the captured audio is processed.
- Failure: return to a usable **Start Recording** control and show the concrete failure plus a recovery action.

Start uses the existing draft defaults. Detailed title, mode, template, language, and model choices remain available through an optional setup action; they never block recording.

## State and capture guarantees

The coordinator remains the sole owner of start/stop. The database meeting is created before capture, system audio is written before inference, and any partially started pipeline is stopped on failure. Stop always stops ScreenCaptureKit before final ASR and diarization.

## Verification

Add deterministic state/control tests where possible, compile the SwiftUI target, run the full suite, package the app, and visually inspect idle, preparing, recording-control, and failure states.
