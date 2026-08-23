import CoreAudio
import Foundation
import Testing
@testable import Hushnote

@Suite("Core Audio start preparation")
struct CaptureStartPreparationTests {
    @Test("Readiness returns as soon as an input stream appears")
    func readinessStopsAtFirstStream() throws {
        var probes = 0
        var sleeps: [TimeInterval] = []

        try CaptureStartPreparation.waitForInputStream(
            attempts: 5,
            delay: 0.025,
            probe: {
                probes += 1
                return .init(
                    status: noErr,
                    byteCount: probes == 3 ? UInt32(MemoryLayout<AudioStreamID>.size) : 0
                )
            },
            sleep: { sleeps.append($0) }
        )

        #expect(probes == 3)
        #expect(sleeps == [0.025, 0.025])
    }

    @Test("A stream that never appears times out without a final sleep")
    func readinessTimesOut() {
        var sleeps = 0

        #expect(throws: AudioPipelineError.audioCaptureFailed) {
            try CaptureStartPreparation.waitForInputStream(
                attempts: 4,
                probe: { .init(status: noErr, byteCount: 0) },
                sleep: { _ in sleeps += 1 }
            )
        }

        #expect(sleeps == 3)
    }

    @Test("Persistent readiness errors keep their Core Audio status")
    func persistentReadinessErrorIsSurfaced() {
        let failure = OSStatus(-50)
        var probes = 0

        #expect(throws: AudioPipelineError.coreAudioFailure(
            "prepare the system-audio input stream",
            failure
        )) {
            try CaptureStartPreparation.waitForInputStream(
                attempts: 10,
                toleratedFailures: 2,
                probe: {
                    probes += 1
                    return .init(status: failure, byteCount: 0)
                },
                sleep: { _ in }
            )
        }

        #expect(probes == 3)
    }

    @Test("Transient start failures use the declared backoff schedule")
    func transientStartIsRetried() throws {
        var starts = 0
        var sleeps: [TimeInterval] = []

        try CaptureStartPreparation.startDevice(
            retryDelays: [0, 0.05, 0.1, 0.2],
            start: {
                starts += 1
                return starts < 3 ? CaptureStartPreparation.transientIllegalOperation : noErr
            },
            sleep: { sleeps.append($0) }
        )

        #expect(starts == 3)
        #expect(sleeps == [0.05, 0.1])
    }

    @Test("A deterministic start failure is never retried")
    func nonTransientStartFailsImmediately() {
        let failure = OSStatus(-50)
        var starts = 0
        var sleeps = 0

        #expect(throws: AudioPipelineError.coreAudioFailure(
            SystemAudioTapCapture.Operation.startDevice,
            failure
        )) {
            try CaptureStartPreparation.startDevice(
                start: {
                    starts += 1
                    return failure
                },
                sleep: { _ in sleeps += 1 }
            )
        }

        #expect(starts == 1)
        #expect(sleeps == 0)
    }

    @Test("Exhausted transient starts name the waited operation")
    func transientStartExhaustion() {
        #expect(throws: AudioPipelineError.coreAudioFailure(
            SystemAudioTapCapture.Operation.startDeviceAfterWaiting,
            CaptureStartPreparation.transientIllegalOperation
        )) {
            try CaptureStartPreparation.startDevice(
                retryDelays: [0, 0.01],
                start: { CaptureStartPreparation.transientIllegalOperation },
                sleep: { _ in }
            )
        }
    }
}
