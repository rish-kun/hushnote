import Foundation
import Testing
@testable import Hushnote

/// Summary and Ask are gated only on the transcript being non-empty, which it
/// is throughout a live capture. Offering them mid-recording would let a
/// summary be generated against provisional text whose segment identifiers the
/// final pass is about to replace wholesale.
@Suite("Workspace tab availability")
struct WorkspaceTabAvailabilityTests {
    private let meeting = UUID()
    private let other = UUID()

    @Test("A busy meeting offers only what is meaningful while it is busy")
    func busyPhases() {
        for phase in [RecordingPhase.preparing, .recording, .paused, .finalizing(0.5)] {
            #expect(
                WorkspaceTabAvailability.available(during: phase) == [.notes, .transcript],
                "\(phase) should not offer Summary or Ask"
            )
        }
    }

    @Test("A settled meeting offers everything")
    func settledPhases() {
        #expect(WorkspaceTabAvailability.available(during: .idle) == WorkspaceTab.allCases)
        #expect(
            WorkspaceTabAvailability.available(
                during: .failed(RecordingFailure(kind: .unknown, message: "x", meetingID: nil))
            ) == WorkspaceTab.allCases
        )
    }

    /// The bug this exists to stop: `recordingPhase` is global, but only one
    /// meeting owns the capture session. Reading it directly hid Summary and
    /// Ask on every *other* meeting for the length of an unrelated recording.
    @Test("Only the meeting holding the capture session is governed by its phase")
    func governingPhaseIsPerMeeting() {
        #expect(
            WorkspaceTabAvailability.governingPhase(
                .recording, activeMeetingID: meeting, meetingID: meeting
            ) == .recording
        )
        #expect(
            WorkspaceTabAvailability.governingPhase(
                .recording, activeMeetingID: other, meetingID: meeting
            ) == .idle
        )
        #expect(
            WorkspaceTabAvailability.governingPhase(
                .recording, activeMeetingID: nil, meetingID: meeting
            ) == .idle
        )
    }

    /// Resolution is read-only. Starting a recording on a meeting whose stored
    /// tab is Summary must not rewrite that preference, or the tab would have
    /// silently changed for good by the time the user pressed Stop.
    @Test("A tab the phase does not offer falls back without being overwritten")
    func staleSelectionFallsBack() {
        #expect(WorkspaceTabAvailability.resolved(.summary, during: .recording) == .notes)
        #expect(WorkspaceTabAvailability.resolved(.ask, during: .finalizing(0)) == .notes)
        #expect(WorkspaceTabAvailability.resolved(.transcript, during: .recording) == .transcript)
        #expect(WorkspaceTabAvailability.resolved(.summary, during: .idle) == .summary)
    }
}
