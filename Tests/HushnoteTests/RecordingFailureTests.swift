import Foundation
import Testing
@testable import Hushnote

/// `markFailed` is called by at least nine paths, only three of which have
/// anything to do with audio: bootstrap, meeting creation, model download,
/// keychain save, ChatGPT connect, finalization and recovery all reached the
/// same banner, which offered "System Audio Settings" for every one of them.
///
/// "Try Again" was worse. It called `startMeeting(meetingID: selectedMeetingID)`,
/// and that identifier is nil unless the sidebar selection happens to be a
/// meeting -- and `startMeeting(nil)` constructs a brand-new Meeting. Failing a
/// model download from the Models screen and pressing Try Again started
/// recording a new empty untitled meeting.
@Suite("Recording failure remedies")
struct RecordingFailureTests {
    private let meetingID = UUID()

    @Test("Only a permission failure offers the Privacy pane")
    func privacyPaneIsOfferedOnlyForPermission() {
        #expect(
            RecordingFailure(kind: .audioPermission, message: "Not authorized.")
                .remedies.contains(.openPrivacySettings)
        )

        for kind in [
            RecordingFailureKind.modelDownload,
            .credentialStorage,
            .providerConnection,
            .database,
            .finalization,
            .unknown
        ] {
            #expect(
                RecordingFailure(kind: kind, message: "Something failed.")
                    .remedies.contains(.openPrivacySettings) == false
            )
        }
    }

    /// The bug that could start recording an empty untitled meeting. Retrying is
    /// only representable with a meeting to retry, so the nil case cannot be
    /// written at the call site at all.
    @Test("Retry is offered only when there is a real meeting to retry")
    func retryRequiresAMeeting() {
        #expect(
            RecordingFailure(kind: .capture, message: "Capture stopped.", meetingID: meetingID)
                .remedies == [.retryRecording(meetingID)]
        )
        #expect(
            RecordingFailure(kind: .capture, message: "Capture stopped.").remedies.isEmpty
        )
        #expect(
            RecordingFailure(kind: .audioPermission, message: "Not authorized.").remedies
                == [.openPrivacySettings]
        )
    }

    /// Finalization has its own retry: the audio is already on disk, so starting
    /// a fresh recording would be the wrong verb entirely.
    @Test("A stopped finalization is resumed, not re-recorded")
    func finalizationRetriesFinalization() {
        #expect(
            RecordingFailure(kind: .finalization, message: "ASR failed.", meetingID: meetingID)
                .remedies == [.retryFinalization(meetingID)]
        )
    }

    @Test("A failure points at the screen that can actually fix it")
    func nonRecordingFailuresPointAtTheirOwnScreen() {
        #expect(
            RecordingFailure(kind: .modelDownload, message: "Download failed.").remedies
                == [.openModels]
        )
        #expect(
            RecordingFailure(kind: .credentialStorage, message: "Keychain refused.").remedies
                == [.openSettings]
        )
        #expect(
            RecordingFailure(kind: .providerConnection, message: "Login failed.").remedies
                == [.openSettings]
        )
        #expect(RecordingFailure(kind: .database, message: "Cannot open.").remedies.isEmpty)
    }

    /// A bare message carries no claim about what went wrong, so it must not
    /// produce a remedy that pretends otherwise.
    @Test("An unclassified failure offers nothing it cannot deliver")
    func unclassifiedFailureOffersNoRemedies() {
        let failure: RecordingFailure = "capture stopped"
        #expect(failure.kind == .unknown)
        #expect(failure.message == "capture stopped")
        #expect(failure.remedies.isEmpty)
    }

    @Test("Only a real audio-permission denial is treated as one")
    func permissionIsClassifiedFromTheAudioError() {
        #expect(
            RecordingFailureKind.classifyCapture(AudioPipelineError.permissionDenied)
                == .audioPermission
        )
        #expect(
            RecordingFailureKind.classifyCapture(AudioPipelineError.unsupportedAudioFormat)
                == .capture
        )
        #expect(
            RecordingFailureKind.classifyCapture(CoordinatorError.noTranscript) == .capture
        )
    }

    /// There was no way to dismiss the banner: it sat above the detail pane
    /// until the next recording replaced the phase.
    @MainActor
    @Test("The banner can be dismissed")
    func failureCanBeDismissed() {
        let state = AppViewState()

        state.markFailed(.init(kind: .modelDownload, message: "Download failed."))
        #expect(state.recordingPhase == .failed(.init(kind: .modelDownload, message: "Download failed.")))

        state.dismissFailure()
        #expect(state.recordingPhase == .idle)
    }

    /// Dismissing is only ever about a failure. It must not cancel a recording.
    @MainActor
    @Test("Dismissing does nothing while a meeting is live")
    func dismissDoesNotTouchALiveRecording() {
        let state = AppViewState()
        state.markRecordingStarted(meetingID: meetingID)

        state.dismissFailure()

        #expect(state.recordingPhase == .recording)
    }
}
