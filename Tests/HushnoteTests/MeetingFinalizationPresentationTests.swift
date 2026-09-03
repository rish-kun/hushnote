import Foundation
import Testing
@testable import Hushnote

@Suite("Meeting finalization presentation")
struct MeetingFinalizationPresentationTests {
    private let meetingID = UUID()
    private let sessionID = UUID()

    private func job(
        state: FinalizationJobState,
        queuedAt: TimeInterval = 10,
        progress: Double = 0.4,
        errorMessage: String? = nil
    ) -> FinalizationJob {
        FinalizationJob(
            sessionID: sessionID,
            state: state,
            modelID: "large-v3",
            progress: progress,
            queuedAt: Date(timeIntervalSince1970: queuedAt),
            errorMessage: errorMessage,
            audioDurationMilliseconds: 60_000
        )
    }

    @Test("Queued work describes safe audio and its ETA")
    func queuedWork() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .queued)],
            eta: .init(lowerBoundSeconds: 30, upperBoundSeconds: 45),
            isBlockedByLiveCapture: false
        )

        #expect(presentation?.kind == .queued)
        #expect(presentation?.title == "Final transcription queued")
        #expect(presentation?.detail.contains("Recording is safe") == true)
        #expect(presentation?.compactText.contains("30–45 sec") == true)
        #expect(presentation?.progress == nil)
    }

    @Test("A live recording honestly explains why queued work waits")
    func queuedWorkBlockedByCapture() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .queued)],
            eta: nil,
            isBlockedByLiveCapture: true
        )

        #expect(presentation?.detail.contains("after the current recording stops") == true)
    }

    @Test("Running work outranks queued and failed appended sessions")
    func runningWorkWinsAggregation() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [
                job(state: .queued, queuedAt: 40),
                job(state: .failed, queuedAt: 30, errorMessage: "decoder stopped"),
                job(state: .diarizing, queuedAt: 20, progress: 0.8),
            ],
            eta: .init(lowerBoundSeconds: 10, upperBoundSeconds: 20),
            isBlockedByLiveCapture: false
        )

        #expect(presentation?.kind == .diarizing)
        #expect(presentation?.title == "Identifying speakers")
        #expect(presentation?.progress == 0.8)
        #expect(presentation?.unresolvedSessionCount == 3)
    }

    @Test("A failed job remains actionable when no work is running")
    func failedWork() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [
                job(state: .queued, queuedAt: 10),
                job(state: .failed, queuedAt: 20, errorMessage: "The decoder stopped."),
            ],
            eta: .init(lowerBoundSeconds: 30, upperBoundSeconds: 45),
            isBlockedByLiveCapture: false
        )

        #expect(presentation?.kind == .failed)
        #expect(presentation?.isRetryable == true)
        #expect(presentation?.detail == "The decoder stopped.")
        #expect(presentation?.eta == nil)
    }

    @Test("Completed sessions do not leave a stale status behind")
    func completedWorkIsHidden() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .succeeded, progress: 1)],
            eta: nil,
            isBlockedByLiveCapture: false
        )

        #expect(presentation == nil)
    }
}
