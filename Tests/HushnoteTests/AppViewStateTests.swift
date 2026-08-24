import XCTest
@testable import Hushnote

@MainActor
final class AppViewStateTests: XCTestCase {
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
}
