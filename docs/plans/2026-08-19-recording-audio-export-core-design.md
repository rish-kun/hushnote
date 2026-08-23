# Recording and Audio Export Core

Keep the crash-recoverable 48 kHz mono CAF as the recording source of truth. Export either that original file or a broadly playable AAC M4A without deleting or rewriting the source. Export work runs asynchronously, validates that the source contains audio, stages output beside the destination, and only replaces the destination after the copy or conversion succeeds.

Make Core Audio's aggregate-device preparation deterministic under unit tests by moving readiness polling and transient start retries behind closure-based helpers. Production keeps the same HAL calls and delays; tests supply probes, start results, and a no-op sleeper.

Audio retention belongs to the meeting snapshot taken when recording starts. Later changes to the global preference affect later meetings only. Finalization therefore decides deletion from the stored meeting's `retainsAudio` value, while export availability should ultimately be confirmed from the file on disk.

Verification covers readiness and retry order, terminal failures, missing and empty sources, original CAF copying, M4A readability and duration, cancellation, atomic destination preservation, and the retention truth table.
