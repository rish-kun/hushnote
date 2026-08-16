import Foundation
import Testing
import WhisperKit
@testable import Hushnote

@Suite("Final transcription pass")
struct FinalTranscriberTests {
    @Test("A track that fails to decode does not discard the tracks that succeeded")
    func keepsSuccessfulTracksWhenOneFails() async throws {
        let meetingID = UUID()
        let decoder = StubFileDecoder([
            .failure(StubFailure.damagedFile),
            .success([
                result(segments: [
                    whisperSegment(start: 0, end: 1, text: "Recovered speech"),
                    whisperSegment(start: 1, end: 2, text: "and more"),
                ])
            ]),
        ])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        let snapshot = try await transcriber.transcribe(
            meetingID: meetingID,
            tracks: [track(meetingID, .microphone), track(meetingID, .system)],
            model: SpeechModelCatalog.whisperSmall,
            revision: 3
        )

        #expect(snapshot.segments.map(\.text) == ["Recovered speech", "and more"])
        #expect(snapshot.segments.allSatisfy { $0.source == .system })
        let ids = snapshot.segments.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("A pass where every track fails reports the decoder's own failure")
    func reportsFailureWhenNothingDecodes() async throws {
        let meetingID = UUID()
        let decoder = StubFileDecoder([.failure(StubFailure.damagedFile)])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        await #expect(throws: StubFailure.damagedFile) {
            _ = try await transcriber.transcribe(
                meetingID: meetingID,
                tracks: [track(meetingID, .system)],
                model: SpeechModelCatalog.whisperSmall,
                revision: 1
            )
        }
    }

    @Test("The single-use final model is not prewarmed")
    func doesNotPrewarmTheFinalModel() {
        let configuration = WhisperKitFinalTranscriber
            .modelConfiguration(for: SpeechModelCatalog.whisperSmall)

        // Prewarm trades a 2x load time for lower peak compilation memory. This
        // model is loaded, used once and thrown away, so the trade is all cost.
        #expect(configuration.prewarm == false)
    }
}

// MARK: - Fixtures

private enum StubFailure: Error {
    case damagedFile
}

private func track(_ meetingID: UUID, _ source: AudioSource) -> MeetingAudioTrack {
    MeetingAudioTrack(
        meetingID: meetingID,
        source: source,
        fileURL: URL(filePath: "/tmp/hushnote-tests/\(source.rawValue).caf"),
        sampleRate: 16_000,
        channelCount: 1,
        isComplete: true
    )
}

private func whisperSegment(start: Float, end: Float, text: String) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text, avgLogprob: -0.2)
}

private func result(segments: [TranscriptionSegment]) -> TranscriptionResult {
    TranscriptionResult(
        text: segments.map(\.text).joined(separator: " "),
        segments: segments,
        language: "en",
        timings: TranscriptionTimings()
    )
}

/// Returns one canned outcome per audio path, the way WhisperKit does.
private struct StubFileDecoder: FinalSpeechDecoder, @unchecked Sendable {
    let outcomes: [Result<[TranscriptionResult], any Error>]

    init(_ outcomes: [Result<[TranscriptionResult], any Error>]) {
        self.outcomes = outcomes
    }

    func decodeFiles(
        paths: [String],
        options: DecodingOptions
    ) async -> [Result<[TranscriptionResult], any Error>] {
        outcomes
    }
}
