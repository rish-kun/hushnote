import Foundation
import Testing
import WhisperKit
@testable import Hushnote

/// `DecodingOptions.skipSpecialTokens` defaults to `false`
/// (`Configurations.swift`), and that default is what puts
/// `<|startoftranscript|><|en|><|transcribe|>` and a `<|6.88|>` timestamp token
/// into the text WhisperKit hands back. Both entry points must opt out of it.
@Suite("Whisper is asked to decode without its control vocabulary")
struct SpecialTokenDecodingOptionTests {
    @Test("The live engine decodes with special tokens skipped")
    func liveEngineSkipsSpecialTokens() async throws {
        let meetingID = UUID()
        let decoder = RecordingLiveDecoder([
            [SpecialTokenFixture.segment(start: 0, end: 1, text: "Hello")]
        ])
        let engine = WhisperKitTranscriptionEngine(makeDecoder: { decoder })
        let stream = try await engine.start(
            configuration: SpecialTokenFixture.configuration(meetingID: meetingID)
        )
        var deltas = stream.makeAsyncIterator()

        try await engine.push(
            SpecialTokenFixture.frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0)
        )
        _ = try await deltas.next()

        let options = await decoder.receivedOptions
        #expect(!options.isEmpty)
        #expect(options.allSatisfy { $0.skipSpecialTokens })
        // The option must not cost the word timings the transcript is scrubbed
        // and cited with.
        #expect(options.allSatisfy { $0.wordTimestamps })
    }

    @Test("The final pass decodes with special tokens skipped")
    func finalPassSkipsSpecialTokens() async throws {
        let meetingID = UUID()
        let decoder = RecordingFileDecoder([
            .success([
                SpecialTokenFixture.result([
                    SpecialTokenFixture.segment(start: 0, end: 1, text: "Hello")
                ])
            ])
        ])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        _ = try await transcriber.transcribe(
            meetingID: meetingID,
            tracks: [SpecialTokenFixture.track(meetingID)],
            model: SpeechModelCatalog.whisperSmall,
            revision: 1
        )

        let options = try #require(await decoder.receivedOptions.first)
        #expect(options.skipSpecialTokens)
        #expect(options.wordTimestamps)
    }
}
