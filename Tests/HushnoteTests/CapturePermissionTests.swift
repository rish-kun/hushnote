import Foundation
import Testing
@testable import Hushnote

/// `'nope'` (kAudioHardwareIllegalOperationError) is what the HAL returns both
/// for a genuinely transient device-graph update and for a privacy denial. The
/// two arrive at different operations, which is what tells them apart:
/// tap creation is where TCC refuses, and `AudioDeviceStart` is where the real
/// transient occurs.
@Suite("Capture permission errors")
struct CapturePermissionTests {
    private static let nope = OSStatus(bitPattern: 0x6E6F7065)

    @Test("A refused tap is reported as a permission problem")
    func refusedTapIsPermissionDenied() {
        let mapped = AudioPipeline.mapCaptureError(
            AudioPipelineError.coreAudioFailure(SystemAudioTapCapture.Operation.createTap, Self.nope)
        )

        #expect(mapped as? AudioPipelineError == .permissionDenied)
    }

    @Test("The permission message names the toggle to turn on")
    func permissionMessagePointsAtTheToggle() {
        let message = AudioPipelineError.permissionDenied.localizedDescription

        #expect(message.contains("System Audio Recording"))
        #expect(!message.contains("temporarily busy"))
    }

    /// This one really is transient, and `startDeviceWithRecovery` already
    /// retries it. Relabelling it as a permission problem would send the user
    /// to a toggle that is already on.
    @Test("A busy device start keeps its transient meaning")
    func busyStartIsNotAPermissionProblem() {
        let error = AudioPipelineError.coreAudioFailure(
            SystemAudioTapCapture.Operation.startDevice,
            Self.nope
        )
        let mapped = AudioPipeline.mapCaptureError(error)

        #expect(mapped as? AudioPipelineError == error)
        #expect(mapped.localizedDescription.contains("temporarily busy"))
    }

    @Test("A tap failure with another status is left alone")
    func otherTapFailuresAreUnchanged() {
        let error = AudioPipelineError.coreAudioFailure(
            SystemAudioTapCapture.Operation.createTap,
            OSStatus(-4)
        )

        #expect(AudioPipeline.mapCaptureError(error) as? AudioPipelineError == error)
    }

    @Test("Errors that are not Core Audio statuses pass straight through")
    func unrelatedErrorsAreUnchanged() {
        let error = AudioPipelineError.writerFailed("disk full")

        #expect(AudioPipeline.mapCaptureError(error) as? AudioPipelineError == error)
    }
}
