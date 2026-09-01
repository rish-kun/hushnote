import Foundation

/// The ownership stamp attached to an audio event observer.
///
/// AudioPipeline's event stream can still contain buffered values after a
/// capture has stopped. The coordinator must therefore validate the observer's
/// meeting and live-session generation before allowing any value to reach UI,
/// speech, or persistence state.
struct AudioEventObservationIdentity: Equatable, Sendable {
    let meetingID: UUID
    let generation: UUID
}

enum AudioEventObservationPolicy {
    /// Returns whether an event observer still owns the state it is about to
    /// mutate. Pipeline identity is checked separately because an actor's
    /// instance identity cannot be represented by this pure policy.
    nonisolated static func accepts(
        observer: AudioEventObservationIdentity,
        current: AudioEventObservationIdentity?,
        isCurrentPipeline: Bool
    ) -> Bool {
        isCurrentPipeline && current == observer
    }
}
