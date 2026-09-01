# Floating panel sizing and microphone controls

## Problem

The expanded floating recording panel can retain the compact panel's height.
SwiftUI has already switched hierarchies, but AppKit can read the hosting view's
old fitting size before the expanded layout commits, leaving the lower controls
clipped.

The expanded panel also reports microphone health without providing a control.
Although the coordinator and audio pipeline support rotating microphone takes
during capture, that capability is not reachable while the user remains in a
meeting application.

## Design

The floating panel uses deterministic compact and expanded content sizes. The
controller remains the sole owner of the `NSPanel` frame and preserves its top
edge while switching sizes, then clamps the result to the active display. The
view reports expansion intent instead of asking AppKit to infer the new size
from a transient SwiftUI fitting measurement.

The expanded source row includes a Hushnote-styled microphone toggle beside
microphone health. Turning the microphone off closes the current microphone
take while system audio continues. Turning it on opens a new immutable take at
the current captured-media clock. The control exposes a working state while the
serialized coordinator request is in flight and refuses duplicate clicks.

Failure is source-specific. If permission, selection, or hardware setup fails,
system capture remains active, microphone health becomes unavailable, and the
control returns to an actionable state. The desired preference remains enabled
so the UI can describe the expected source and offer another attempt.

## Testing

- Pure sizing policy tests cover compact and expanded dimensions.
- Positioning tests verify expansion preserves the top edge and remains inside
  the selected screen.
- Interaction-policy tests cover enabled, disabled, and configuring labels and
  disabled states.
- Pipeline/coordinator tests verify off closes a take, on opens a fresh take,
  and repeated requests cannot resurrect stale configuration work.
- The full dual-framework test suite and a forced full Swift build remain the
  release gate.
