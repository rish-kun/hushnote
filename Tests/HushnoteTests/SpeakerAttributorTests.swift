import Foundation
import Testing
@testable import Hushnote

@Suite("Speaker attribution")
struct SpeakerAttributorTests {
    @Test("Microphone segments always use the configured local identity")
    func labelsMicrophoneDirectly() {
        let meetingID = UUID()
        let segment = transcriptSegment("mic", meetingID: meetingID, source: .microphone, start: 0, end: 100)

        let result = SpeakerAttributor.assign(
            turns: [],
            to: [segment],
            microphoneSpeakerID: "me",
            microphoneSpeakerName: "Rishit"
        )

        #expect(result[0].speakerID == "me")
        #expect(result[0].speakerName == "Rishit")
    }

    @Test("System segments use the turn with greatest overlap")
    func choosesGreatestOverlap() {
        let meetingID = UUID()
        let segment = transcriptSegment("remote", meetingID: meetingID, source: .system, start: 100, end: 500)
        let turns = [
            SpeakerTurn(id: "a", speakerID: "A", startMilliseconds: 0, endMilliseconds: 250),
            SpeakerTurn(id: "b", speakerID: "B", startMilliseconds: 200, endMilliseconds: 600),
        ]

        let result = SpeakerAttributor.assign(turns: turns, to: [segment])

        #expect(result[0].speakerID == "B")
        #expect(result[0].speakerName == "Speaker B")
    }

    @Test("Equal overlap resolves deterministically by speaker identifier")
    func deterministicTieBreak() {
        let meetingID = UUID()
        let segment = transcriptSegment("remote", meetingID: meetingID, source: .system, start: 100, end: 300)
        let turns = [
            SpeakerTurn(id: "z", speakerID: "Z", startMilliseconds: 100, endMilliseconds: 200),
            SpeakerTurn(id: "a", speakerID: "A", startMilliseconds: 200, endMilliseconds: 300),
        ]

        let result = SpeakerAttributor.assign(turns: turns, to: [segment])

        #expect(result[0].speakerID == "A")
    }

    @Test("Non-overlapping system speech remains anonymous")
    func noOverlapLeavesSpeakerUnset() {
        let meetingID = UUID()
        var segment = transcriptSegment("remote", meetingID: meetingID, source: .system, start: 500, end: 600)
        segment.speakerID = "stale"
        segment.speakerName = "Stale"

        let result = SpeakerAttributor.assign(
            turns: [SpeakerTurn(id: "a", speakerID: "A", startMilliseconds: 0, endMilliseconds: 100)],
            to: [segment]
        )

        #expect(result[0].speakerID == nil)
        #expect(result[0].speakerName == nil)
    }
}

private func transcriptSegment(
    _ id: String,
    meetingID: UUID,
    source: AudioSource,
    start: Int64,
    end: Int64
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        meetingID: meetingID,
        source: source,
        startMilliseconds: start,
        endMilliseconds: end,
        text: id
    )
}
