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

    @Test("A newer queued session outranks an older failure")
    func newerQueuedOutranksOlderFailure() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [
                job(state: .failed, queuedAt: 10, errorMessage: "decoder stopped"),
                job(state: .queued, queuedAt: 20),
            ],
            eta: .init(lowerBoundSeconds: 30, upperBoundSeconds: 45),
            isBlockedByLiveCapture: false
        )

        #expect(presentation?.kind == .queued)
        #expect(presentation?.title == "Final transcription queued")
        #expect(presentation?.isRetryable == false)
        #expect(presentation?.unresolvedSessionCount == 2)
    }

    @Test("Running work outranks newer queued work even when older")
    func runningOutranksNewerQueued() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [
                job(state: .transcribing, queuedAt: 10, progress: 0.3),
                job(state: .queued, queuedAt: 20),
            ],
            eta: .init(lowerBoundSeconds: 10, upperBoundSeconds: 20),
            isBlockedByLiveCapture: false
        )

        #expect(presentation?.kind == .transcribing)
        #expect(presentation?.title == "Transcribing recording")
        #expect(presentation?.progress == 0.3)
    }

    @Test("Working stages expose progress, ETA and honest copy")
    func workingStagesExposeProgress() {
        let transcribing = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .transcribing, progress: 0.55)],
            eta: .init(lowerBoundSeconds: 10, upperBoundSeconds: 20),
            isBlockedByLiveCapture: false
        )
        #expect(transcribing?.progress == 0.55)
        #expect(transcribing?.eta != nil)
        #expect(transcribing?.detail.contains("final transcript") == true)

        let diarizing = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .diarizing, progress: 0.75)],
            eta: nil,
            isBlockedByLiveCapture: false
        )
        #expect(diarizing?.title == "Identifying speakers")
        #expect(diarizing?.progress == 0.75)

        let merging = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .merging, progress: 0.92)],
            eta: nil,
            isBlockedByLiveCapture: false
        )
        #expect(merging?.title == "Updating combined transcript")
        #expect(merging?.progress == 0.92)
    }

    @Test("A failure without a message still promises the audio is safe")
    func failedWithoutMessagePromisesAudioSafety() {
        let presentation = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .failed)],
            eta: .init(lowerBoundSeconds: 30, upperBoundSeconds: 45),
            isBlockedByLiveCapture: false
        )

        #expect(presentation?.kind == .failed)
        #expect(presentation?.detail.contains("original recording is safe") == true)
        #expect(presentation?.isRetryable == true)
        #expect(presentation?.eta == nil)
        #expect(presentation?.progress == nil)
    }

    @Test("The sidebar keeps its date beside the compact status")
    func sidebarRetainsDate() {
        #expect(MeetingFinalizationSidebarPolicy.subtitle(dateString: "Sep 4", compactText: nil) == "Sep 4")
        #expect(
            MeetingFinalizationSidebarPolicy.subtitle(
                dateString: "Sep 4",
                compactText: "Final transcription queued · About 30–45 sec left"
            ) == "Sep 4 · Final transcription queued · About 30–45 sec left"
        )
        #expect(MeetingFinalizationSidebarPolicy.subtitle(dateString: "", compactText: "Final transcription queued") == "Final transcription queued")
        #expect(MeetingFinalizationSidebarPolicy.systemImage(hasPresentation: true) == "clock.arrow.circlepath")
        #expect(MeetingFinalizationSidebarPolicy.systemImage(hasPresentation: false) == "doc.text")
    }

    @Test("The finalizing route hands from global to durable without a gap")
    func finalizingHandoff() {
        #expect(FinalizationBannerHandoffPolicy.showsGlobalBanner(presentation: nil) == true)
        let queued = MeetingFinalizationPresentationPolicy.presentation(
            jobs: [job(state: .queued)],
            eta: nil,
            isBlockedByLiveCapture: false
        )
        #expect(FinalizationBannerHandoffPolicy.showsGlobalBanner(presentation: queued) == false)
    }
}
