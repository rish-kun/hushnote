import Foundation
import Testing
@testable import Hushnote

@Suite("Audio event observation")
struct AudioEventObservationPolicyTests {
    @Test("Current pipeline and identity are admitted")
    func currentObserverIsAdmitted() {
        let identity = Self.identity()

        #expect(
            AudioEventObservationPolicy.accepts(
                observer: identity,
                current: identity,
                isCurrentPipeline: true
            )
        )
    }

    @Test("A buffered event from an old generation is rejected")
    func oldGenerationIsRejected() {
        let observer = Self.identity()
        let current = AudioEventObservationIdentity(
            meetingID: observer.meetingID,
            generation: UUID()
        )

        #expect(
            !AudioEventObservationPolicy.accepts(
                observer: observer,
                current: current,
                isCurrentPipeline: true
            )
        )
    }

    @Test("A buffered event from another meeting is rejected")
    func oldMeetingIsRejected() {
        let observer = Self.identity()
        let current = AudioEventObservationIdentity(
            meetingID: UUID(),
            generation: observer.generation
        )

        #expect(
            !AudioEventObservationPolicy.accepts(
                observer: observer,
                current: current,
                isCurrentPipeline: true
            )
        )
    }

    @Test("An observer on a replaced pipeline is rejected even with matching IDs")
    func replacedPipelineIsRejected() {
        let identity = Self.identity()

        #expect(
            !AudioEventObservationPolicy.accepts(
                observer: identity,
                current: identity,
                isCurrentPipeline: false
            )
        )
        #expect(
            !AudioEventObservationPolicy.accepts(
                observer: identity,
                current: nil,
                isCurrentPipeline: true
            )
        )
    }

    private static func identity() -> AudioEventObservationIdentity {
        AudioEventObservationIdentity(meetingID: UUID(), generation: UUID())
    }
}
