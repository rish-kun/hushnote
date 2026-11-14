import XCTest
@testable import Hushnote

@MainActor
final class AppViewStateTests: XCTestCase {
    func testMicrophonePreferencesApplyWithoutCouplingLevelsToDiagnostics() {
        let suite = "dev.rishit.hushnote.view-state-microphone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.microphoneCaptureEnabled = false
        preferences.selectedMicrophone = PreferredMicrophone(uid: "desk", displayName: "Desk Mic")
        let state = AppViewState()

        state.applyMicrophonePreferences(preferences)
        state.microphoneLevel = 0.75

        XCTAssertFalse(state.microphoneCaptureEnabled)
        XCTAssertEqual(state.selectedMicrophone?.uid, "desk")
        XCTAssertEqual(state.selectedMicrophone?.displayName, "Desk Mic")
        XCTAssertEqual(state.microphoneLevel, 0.75)
        XCTAssertEqual(state.recordingDiagnostics.diagnostics(for: .microphone).lifecycle, .disabled)
    }

    func testSelectedFolderIDTracksOnlyFolderDestinations() {
        let state = AppViewState()
        let folderID = UUID()

        state.selection = .folder(folderID)
        XCTAssertEqual(state.selectedFolderID, folderID)
        state.selection = .unfiled
        XCTAssertNil(state.selectedFolderID)
        state.selection = .meeting(UUID())
        XCTAssertNil(state.selectedFolderID)
    }

    func testStaleFolderAndMeetingDestinationsFallBackToMeetings() {
        let existingMeeting = UUID()
        let existingFolder = UUID()

        XCTAssertEqual(
            AppViewState.resolvedSidebarDestination(
                .folder(UUID()), meetingIDs: [existingMeeting], folderIDs: [existingFolder]
            ),
            .meetings
        )
        XCTAssertEqual(
            AppViewState.resolvedSidebarDestination(
                .meeting(UUID()), meetingIDs: [existingMeeting], folderIDs: [existingFolder]
            ),
            .meetings
        )
        XCTAssertEqual(
            AppViewState.resolvedSidebarDestination(
                .folder(existingFolder), meetingIDs: [existingMeeting], folderIDs: [existingFolder]
            ),
            .folder(existingFolder)
        )
    }

    func testFolderManagementFailuresUseTheirOwnAlertRoute() {
        XCTAssertEqual(
            FailureRoute.route(for: .folderManagement),
            .appAlert(title: "The folder could not be updated")
        )
    }

    func testRecordingPhaseBusyAndCapturingSemantics() {
        XCTAssertFalse(RecordingPhase.idle.isBusy)
        XCTAssertTrue(RecordingPhase.preparing.isBusy)
        XCTAssertTrue(RecordingPhase.recording.isBusy)
        XCTAssertTrue(RecordingPhase.paused.isBusy)
        XCTAssertTrue(RecordingPhase.finalizing(0.5).isBusy)
        XCTAssertFalse(RecordingPhase.failed("Stopped").isBusy)

        XCTAssertTrue(RecordingPhase.recording.isCapturing)
        XCTAssertTrue(RecordingPhase.paused.isCapturing)
        XCTAssertFalse(RecordingPhase.finalizing(0).isCapturing)
    }

    func testFinalizationStagesHaveConciseUserFacingLabels() {
        XCTAssertEqual(FinalizationStage.savingAudio.title, "Saving audio…")
        XCTAssertEqual(FinalizationStage.stoppingLiveTranscription.title, "Stopping live transcription…")
        XCTAssertEqual(FinalizationStage.loadingFinalModel.title, "Loading final model…")
        XCTAssertEqual(FinalizationStage.transcribing.title, "Transcribing recording…")
        XCTAssertEqual(FinalizationStage.diarizing.title, "Identifying speakers…")
        XCTAssertEqual(FinalizationStage.generatingInsights.title, "Generating summary…")
    }

    func testMarkFinalizingSetsStageAndClampsProgress() {
        let state = AppViewState()

        state.markFinalizing(stage: .savingAudio, progress: -0.25)
        XCTAssertEqual(state.recordingPhase, .finalizing(0))
        XCTAssertEqual(state.finalizationStage, .savingAudio)
        XCTAssertEqual(state.finalizationLabel, "Saving audio…")

        state.updateFinalization(
            stage: .loadingFinalModel,
            progress: 1.4,
            detail: "Downloading model 42%"
        )
        XCTAssertEqual(state.recordingPhase, .finalizing(1))
        XCTAssertEqual(state.finalizationStage, .loadingFinalModel)
        XCTAssertEqual(state.finalizationLabel, "Downloading model 42%")
    }

    func testFinalizationUpdatesAreIgnoredOutsideFinalizingPhase() {
        let state = AppViewState()

        state.updateFinalization(stage: .transcribing, progress: 0.6)

        XCTAssertEqual(state.recordingPhase, .idle)
        XCTAssertNil(state.finalizationStage)
        XCTAssertEqual(state.finalizationLabel, "Finalizing transcript…")
    }

    func testRecordingRestartAndFinishClearFinalizationPresentation() {
        let state = AppViewState()
        let meetingID = UUID()
        state.markFinalizing(
            stage: .generatingInsights,
            progress: 0.9,
            detail: "Summarizing decisions"
        )

        state.markRecordingStarted(meetingID: meetingID)
        XCTAssertEqual(state.recordingPhase, .recording)
        XCTAssertEqual(state.activeMeetingID, meetingID)
        XCTAssertNil(state.finalizationStage)
        XCTAssertNil(state.finalizationDetail)

        state.markFinalizing(stage: .diarizing, progress: 0.8)
        state.markFinished()
        XCTAssertEqual(state.recordingPhase, .idle)
        XCTAssertEqual(state.selection, .meeting(meetingID))
        XCTAssertNil(state.activeMeetingID)
        XCTAssertNil(state.finalizationStage)
        XCTAssertNil(state.finalizationDetail)
    }

    func testLiveTranscriptDoesNotReplaceCompletedMeetingBeingRead() {
        let state = AppViewState()
        let liveMeetingID = UUID()
        let completedMeetingID = UUID()
        let completed = Self.line("completed", text: "Yesterday's decision")
        let live = Self.line("live", text: "Words arriving now")

        state.selection = .meeting(completedMeetingID)
        state.transcript = [completed]
        state.activeMeetingID = liveMeetingID
        state.recordingPhase = .recording
        state.liveTranscript = [live]

        XCTAssertEqual(state.transcript(for: completedMeetingID), [completed])
        XCTAssertEqual(state.transcript(for: liveMeetingID), [live])

        state.liveTranscript.append(Self.line("new-live", text: "Another live delta"))
        XCTAssertEqual(state.transcript(for: completedMeetingID), [completed])
        XCTAssertEqual(state.transcript(for: liveMeetingID).count, 2)
    }

    func testNewRecordingClearsOnlyLiveWorkspaceContent() {
        let state = AppViewState()
        let completed = Self.line("completed", text: "Keep this visible")
        state.transcript = [completed]
        state.liveTranscript = [Self.line("stale-live", text: "Old capture")]
        state.liveRecordingEvents = [
            RecordingEvent(
                sessionID: UUID(),
                kind: .pause,
                timelineMilliseconds: 1_000,
                wallClockAt: Date(),
                durationMilliseconds: 500
            )
        ]

        state.markRecordingStarted(meetingID: UUID())

        XCTAssertEqual(state.transcript, [completed])
        XCTAssertTrue(state.liveTranscript.isEmpty)
        XCTAssertTrue(state.liveRecordingEvents.isEmpty)
    }

    func testFinishingPromotesActiveTranscriptWithoutMixingMeetings() {
        let state = AppViewState()
        let liveMeetingID = UUID()
        let live = Self.line("live", text: "Provisional but safe")
        let event = RecordingEvent(
            sessionID: UUID(),
            kind: .pause,
            timelineMilliseconds: 2_000,
            wallClockAt: Date(),
            durationMilliseconds: 750
        )
        state.activeMeetingID = liveMeetingID
        state.recordingPhase = .finalizing(0.5)
        state.liveTranscript = [live]
        state.liveRecordingEvents = [event]

        state.markFinished()

        XCTAssertEqual(state.selection, .meeting(liveMeetingID))
        XCTAssertEqual(state.transcript, [live])
        XCTAssertEqual(state.recordingEvents, [event])
        XCTAssertTrue(state.liveTranscript.isEmpty)
        XCTAssertTrue(state.liveRecordingEvents.isEmpty)
    }

    func testFirstDurableBufferPromotesStartupAndTerminalStatesClearIt() {
        let state = AppViewState()
        let meetingID = UUID()
        state.recordingPhase = .preparing
        state.recordingStartupStage = .waitingForFirstBuffer

        state.markRecordingStarted(meetingID: meetingID)
        XCTAssertEqual(state.recordingPhase, .recording)
        XCTAssertEqual(state.recordingStartupStage, .ready)

        state.markFinished()
        XCTAssertEqual(state.recordingStartupStage, .idle)

        state.recordingPhase = .preparing
        state.recordingStartupStage = .arming
        state.markFailed(.init(kind: .capture, message: "Tap stopped"))
        XCTAssertEqual(state.recordingStartupStage, .idle)
    }

    private static func line(_ segmentID: String, text: String) -> TranscriptLineItem {
        TranscriptLineItem(
            id: UUID(),
            segmentID: segmentID,
            speaker: "Speaker",
            start: 0,
            end: 1,
            text: text,
            isProvisional: segmentID.contains("live")
        )
    }

    func testInsightWorkRemainsVisibleToQuitGuardAfterNavigatingAway() {
        let state = AppViewState()
        let runningMeeting = UUID()
        let displayedMeeting = UUID()
        state.updateInsights(for: runningMeeting) { $0.isGenerating = true }
        state.selection = .meeting(displayedMeeting)

        XCTAssertFalse(state.insights.isGenerating)
        XCTAssertTrue(state.hasInsightWork)
        XCTAssertEqual(
            TerminationGuard.decision(
                for: state.recordingPhase,
                hasInsightWork: state.hasInsightWork
            ),
            .confirmFinalizing
        )
    }

    func testInsightContentAndProgressAreMeetingScoped() {
        let state = AppViewState()
        let first = UUID()
        let second = UUID()
        state.updateInsights(for: first) {
            $0.summary = "First summary"
            $0.isGenerating = true
        }
        state.updateInsights(for: second) { $0.summary = "Second summary" }

        state.selection = .meeting(second)
        XCTAssertEqual(state.insights.summary, "Second summary")
        XCTAssertFalse(state.insights.isGenerating)

        state.selection = .meeting(first)
        XCTAssertEqual(state.insights.summary, "First summary")
        XCTAssertTrue(state.insights.isGenerating)
    }

    func testUnsavedSummaryWorkRemainsVisibleAfterSelectionChanges() {
        let state = AppViewState()
        let meetingID = UUID()
        state.updateInsights(for: meetingID) {
            $0.summary = "Stored"
            $0.summaryDraft = "Edited"
            $0.isEditingSummary = true
        }
        state.selection = .settings

        XCTAssertTrue(state.hasUnsavedSummaryChanges)
        XCTAssertEqual(state.unsavedSummaryMeetingID, meetingID)
    }

    func testMeetingScopedFinalizationSurvivesStopAndUnrelatedRecording() {
        let state = AppViewState()
        let completedMeetingID = UUID()
        let activeMeetingID = UUID()
        let job = FinalizationJob(
            sessionID: UUID(),
            state: .queued,
            modelID: "large-v3",
            audioDurationMilliseconds: 60_000
        )

        state.recordFinalizationJob(job, for: completedMeetingID)
        state.finalizationETAs[completedMeetingID] = .init(
            lowerBoundSeconds: 30,
            upperBoundSeconds: 45
        )
        state.activeMeetingID = completedMeetingID
        state.markFinalizing(stage: .savingAudio, progress: 0.1)
        state.markFinished()

        XCTAssertEqual(state.finalizationPresentation(for: completedMeetingID)?.kind, .queued)
        XCTAssertEqual(state.finalizationPresentation(for: completedMeetingID)?.eta?.lowerBoundSeconds, 30)

        state.markRecordingStarted(meetingID: activeMeetingID)

        XCTAssertEqual(state.finalizationPresentation(for: completedMeetingID)?.kind, .queued)
        XCTAssertTrue(
            state.finalizationPresentation(for: completedMeetingID)?.detail
                .contains("after the current recording stops") == true
        )
    }

    func testPreparingAndFinalizingElsewhereAlsoBlockQueuedWork() {
        let state = AppViewState()
        let completedMeetingID = UUID()
        let otherMeetingID = UUID()
        let job = FinalizationJob(
            sessionID: UUID(),
            state: .queued,
            modelID: "large-v3",
            audioDurationMilliseconds: 60_000
        )
        state.recordFinalizationJob(job, for: completedMeetingID)

        // Preparing owns the pipeline before the first buffer: the queue waits.
        state.recordingPhase = .preparing
        state.activeMeetingID = otherMeetingID
        XCTAssertTrue(
            state.finalizationPresentation(for: completedMeetingID)?.detail
                .contains("after the current recording stops") == true
        )

        // A foreground finalization elsewhere also owns it.
        state.recordingPhase = .finalizing(0.4)
        state.activeMeetingID = otherMeetingID
        XCTAssertTrue(
            state.finalizationPresentation(for: completedMeetingID)?.detail
                .contains("after the current recording stops") == true
        )

        // Idle never blocks, and the meeting being finalized never blocks itself.
        state.recordingPhase = .idle
        state.activeMeetingID = nil
        XCTAssertTrue(
            state.finalizationPresentation(for: completedMeetingID)?.detail
                .contains("will start automatically") == true
        )
        state.recordingPhase = .finalizing(0.4)
        state.activeMeetingID = completedMeetingID
        XCTAssertTrue(
            state.finalizationPresentation(for: completedMeetingID)?.detail
                .contains("will start automatically") == true
        )
    }

    func testWorkingPresentationSurvivesMarkFinishedWithProgress() {
        let state = AppViewState()
        let meetingID = UUID()
        let job = FinalizationJob(
            sessionID: UUID(),
            state: .transcribing,
            modelID: "large-v3",
            progress: 0.55,
            audioDurationMilliseconds: 60_000
        )
        state.recordFinalizationJob(job, for: meetingID)
        state.finalizationETAs[meetingID] = .init(lowerBoundSeconds: 10, upperBoundSeconds: 20)
        state.activeMeetingID = meetingID
        state.markFinalizing(stage: .savingAudio, progress: 0.1)
        state.markFinished()

        XCTAssertEqual(state.finalizationPresentation(for: meetingID)?.kind, .transcribing)
        XCTAssertEqual(state.finalizationPresentation(for: meetingID)?.progress, 0.55)
        XCTAssertNotNil(state.finalizationPresentation(for: meetingID)?.eta)
    }
}
