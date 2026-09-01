import Foundation
import Testing
@testable import Hushnote

@Suite("Recording source health")
struct RecordingSourceHealthPolicyTests {
    @Test("A durable success is accepted while a take is arming")
    func healthyAfterArmingIsAccepted() {
        #expect(
            RecordingSourceHealthPolicy.accepts(
                observed: .healthy,
                current: .arming
            )
        )
    }

    @Test("A late success cannot overwrite an unavailable source")
    func healthyAfterFailureIsRejected() {
        #expect(
            !RecordingSourceHealthPolicy.accepts(
                observed: .healthy,
                current: .unavailable
            )
        )
    }

    @Test("A late success cannot re-enable a disabled source")
    func disabledRejectsLateSuccess() {
        #expect(
            !RecordingSourceHealthPolicy.accepts(
                observed: .healthy,
                current: .disabled
            )
        )
    }

    @Test("A new arming observation can recover after a failure")
    func armingAfterFailureIsAccepted() {
        #expect(
            RecordingSourceHealthPolicy.accepts(
                observed: .arming,
                current: .unavailable
            )
        )
    }

    @Test("Non-success observations are never blocked by prior health")
    func failureRemainsVisible() {
        #expect(
            RecordingSourceHealthPolicy.accepts(
                observed: .unavailable("writer failed"),
                current: .healthy
            )
        )
    }

    @Test("System silence does not demote a verified source")
    func systemSilenceKeepsHealthy() {
        #expect(
            RecordingSourceHealthPolicy.lifecycleAfterLevel(
                source: .system,
                current: .healthy,
                audible: false
            ) == .healthy
        )
    }

    @Test("A level callback cannot verify an arming system source")
    func systemLevelKeepsArming() {
        #expect(
            RecordingSourceHealthPolicy.lifecycleAfterLevel(
                source: .system,
                current: .arming,
                audible: true
            ) == .arming
        )
    }
}
