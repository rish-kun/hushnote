import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// Sleep/wake tears the aggregate device down, a revoked permission stops the
/// HAL, and a mid-meeting device change can leave the IOProc installed but
/// permanently silent. All three look identical from here — the callback stops
/// firing while the capture still reports itself as running — so one check
/// covers all of them.
@Suite("Capture stall watchdog")
struct CaptureWatchdogTests {
    @Test("Silence longer than the threshold is reported as a failure")
    func reportsStall() {
        let recorder = StallRecorder()
        let watchdog = CaptureStallWatchdog(threshold: 3)
        watchdog.onStall = recorder.record

        watchdog.begin(at: 100)
        watchdog.check(at: 102.9)
        #expect(recorder.stalls.isEmpty, "2.9 s of silence is inside the threshold")

        watchdog.check(at: 103.1)
        #expect(recorder.stalls.count == 1)
        #expect((recorder.stalls.first ?? 0) >= 3)
    }

    @Test("A stall is reported once, not on every tick")
    func reportsOnce() {
        let recorder = StallRecorder()
        let watchdog = CaptureStallWatchdog(threshold: 3)
        watchdog.onStall = recorder.record

        watchdog.begin(at: 0)
        for tick in stride(from: 3.5, through: 20, by: 0.5) {
            watchdog.check(at: tick)
        }

        #expect(recorder.stalls.count == 1)
    }

    @Test("An arriving buffer resets the deadline")
    func bufferResetsDeadline() {
        let recorder = StallRecorder()
        let watchdog = CaptureStallWatchdog(threshold: 3)
        watchdog.onStall = recorder.record

        watchdog.begin(at: 0)
        for tick in stride(from: 0.5, through: 30, by: 0.5) {
            watchdog.noteActivity(at: tick)
            watchdog.check(at: tick)
        }

        #expect(recorder.stalls.isEmpty, "audio never stopped arriving")

        watchdog.check(at: 33.5)
        #expect(recorder.stalls.count == 1, "silence after the last buffer is still a stall")
    }

    @Test("A paused meeting is silent on purpose")
    func pauseIsNotAStall() {
        let recorder = StallRecorder()
        let watchdog = CaptureStallWatchdog(threshold: 3)
        watchdog.onStall = recorder.record

        watchdog.begin(at: 0)
        watchdog.noteActivity(at: 1)
        watchdog.suspend()
        for tick in stride(from: 2.0, through: 60.0, by: 1.0) {
            watchdog.check(at: tick)
        }
        #expect(recorder.stalls.isEmpty, "a pause is not a device failure")

        // Resuming restarts the clock: the device is allowed its start-up time
        // again rather than being judged against the pre-pause buffer.
        watchdog.resume(at: 60)
        watchdog.check(at: 62.5)
        #expect(recorder.stalls.isEmpty)
        watchdog.check(at: 63.5)
        #expect(recorder.stalls.count == 1)
    }

    @Test("A stopped watchdog never fires")
    func stopSilencesIt() {
        let recorder = StallRecorder()
        let watchdog = CaptureStallWatchdog(threshold: 3)
        watchdog.onStall = recorder.record

        watchdog.begin(at: 0)
        watchdog.stop()
        for tick in stride(from: 1.0, through: 60.0, by: 1.0) {
            watchdog.check(at: tick)
        }

        #expect(recorder.stalls.isEmpty)
    }
}

@Suite("Tap format changes")
struct TapFormatChangeTests {
    @Test("An unchanged format is not a failure")
    func identicalFormatIsFine() {
        let format = Self.format(sampleRate: 48_000, channels: 2)
        #expect(!SystemAudioTapCapture.isFatalFormatChange(from: format, to: format))
    }

    /// Plugging in AirPods mid-meeting can halve the tap's rate. The frozen
    /// format keeps being used to wrap every buffer, so the rest of the meeting
    /// is written pitch-shifted and time-stretched.
    @Test("A changed sample rate is a failure")
    func rateChangeIsFatal() {
        #expect(SystemAudioTapCapture.isFatalFormatChange(
            from: Self.format(sampleRate: 48_000, channels: 2),
            to: Self.format(sampleRate: 24_000, channels: 2)
        ))
    }

    /// A changed channel count makes every `ownedCopy` return nil, which is an
    /// empty recording behind a UI that still says "recording".
    @Test("A changed channel count is a failure")
    func channelChangeIsFatal() {
        #expect(SystemAudioTapCapture.isFatalFormatChange(
            from: Self.format(sampleRate: 48_000, channels: 2),
            to: Self.format(sampleRate: 48_000, channels: 1)
        ))
    }

    private static func format(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }
}

final class StallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stalls: [TimeInterval] = []

    var stalls: [TimeInterval] { lock.withLock { _stalls } }

    @Sendable func record(_ silence: TimeInterval) {
        lock.withLock { _stalls.append(silence) }
    }
}
