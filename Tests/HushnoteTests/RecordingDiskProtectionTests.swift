import Foundation
import Testing
@testable import Hushnote

@Suite("Recording disk protection integration policy")
struct RecordingDiskProtectionTests {
    @Test("Enabled sources determine actual recovery-file rate")
    func sourceFormats() {
        let systemOnly = RecordingDiskProtection.formats(microphoneEnabled: false)
        let both = RecordingDiskProtection.formats(microphoneEnabled: true)

        #expect(systemOnly.map(\.bytesPerSecond) == [192_000])
        #expect(both.map(\.bytesPerSecond) == [192_000, 192_000])
        #expect(
            RecordingDiskProtection.assessment(
                availableBytes: DiskHeadroomPolicy.reserveBytes + 384_000 * 600,
                microphoneEnabled: true
            ).estimatedSeconds == 600
        )
    }

    @Test("Headroom levels map to calm writer diagnostics")
    func diagnosticsMapping() {
        #expect(RecordingDiskProtection.diagnosticsState(for: .healthy) == .healthy)
        #expect(RecordingDiskProtection.diagnosticsState(for: .warning) == .low)
        #expect(RecordingDiskProtection.diagnosticsState(for: .critical) == .critical)
        #expect(RecordingDiskProtection.diagnosticsState(for: .insufficientToStart) == .critical)
    }

    @Test("Start refusal gives a concrete safe cleanup remedy")
    func refusalRemedy() {
        let assessment = RecordingDiskProtection.assessment(
            availableBytes: DiskHeadroomPolicy.reserveBytes + 384_000 * 120,
            microphoneEnabled: true
        )
        let message = RecordingDiskProtection.refusalMessage(assessment)

        #expect(!assessment.canStartRecording)
        #expect(message.contains("2 min"))
        #expect(message.contains("finalized audio"))
        #expect(message.contains("Storage"))
    }

    @Test("Free-space checks are injectable without reading the real volume")
    func injectableChecker() async throws {
        let checker: any RecordingFreeSpaceChecking = StubFreeSpaceChecker(bytes: 987_654_321)
        let bytes = try await checker.availableBytes(at: URL(filePath: "/not-read"))
        #expect(bytes == 987_654_321)
    }
}

private struct StubFreeSpaceChecker: RecordingFreeSpaceChecking {
    let bytes: Int64

    func availableBytes(at _: URL) async throws -> Int64 { bytes }
}
