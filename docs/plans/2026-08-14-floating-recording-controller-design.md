# Floating Recording Controller and Reliable Finalization

## Goals

- Present the recording controller as a movable picture-in-picture panel above all applications.
- Keep the controller available across macOS Spaces and full-screen applications.
- Preserve its last valid screen position.
- Prevent Stop from waiting indefinitely for live Whisper model setup.
- Make every finalization stage visible and recoverable without risking recorded audio.

## Floating controller

Use a borderless AppKit `NSPanel` containing the existing SwiftUI `RecordingPill` through an
`NSHostingView`. The panel is non-activating, floats above ordinary windows, joins every Space,
and participates as a full-screen auxiliary window. Its clear background and shadow preserve the
existing pill appearance. The panel is movable by dragging its background. Its position is stored
in user defaults and constrained to a connected display when restored.

One application-owned controller observes `AppViewState.recordingPhase`. It creates and shows the
panel for Preparing, Recording, Paused, and Finalizing, and hides it for Idle and Failed. The
in-window overlay is removed so only one set of controls exists.

## Finalization lifecycle

Stopping audio remains the highest-priority first action. After the CAF writer closes, the meeting
and track metadata are persisted immediately. Cancelling live ASR setup must not be followed by an
unbounded wait. A session generation token prevents a cancelled or late task from installing an
engine or mutating a later meeting.

Finalization reports these stages through application state: saving audio, stopping live ASR,
loading the final model, transcribing, identifying speakers, and generating the summary. Operations
that can fail retain the CAF and move the meeting to a recoverable state with a retry action. The
full-quality final ASR pass remains enabled.

## Error handling

- A late live-model task is discarded when its session token no longer matches.
- Finalization errors preserve recording metadata and raw audio.
- The UI distinguishes active progress from a recoverable failure.
- Restart recovery continues to discover and register CAF artifacts.

## Verification

- Unit-test finalization stage state and stale-session rejection.
- Exercise Stop while live model setup is still running.
- Verify panel visibility for every active phase and hiding for terminal phases.
- Verify panel position clamping and persistence.
- Run the complete Swift test suite.
- Build the signed development app and use computer control to verify panel movement and Stop.

