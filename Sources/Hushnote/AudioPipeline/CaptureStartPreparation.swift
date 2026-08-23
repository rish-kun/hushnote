import CoreAudio
import Foundation

/// The timing-sensitive part of bringing up a private Core Audio aggregate
/// device. Hardware access stays in `SystemAudioTapCapture`; these loops are
/// closure-driven so retry order and terminal failures can be proven without a
/// process tap or a privacy grant.
enum CaptureStartPreparation {
    static let readinessAttempts = 40
    static let readinessDelay: TimeInterval = 0.025
    static let toleratedReadinessFailures = 5
    static let deviceStartRetryDelays: [TimeInterval] = [0, 0.05, 0.1, 0.2, 0.4]

    struct StreamProbe: Equatable {
        var status: OSStatus
        var byteCount: UInt32

        var hasInputStream: Bool {
            status == noErr && byteCount >= UInt32(MemoryLayout<AudioStreamID>.size)
        }
    }

    /// Waits for the HAL to publish an input stream after the aggregate-device
    /// tap list changes. Early probe failures are treated as graph churn; a
    /// persistent failure is surfaced rather than hidden by the timeout.
    static func waitForInputStream(
        attempts: Int = readinessAttempts,
        delay: TimeInterval = readinessDelay,
        toleratedFailures: Int = toleratedReadinessFailures,
        probe: () -> StreamProbe,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        precondition(attempts > 0)
        for attempt in 0..<attempts {
            let result = probe()
            if result.hasInputStream { return }
            if result.status != noErr, attempt >= toleratedFailures {
                throw AudioPipelineError.coreAudioFailure(
                    "prepare the system-audio input stream",
                    result.status
                )
            }
            if attempt + 1 < attempts { sleep(delay) }
        }
        throw AudioPipelineError.audioCaptureFailed
    }

    /// Retries only the transient HAL illegal-operation response. Every other
    /// result is deterministic and is returned immediately.
    static func startDevice(
        retryDelays: [TimeInterval] = deviceStartRetryDelays,
        start: () -> OSStatus,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        precondition(!retryDelays.isEmpty)
        var lastStatus: OSStatus = noErr
        for delay in retryDelays {
            if delay > 0 { sleep(delay) }
            lastStatus = start()
            if lastStatus == noErr { return }
            guard lastStatus == transientIllegalOperation else {
                throw AudioPipelineError.coreAudioFailure(
                    SystemAudioTapCapture.Operation.startDevice,
                    lastStatus
                )
            }
        }
        throw AudioPipelineError.coreAudioFailure(
            SystemAudioTapCapture.Operation.startDeviceAfterWaiting,
            lastStatus
        )
    }

    static let transientIllegalOperation = OSStatus(bitPattern: 0x6E6F7065)
}
