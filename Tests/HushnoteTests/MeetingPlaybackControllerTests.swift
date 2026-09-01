import Foundation
import Testing
@testable import Hushnote

@Suite("Synchronized meeting playback")
@MainActor
struct MeetingPlaybackControllerTests {
    private func line(
        _ id: String,
        speaker: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptLineItem {
        TranscriptLineItem(
            id: UUID(),
            segmentID: id,
            speaker: speaker,
            start: start,
            end: end,
            text: id,
            isProvisional: false
        )
    }

    @Test("Controller seeks on the meeting timeline and controls rate")
    func controllerTransport() async throws {
        let engine = FakeMeetingAudioPlayer(duration: 120)
        let controller = MeetingPlaybackController(engine: engine)
        let meetingID = UUID()
        let transcript = [
            line("a", speaker: "Alex", start: 10, end: 20),
            line("b", speaker: "Sam", start: 30, end: 40)
        ]
        try await controller.load(
            meetingID: meetingID,
            tracks: [MeetingAudioTrack(
                meetingID: meetingID,
                source: .system,
                fileURL: URL(filePath: "/tmp/source.caf"),
                sampleRate: 48_000,
                channelCount: 1,
                durationMilliseconds: 120_000,
                isComplete: true
            )],
            transcript: transcript,
            markers: []
        )

        controller.seek(to: 12)
        #expect(engine.seekPosition == 12)
        #expect(controller.activeSegmentID == "a")
        controller.skip(seconds: 15)
        #expect(controller.position == 27)
        controller.setRate(1.5)
        controller.play()
        #expect(engine.playRate == 1.5)
        #expect(controller.isPlaying)
        controller.pause()
        #expect(!controller.isPlaying)
    }

    @Test("Active highlighting and silence skipping follow transcript evidence")
    func playbackPolicies() {
        let transcript = [
            line("a", speaker: "Alex", start: 0, end: 4),
            line("b", speaker: "Sam", start: 20, end: 25)
        ]
        #expect(MeetingPlaybackPolicy.activeSegmentID(at: 2, transcript: transcript) == "a")
        #expect(MeetingPlaybackPolicy.activeSegmentID(at: 10, transcript: transcript) == nil)
        #expect(MeetingPlaybackPolicy.silenceSkipTarget(at: 10, transcript: transcript) == 20)
        #expect(MeetingPlaybackPolicy.silenceSkipTarget(at: 3, transcript: transcript) == nil)
    }

    @Test("Jump inventory includes chapters, first speaker appearances, and markers")
    func jumpPoints() {
        let meetingID = UUID()
        let sessionID = UUID()
        let transcript = [
            line("a", speaker: "Alex", start: 0, end: 2),
            line("b", speaker: "Sam", start: 310, end: 312),
            line("c", speaker: "Alex", start: 320, end: 322)
        ]
        let marker = RecordingMarker(
            meetingID: meetingID,
            sessionID: sessionID,
            type: .decision,
            timelineMilliseconds: 12_000
        )
        let points = MeetingPlaybackPolicy.jumpPoints(transcript: transcript, markers: [marker])

        #expect(points.filter { $0.kind == .chapter }.count == 2)
        #expect(points.filter { $0.kind == .speaker }.map(\.title) == ["Alex", "Sam", "Alex"])
        #expect(points.contains { $0.kind == .marker && $0.seconds == 12 && $0.title == "Decision" })
    }
}

@MainActor
private final class FakeMeetingAudioPlayer: MeetingAudioPlaying {
    let preparedDuration: TimeInterval
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var seekPosition: TimeInterval?
    var playRate: Float?

    init(duration: TimeInterval) { preparedDuration = duration }

    func prepare(tracks: [MeetingAudioTrack]) async throws -> TimeInterval { preparedDuration }
    func play(rate: Float) {
        playRate = rate
        isPlaying = true
    }
    func pause() { isPlaying = false }
    func seek(to seconds: TimeInterval) {
        seekPosition = seconds
        currentTime = seconds
    }
    func stop() {
        isPlaying = false
        currentTime = 0
    }
}
