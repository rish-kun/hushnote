import Foundation
import Testing
@testable import Hushnote

/// The meeting window has to follow the recording, not the database. While a
/// meeting is being captured its workspace must show the live controls, the
/// level meter, and the "live transcription is unavailable" notice — the only
/// place that notice is ever rendered. Routing unconditionally to the completed
/// workspace made all of it unreachable and told the user there was no
/// transcript while audio was recording perfectly.
@Suite("Meeting workspace routing")
struct MeetingWorkspaceRoutingTests {
    private let meetingID = UUID()

    @Test("A meeting being captured shows its live workspace")
    func capturingRoutesToActive() {
        for phase in [RecordingPhase.recording, .paused, .preparing] {
            #expect(
                MeetingWorkspaceRoute.route(
                    phase: phase,
                    activeMeetingID: meetingID,
                    meetingID: meetingID
                ) == .active
            )
        }
    }

    @Test("Finalizing is neither live capture nor a finished transcript")
    func finalizingRoutesToItsOwnPhase() {
        #expect(
            MeetingWorkspaceRoute.route(
                phase: .finalizing(0.4),
                activeMeetingID: meetingID,
                meetingID: meetingID
            ) == .finalizing
        )
    }

    @Test("An idle or failed meeting shows the completed workspace")
    func settledPhasesRouteToCompleted() {
        for phase in [RecordingPhase.idle, .failed("capture stopped")] {
            #expect(
                MeetingWorkspaceRoute.route(
                    phase: phase,
                    activeMeetingID: meetingID,
                    meetingID: meetingID
                ) == .completed
            )
        }
    }

    /// Browsing an old meeting during a recording must not hand that window the
    /// live controls: Stop would end a meeting the user is not looking at.
    @Test("Another meeting's recording never takes over this window")
    func otherMeetingsRecordingDoesNotLeak() {
        for phase in [RecordingPhase.recording, .paused, .preparing, .finalizing(0.2)] {
            #expect(
                MeetingWorkspaceRoute.route(
                    phase: phase,
                    activeMeetingID: UUID(),
                    meetingID: meetingID
                ) == .completed
            )
        }
    }

    /// `startMeeting` sets `.preparing` before `markRecordingStarted` assigns
    /// the active meeting, so the identifier is briefly nil.
    @Test("Preparing with no active meeting yet stays on the completed workspace")
    func preparingWithoutAnActiveMeetingStaysCompleted() {
        #expect(
            MeetingWorkspaceRoute.route(
                phase: .preparing,
                activeMeetingID: nil,
                meetingID: meetingID
            ) == .completed
        )
    }
}
