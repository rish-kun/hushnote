import Foundation

/// Guards source-health observations against a late success overwriting a
/// stronger failure. A new take explicitly emits `.arming`, which resets the
/// gate and allows its first durable write to verify that replacement.
enum RecordingSourceHealthPolicy {
    nonisolated static func accepts(
        observed: AudioSourceCaptureState,
        current: RecordingSourceLifecycle
    ) -> Bool {
        guard case .healthy = observed else { return true }
        switch current {
        case .disabled, .unavailable, .degraded:
            return false
        case .arming, .healthy, .silent, .reconnecting:
            return true
        }
    }

    /// Level callbacks are evidence for silence, not source-health
    /// transitions, on the system track. Its lifecycle is verified by a
    /// durable write and must not flap with ordinary silence or volume.
    nonisolated static func lifecycleAfterLevel(
        source: AudioSource,
        current: RecordingSourceLifecycle,
        audible: Bool
    ) -> RecordingSourceLifecycle {
        guard source != .system else { return current }
        switch current {
        case .disabled, .unavailable, .reconnecting, .degraded:
            return current
        case .arming, .healthy, .silent:
            return audible ? .healthy : .silent
        }
    }
}
