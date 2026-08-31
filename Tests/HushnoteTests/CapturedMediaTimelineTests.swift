import Foundation
import Testing
@testable import Hushnote

@Suite("Captured media timeline")
struct CapturedMediaTimelineTests {
    @Test("Independent sources share one meeting-time coordinate space")
    func alignsSourcesByPresentationTime() throws {
        var timeline = CapturedMediaTimeline(meetingStartMilliseconds: 10_000)

        let systemFirstValue = timeline.append(
            source: .system,
            presentationSeconds: 100,
            durationMilliseconds: 20
        )
        let systemFirst = try #require(systemFirstValue)
        let microphoneFirstValue = timeline.append(
            source: .microphone,
            presentationSeconds: 100,
            durationMilliseconds: 20
        )
        let microphoneFirst = try #require(microphoneFirstValue)
        let microphoneSecondValue = timeline.append(
            source: .microphone,
            presentationSeconds: 100.020,
            durationMilliseconds: 20
        )
        let microphoneSecond = try #require(microphoneSecondValue)

        #expect(systemFirst.startMilliseconds == 10_000)
        #expect(microphoneFirst.startMilliseconds == systemFirst.startMilliseconds)
        #expect(microphoneSecond.startMilliseconds == 10_020)
        #expect(timeline.positionMilliseconds == 10_040)
    }

    @Test("A source never moves backwards when its timestamp does")
    func clampsBackwardSourceTimestamps() throws {
        var timeline = CapturedMediaTimeline()

        _ = timeline.append(
            source: .system,
            presentationSeconds: 50,
            durationMilliseconds: 40
        )
        let backwardValue = timeline.append(
            source: .system,
            presentationSeconds: 49,
            durationMilliseconds: 10
        )
        let backward = try #require(backwardValue)
        let delayedOtherSourceValue = timeline.append(
            source: .microphone,
            presentationSeconds: 50.020,
            durationMilliseconds: 10
        )
        let delayedOtherSource = try #require(delayedOtherSourceValue)

        #expect(backward.startMilliseconds == 40)
        // A delayed callback from the other source may overlap system audio;
        // it still uses the same meeting coordinate rather than being placed
        // after whichever callback happened to arrive first.
        #expect(delayedOtherSource.startMilliseconds == 20)
        #expect(timeline.positionMilliseconds == 50)
    }

    @Test("Pause and sleep freeze media time and report omitted wall time")
    func suspensionsFreezeTheTimeline() throws {
        for reason in [CapturedMediaSuspensionReason.pause, .sleep] {
            var timeline = CapturedMediaTimeline(meetingStartMilliseconds: 1_000)
            _ = timeline.append(
                source: .system,
                presentationSeconds: 100,
                durationMilliseconds: 100
            )

            timeline.suspend(reason: reason, at: 100.1)
            let positionWhileSuspended = timeline.positionMilliseconds
            #expect(timeline.append(
                source: .system,
                presentationSeconds: 102,
                durationMilliseconds: 100
            ) == nil)
            #expect(timeline.positionMilliseconds == positionWhileSuspended)

            let omissionValue = timeline.resume(at: 105.1)
            let omission = try #require(omissionValue)
            #expect(omission.reason == reason)
            #expect(omission.atMilliseconds == 1_100)
            #expect(omission.wallDurationMilliseconds == 5_000)

            let resumedValue = timeline.append(
                source: .microphone,
                presentationSeconds: 105.25,
                durationMilliseconds: 50
            )
            let resumed = try #require(resumedValue)
            #expect(resumed.startMilliseconds == 1_100)
            #expect(resumed.endMilliseconds == 1_150)
        }
    }

    @Test("Invalid timestamps fall back safely and do not poison a later anchor")
    func toleratesMalformedTimestamps() throws {
        var timeline = CapturedMediaTimeline(meetingStartMilliseconds: 200)

        let invalidValue = timeline.append(
            source: .system,
            presentationSeconds: .nan,
            durationMilliseconds: 25
        )
        let invalid = try #require(invalidValue)
        let firstValidValue = timeline.append(
            source: .microphone,
            presentationSeconds: 80,
            durationMilliseconds: 25
        )
        let firstValid = try #require(firstValidValue)
        let repeatedValue = timeline.append(
            source: .microphone,
            presentationSeconds: 79,
            durationMilliseconds: 10
        )
        let repeated = try #require(repeatedValue)
        let infiniteValue = timeline.append(
            source: .system,
            presentationSeconds: .infinity,
            durationMilliseconds: 5
        )
        let infinite = try #require(infiniteValue)

        #expect(invalid.startMilliseconds == 200)
        #expect(firstValid.startMilliseconds == 225)
        #expect(repeated.startMilliseconds == 250)
        #expect(infinite.startMilliseconds == 260)
        #expect(timeline.positionMilliseconds == 265)
    }

    @Test("An invalid suspension clock reports an unknown gap and still resumes")
    func invalidSuspensionClockIsHonest() throws {
        var timeline = CapturedMediaTimeline()
        _ = timeline.append(
            source: .system,
            presentationSeconds: 10,
            durationMilliseconds: 100
        )

        timeline.suspend(reason: .sleep, at: .nan)
        let omissionValue = timeline.resume(at: .infinity)
        let omission = try #require(omissionValue)
        let resumedValue = timeline.append(
            source: .system,
            presentationSeconds: 30,
            durationMilliseconds: 100
        )
        let resumed = try #require(resumedValue)

        #expect(omission.wallDurationMilliseconds == nil)
        #expect(resumed.startMilliseconds == 100)
        #expect(timeline.positionMilliseconds == 200)
    }

    @Test("Appended sessions begin at their assigned meeting offset")
    func honorsNonzeroMeetingStart() throws {
        var timeline = CapturedMediaTimeline(meetingStartMilliseconds: 3_600_000)

        let rangeValue = timeline.append(
            source: .system,
            presentationSeconds: 7_200,
            durationMilliseconds: 500
        )
        let range = try #require(rangeValue)

        #expect(range.startMilliseconds == 3_600_000)
        #expect(range.endMilliseconds == 3_600_500)
        #expect(timeline.positionMilliseconds == 3_600_500)
    }

    @Test("A host-clock jump cannot invent uncaptured meeting time")
    func clampsForwardClockJumpsToTheDurableFrontier() throws {
        var timeline = CapturedMediaTimeline()

        _ = timeline.append(
            source: .system,
            presentationSeconds: 1_000,
            durationMilliseconds: 300
        )
        let resumedValue = timeline.append(
            source: .system,
            presentationSeconds: 1_010,
            durationMilliseconds: 300
        )
        let resumed = try #require(resumedValue)

        #expect(resumed.startMilliseconds == 300)
        #expect(resumed.endMilliseconds == 600)
        #expect(timeline.positionMilliseconds == 600)
    }
}

@Suite("Captured media timeline coordinator")
struct CapturedMediaTimelineCoordinatorTests {
    @Test("Source writes run independently")
    func sourceWritesCanOverlap() {
        let coordinator = CapturedMediaTimelineCoordinator()
        let queue = DispatchQueue(
            label: "com.hushnote.tests.timeline-overlap",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        for source in [AudioSource.system, .microphone] {
            group.enter()
            queue.async {
                _ = try? coordinator.record(
                    source: source,
                    presentationSeconds: 10
                ) {
                    started.signal()
                    release.wait()
                    return (value: (), durationMilliseconds: 10)
                }
                group.leave()
            }
        }

        let firstStarted = started.wait(timeout: .now() + 1)
        let secondStarted = started.wait(timeout: .now() + 1)
        // Always release both operations so a failed assertion cannot strand
        // worker threads or a later SwiftPM test run.
        release.signal()
        release.signal()
        let completed = group.wait(timeout: .now() + 1)

        #expect(firstStarted == .success)
        #expect(secondStarted == .success, "one source writer blocked the other")
        #expect(completed == .success)
    }

    @Test("Suspension waits for admitted writes and rejects later writes")
    func suspensionIsAtomicWithWrites() throws {
        let coordinator = CapturedMediaTimelineCoordinator()
        let queue = DispatchQueue(
            label: "com.hushnote.tests.timeline-suspend",
            attributes: .concurrent
        )
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let recordFinished = DispatchSemaphore(value: 0)
        let suspensionFinished = DispatchSemaphore(value: 0)

        queue.async {
            _ = try? coordinator.record(
                source: .system,
                presentationSeconds: 100
            ) {
                writeStarted.signal()
                releaseWrite.wait()
                return (value: (), durationMilliseconds: 100)
            }
            recordFinished.signal()
        }
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)

        queue.async {
            coordinator.suspend(reason: .pause, at: 100.1)
            suspensionFinished.signal()
        }
        #expect(
            suspensionFinished.wait(timeout: .now() + 0.05) == .timedOut,
            "suspension returned before an admitted durable write committed"
        )

        var rejectedOperationRan = false
        let rejected = try coordinator.record(
            source: .microphone,
            presentationSeconds: 100.05
        ) {
            rejectedOperationRan = true
            return (value: (), durationMilliseconds: 50)
        }
        #expect(rejected == nil)
        #expect(!rejectedOperationRan)

        releaseWrite.signal()
        #expect(recordFinished.wait(timeout: .now() + 1) == .success)
        #expect(suspensionFinished.wait(timeout: .now() + 1) == .success)
        #expect(coordinator.positionMilliseconds == 100)
        #expect(coordinator.isSuspended)

        let omissionValue = coordinator.resume(at: 105.1)
        let omission = try #require(omissionValue)
        let resumedValue = try coordinator.record(
            source: .microphone,
            presentationSeconds: 105.2
        ) {
            (value: (), durationMilliseconds: 50)
        }
        let resumed = try #require(resumedValue)
        #expect(omission.atMilliseconds == 100)
        #expect(resumed.range.startMilliseconds == 100)
        #expect(resumed.range.endMilliseconds == 150)
    }
}
