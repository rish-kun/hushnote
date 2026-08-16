import XCTest
@testable import Hushnote

@MainActor
final class AppViewStateTests: XCTestCase {
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
}
