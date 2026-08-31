import Foundation
import Testing
@testable import Hushnote

@Suite("Recording disk headroom")
struct DiskHeadroomPolicyTests {
    @Test("Recovery PCM uses the bytes written by one normalized source")
    func recoveryPCMRate() {
        #expect(RecordingStorageFormat.recoveryPCM.bytesPerSecond == 192_000)
    }

    @Test("Two source writers halve the available recording time")
    func twoSourcesCostTwiceAsMuch() {
        let capacity = DiskHeadroomPolicy.reserveBytes + 1_382_400_000
        let one = DiskHeadroomPolicy.assess(
            availableBytes: capacity,
            formats: [.recoveryPCM]
        )
        let two = DiskHeadroomPolicy.assess(
            availableBytes: capacity,
            formats: [.recoveryPCM, .recoveryPCM]
        )

        #expect(abs(one.estimatedSeconds - 7_200) < 0.001)
        #expect(abs(two.estimatedSeconds - 3_600) < 0.001)
        #expect(one.bytesPerSecond == 192_000)
        #expect(two.bytesPerSecond == 384_000)
    }

    @Test("Thresholds distinguish warning, critical, and start refusal")
    func thresholdLevels() {
        #expect(assessment(minutes: 61).level == .healthy)
        #expect(assessment(minutes: 60).level == .healthy)
        #expect(assessment(minutes: 59).level == .warning)
        #expect(assessment(minutes: 15).level == .warning)
        #expect(assessment(minutes: 14).level == .critical)
        #expect(assessment(minutes: 5).level == .critical)
        #expect(assessment(minutes: 4).level == .insufficientToStart)
    }

    @Test("The fixed reserve is not advertised as recording time")
    func reserveIsExcluded() {
        let assessment = DiskHeadroomPolicy.assess(
            availableBytes: DiskHeadroomPolicy.reserveBytes,
            formats: [.recoveryPCM]
        )

        #expect(assessment.availableRecordingBytes == 0)
        #expect(assessment.estimatedSeconds == 0)
        #expect(!assessment.canStartRecording)
    }

    @Test("No valid enabled source cannot pass preflight")
    func invalidFormatsCannotStart() {
        let invalid = RecordingStorageFormat(
            sampleRate: .nan,
            channelCount: 0,
            bytesPerSample: 0
        )
        let assessment = DiskHeadroomPolicy.assess(
            availableBytes: Int64.max,
            formats: [invalid]
        )

        #expect(assessment.level == .insufficientToStart)
        #expect(!assessment.canStartRecording)
    }

    private func assessment(minutes: Int) -> DiskHeadroomAssessment {
        let recordable = Int64(minutes * 60) * RecordingStorageFormat.recoveryPCM.bytesPerSecond
        return DiskHeadroomPolicy.assess(
            availableBytes: DiskHeadroomPolicy.reserveBytes + recordable,
            formats: [.recoveryPCM]
        )
    }
}
