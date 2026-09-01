import Foundation

protocol RecordingFreeSpaceChecking: Sendable {
    func availableBytes(at url: URL) async throws -> Int64
}

struct VolumeRecordingFreeSpaceChecker: RecordingFreeSpaceChecking {
    func availableBytes(at url: URL) async throws -> Int64 {
        let task = Task.detached(priority: .utility) {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return max(0, capacity)
            }
            if let capacity = values.volumeAvailableCapacity {
                return Int64(max(0, capacity))
            }
            throw CocoaError(.fileReadUnknown)
        }
        return try await task.value
    }
}

/// Adapts byte-level headroom to source configuration and the calm diagnostics
/// vocabulary. Cleanup is deliberately not performed here: only finalized raw
/// audio may be removed, and the active recovery take always wins.
enum RecordingDiskProtection {
    static func formats(microphoneEnabled: Bool) -> [RecordingStorageFormat] {
        microphoneEnabled ? [.recoveryPCM, .recoveryPCM] : [.recoveryPCM]
    }

    static func assessment(
        availableBytes: Int64,
        microphoneEnabled: Bool
    ) -> DiskHeadroomAssessment {
        DiskHeadroomPolicy.assess(
            availableBytes: availableBytes,
            formats: formats(microphoneEnabled: microphoneEnabled)
        )
    }

    static func diagnosticsState(for level: DiskHeadroomLevel) -> RecordingDiskState {
        switch level {
        case .healthy: .healthy
        case .warning: .low
        case .critical, .insufficientToStart: .critical
        }
    }

    static func refusalMessage(_ assessment: DiskHeadroomAssessment) -> String {
        let minutes = max(0, Int(assessment.estimatedSeconds / 60))
        return "Only about \(minutes) min of recording space remains. Free space or remove finalized audio in Storage, then try again."
    }
}
