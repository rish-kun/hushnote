import Foundation
import Testing
import WhisperKit
@testable import Hushnote

/// Defence in depth behind `DecodingOptions.skipSpecialTokens`. The option is a
/// library default away from flipping back and a new model can introduce a
/// control token WhisperKit does not classify as special, so nothing shaped
/// like `<|…|>` is allowed out of the speech pipeline regardless of what the
/// decoder returns. Every polluted string below is verbatim from a real
/// meeting the user recorded.
@Suite("Whisper special tokens never reach the transcript")
struct SpecialTokenLeakTests {
    @Test("The live engine strips special tokens out of segment text")
    func liveEngineStripsSpecialTokensFromSegmentText() async throws {
        let meetingID = UUID()
        let decoder = RecordingLiveDecoder([
            [
                SpecialTokenFixture.segment(
                    start: 0,
                    end: 6.88,
                    text: SpecialTokenFixture.pollutedFirstSegment
                ),
                SpecialTokenFixture.segment(
                    start: 6.88,
                    end: 12.06,
                    text: SpecialTokenFixture.pollutedSecondSegment
                ),
                SpecialTokenFixture.segment(
                    start: 12.06,
                    end: 18,
                    text: SpecialTokenFixture.pollutedThirdSegment
                ),
            ]
        ])
        let engine = WhisperKitTranscriptionEngine(makeDecoder: { decoder })
        let stream = try await engine.start(
            configuration: SpecialTokenFixture.configuration(meetingID: meetingID)
        )
        var deltas = stream.makeAsyncIterator()

        try await engine.push(
            SpecialTokenFixture.frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0)
        )
        let delta = try #require(await deltas.next())

        #expect(
            delta.segments.map(\.text) == [
                "Also, do not touch the releases.",
                "I'll only increase the release patch after it has been merged to me.",
                "So whatever changes you have to make has to be within skills, within scripts.",
            ]
        )
    }

    @Test("Stripping special tokens leaves segment timings alone")
    func liveEngineKeepsTimingsWhileStripping() async throws {
        let meetingID = UUID()
        let decoder = RecordingLiveDecoder([
            [
                SpecialTokenFixture.segment(
                    start: 0,
                    end: 6.88,
                    text: SpecialTokenFixture.pollutedFirstSegment
                )
            ]
        ])
        let engine = WhisperKitTranscriptionEngine(makeDecoder: { decoder })
        let stream = try await engine.start(
            configuration: SpecialTokenFixture.configuration(meetingID: meetingID)
        )
        var deltas = stream.makeAsyncIterator()

        try await engine.push(
            SpecialTokenFixture.frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0)
        )
        let delta = try #require(await deltas.next())

        // The leaked tokens encode the same timings the segment carries, but
        // WhisperKit derives `start`/`end` from the timestamp token *ids*
        // (`SegmentSeeker.swift`, `Float(timestampTokens.first! - timeToken)`),
        // never from the text. Cleaning the text must not move them.
        let segment = try #require(delta.segments.first)
        #expect(segment.startMilliseconds == 0)
        #expect(segment.endMilliseconds == 6_880)
    }

    @Test("The live engine strips special tokens out of word text")
    func liveEngineStripsSpecialTokensFromWordText() async throws {
        let meetingID = UUID()
        let decoder = RecordingLiveDecoder([
            [
                SpecialTokenFixture.segment(
                    start: 0,
                    end: 2,
                    text: "<|0.00|> Also, do not touch<|2.00|>",
                    words: [
                        SpecialTokenFixture.word("<|startoftranscript|>", start: 0, end: 0),
                        SpecialTokenFixture.word(" Also,", start: 0, end: 1),
                        SpecialTokenFixture.word("<|2.00|>", start: 1, end: 1),
                        SpecialTokenFixture.word(" do not touch", start: 1, end: 2),
                    ]
                )
            ]
        ])
        let engine = WhisperKitTranscriptionEngine(makeDecoder: { decoder })
        let stream = try await engine.start(
            configuration: SpecialTokenFixture.configuration(meetingID: meetingID)
        )
        var deltas = stream.makeAsyncIterator()

        try await engine.push(
            SpecialTokenFixture.frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0)
        )
        let delta = try #require(await deltas.next())

        // A word made of nothing but control tokens carries no speech, so it is
        // dropped rather than stored as an empty row that scrubbing would seek
        // to. The leading space is Whisper's word boundary and is preserved.
        let words = try #require(delta.segments.first?.words)
        #expect(words.map(\.text) == [" Also,", " do not touch"])
    }

    @Test("The final pass strips special tokens out of segment text")
    func finalPassStripsSpecialTokensFromSegmentText() async throws {
        let meetingID = UUID()
        let decoder = RecordingFileDecoder([
            .success([
                SpecialTokenFixture.result([
                    SpecialTokenFixture.segment(
                        start: 0,
                        end: 6.88,
                        text: SpecialTokenFixture.pollutedFirstSegment
                    ),
                    SpecialTokenFixture.segment(
                        start: 8.4,
                        end: 14,
                        text: SpecialTokenFixture.pollutedLowercaseSegment
                    ),
                ])
            ])
        ])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        let snapshot = try await transcriber.transcribe(
            meetingID: meetingID,
            tracks: [SpecialTokenFixture.track(meetingID)],
            model: SpeechModelCatalog.whisperSmall,
            revision: 1
        )

        #expect(
            snapshot.segments.map(\.text) == [
                "Also, do not touch the releases.",
                "okay take light i'll uh you can get started on it",
            ]
        )
    }

    @Test("The final pass strips special tokens out of word text")
    func finalPassStripsSpecialTokensFromWordText() async throws {
        let meetingID = UUID()
        let decoder = RecordingFileDecoder([
            .success([
                SpecialTokenFixture.result([
                    SpecialTokenFixture.segment(
                        start: 0,
                        end: 2,
                        text: "<|0.00|> Yeah, that's about it.<|2.00|>",
                        words: [
                            SpecialTokenFixture.word("<|0.00|>", start: 0, end: 0),
                            SpecialTokenFixture.word(" Yeah,", start: 0, end: 1),
                            SpecialTokenFixture.word(" that's about it.", start: 1, end: 2),
                        ]
                    )
                ])
            ])
        ])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        let snapshot = try await transcriber.transcribe(
            meetingID: meetingID,
            tracks: [SpecialTokenFixture.track(meetingID)],
            model: SpeechModelCatalog.whisperSmall,
            revision: 1
        )

        let words = try #require(snapshot.segments.first?.words)
        #expect(words.map(\.text) == [" Yeah,", " that's about it."])
    }

    @Test("A segment that is nothing but control tokens is dropped")
    func dropsSegmentsMadeEntirelyOfSpecialTokens() async throws {
        let meetingID = UUID()
        let decoder = RecordingFileDecoder([
            .success([
                SpecialTokenFixture.result([
                    SpecialTokenFixture.segment(
                        start: 0,
                        end: 1,
                        text: "<|startoftranscript|><|en|><|transcribe|>"
                    ),
                    SpecialTokenFixture.segment(
                        start: 1,
                        end: 2,
                        text: "<|1.00|> Real speech.<|2.00|>"
                    ),
                ])
            ])
        ])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        let snapshot = try await transcriber.transcribe(
            meetingID: meetingID,
            tracks: [SpecialTokenFixture.track(meetingID)],
            model: SpeechModelCatalog.whisperSmall,
            revision: 1
        )

        #expect(snapshot.segments.map(\.text) == ["Real speech."])
    }

    // MARK: - The sanitizer must not damage real speech

    @Test(
        "Text that merely contains angle brackets or pipes survives untouched",
        arguments: [
            "if x < y | z > 0 then bail",
            "we set the threshold to < 5% and the pipe | is the separator",
            "he said the vertical bar |, then paused",
            "a <| b |> c",
            "compare a<b and c>d",
            "the tag <div> stays and so does </div>",
            "pipes||everywhere but no tokens",
            "<not a token>",
            "<|has space|>",
            "<|way too long to be any control token whisper has ever emitted|>",
        ]
    )
    func preservesLegitimateText(_ text: String) {
        #expect(WhisperSpecialToken.stripped(from: text) == text)
    }

    @Test("Only the control token is removed, not the speech around it")
    func removesOnlyTheTokens() {
        #expect(
            WhisperSpecialToken.stripped(from: SpecialTokenFixture.pollutedFirstSegment)
                == " Also, do not touch the releases."
        )
        // One space where a token sat between two words, not two.
        #expect(WhisperSpecialToken.stripped(from: "a <|6.88|> b") == "a b")
        #expect(WhisperSpecialToken.stripped(from: "a<|6.88|>b") == "ab")
        // An unterminated `<|` is speech, not a token, and must not eat the tail.
        #expect(WhisperSpecialToken.stripped(from: "trailing <| forever") == "trailing <| forever")
        // A real token nested inside a non-token span is still found, and the
        // space it occupied collapses the same way it does anywhere else.
        #expect(WhisperSpecialToken.stripped(from: "a <| b <|en|> c") == "a <| b c")
    }
}
