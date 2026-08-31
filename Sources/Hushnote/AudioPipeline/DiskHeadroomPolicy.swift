import Foundation

/// The durable format written by one recording source.
///
/// Headroom is estimated from the bytes Hushnote will actually append rather
/// than from elapsed time or a generic per-meeting constant. Two enabled mono
/// Float32 sources therefore cost twice as much as one.
struct RecordingStorageFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let bytesPerSample: Int

    init(sampleRate: Double, channelCount: Int, bytesPerSample: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
    }

    static let recoveryPCM = RecordingStorageFormat(
        sampleRate: 48_000,
        channelCount: 1,
        bytesPerSample: MemoryLayout<Float>.size
    )

    var bytesPerSecond: Int64 {
        guard sampleRate.isFinite,
              sampleRate > 0,
              channelCount > 0,
              bytesPerSample > 0
        else { return 0 }

        let value = sampleRate * Double(channelCount) * Double(bytesPerSample)
        guard value.isFinite, value < Double(Int64.max) else { return 0 }
        return Int64(value.rounded(.up))
    }
}

enum DiskHeadroomLevel: Equatable, Sendable {
    case healthy
    case warning
    case critical
    case insufficientToStart
}

struct DiskHeadroomAssessment: Equatable, Sendable {
    let level: DiskHeadroomLevel
    let estimatedSeconds: TimeInterval
    let bytesPerSecond: Int64
    let availableRecordingBytes: Int64

    var canStartRecording: Bool { level != .insufficientToStart }
}

/// Converts free bytes into calm, meaningful recording thresholds.
///
/// The reserve is never counted as recordable capacity. It leaves room for the
/// SQLite commit, CAF headers, and ordinary application/OS writes even when the
/// user's volume is already tight. An active take is not stopped merely because
/// it crosses a threshold; this policy controls preflight and warnings, while a
/// writer failure remains the terminal authority for audio already in flight.
enum DiskHeadroomPolicy {
    static let reserveBytes: Int64 = 512 * 1_024 * 1_024
    static let warningSeconds: TimeInterval = 60 * 60
    static let criticalSeconds: TimeInterval = 15 * 60
    static let minimumStartSeconds: TimeInterval = 5 * 60

    static func assess(
        availableBytes: Int64,
        formats: [RecordingStorageFormat]
    ) -> DiskHeadroomAssessment {
        let bytesPerSecond = formats.reduce(into: Int64(0)) { total, format in
            let rate = format.bytesPerSecond
            guard rate > 0, total <= Int64.max - rate else {
                total = Int64.max
                return
            }
            total += rate
        }
        let recordingBytes = max(0, availableBytes - reserveBytes)

        guard bytesPerSecond > 0, bytesPerSecond != Int64.max else {
            return DiskHeadroomAssessment(
                level: .insufficientToStart,
                estimatedSeconds: 0,
                bytesPerSecond: max(0, bytesPerSecond),
                availableRecordingBytes: recordingBytes
            )
        }

        let seconds = Double(recordingBytes) / Double(bytesPerSecond)
        let level: DiskHeadroomLevel
        if seconds < minimumStartSeconds {
            level = .insufficientToStart
        } else if seconds < criticalSeconds {
            level = .critical
        } else if seconds < warningSeconds {
            level = .warning
        } else {
            level = .healthy
        }

        return DiskHeadroomAssessment(
            level: level,
            estimatedSeconds: seconds,
            bytesPerSecond: bytesPerSecond,
            availableRecordingBytes: recordingBytes
        )
    }
}
