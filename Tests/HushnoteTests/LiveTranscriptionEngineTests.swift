import Foundation
import Testing
import WhisperKit
@testable import Hushnote

@Suite("Live transcription engine")
struct LiveTranscriptionEngineTests {
    @Test("Segments decoded with identical timings still receive unique identifiers")
    func mintsUniqueIdentifiersForCollidingTimings() async throws {
        let meetingID = UUID()
        // WhisperKit permits zero-duration segments and re-applies per-chunk seek
        // offsets under `.vad`, so one decode really can return two segments with
        // the same (start, end).
        let decoder = ScriptedDecoder([
            [
                whisperSegment(start: 0, end: 0, text: "Hi"),
                whisperSegment(start: 0, end: 0, text: "there"),
            ]
        ])
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))
        var deltas = stream.makeAsyncIterator()

        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        let delta = try await deltas.next()

        let ids = try #require(delta?.segments.map(\.id))
        #expect(ids.count == 2)
        #expect(Set(ids).count == ids.count)
    }

    // Guards the invariant the live upsert loop depends on: a committed segment
    // keeps its identifier across decodes, so the store updates one row instead
    // of accumulating a duplicate per revision.
    @Test("A committed segment keeps its identifier across decodes")
    func committedIdentifiersAreStableAcrossDecodes() async throws {
        let meetingID = UUID()
        let decoder = ScriptedDecoder([
            [
                whisperSegment(start: 0, end: 1, text: "Committed"),
                whisperSegment(start: 1, end: 2, text: "tail"),
            ],
            [
                whisperSegment(start: 0, end: 1, text: "Committed"),
                whisperSegment(start: 1, end: 2, text: "tail revised"),
                whisperSegment(start: 2, end: 3, text: "and more"),
            ],
        ])
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(
            configuration: configuration(meetingID: meetingID, confirmationLagSegments: 1)
        )
        var deltas = stream.makeAsyncIterator()

        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        let first = try #require(await deltas.next())
        try await engine.push(frame(meetingID: meetingID, sequence: 2, startMilliseconds: 1_000))
        let second = try #require(await deltas.next())

        #expect(first.stablePrefixCount == 1)
        #expect(second.segments.first?.id == first.segments.first?.id)
        #expect(Set(second.segments.map(\.id)).count == second.segments.count)
    }

    @Test("Words sharing a start time receive unique identifiers")
    func mintsUniqueWordIdentifiers() async throws {
        let meetingID = UUID()
        let decoder = ScriptedDecoder([
            [
                whisperSegment(
                    start: 0,
                    end: 1,
                    text: "one two",
                    words: [word("one", start: 0, end: 0), word("two", start: 0, end: 1)]
                ),
                whisperSegment(
                    start: 1,
                    end: 2,
                    text: "three",
                    words: [word("three", start: 0, end: 1)]
                ),
            ]
        ])
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))
        var deltas = stream.makeAsyncIterator()

        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        let delta = try await deltas.next()

        let wordIDs = try #require(delta?.segments.flatMap { $0.words.map(\.id) })
        #expect(wordIDs.count == 3)
        #expect(Set(wordIDs).count == wordIDs.count)
    }

    @Test("Identifiers are scoped to the meeting that produced them")
    func identifiersDoNotCollideAcrossMeetings() async throws {
        let first = UUID()
        let second = UUID()
        var minted: [[String]] = []
        for meetingID in [first, second] {
            let decoder = ScriptedDecoder([[whisperSegment(start: 0, end: 1, text: "Hello")]])
            let engine = WhisperKitTranscriptionEngine(decoder: decoder)
            let stream = try await engine.start(configuration: configuration(meetingID: meetingID))
            var deltas = stream.makeAsyncIterator()
            try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
            minted.append(try #require(await deltas.next()?.segments.map(\.id)))
        }

        // `transcriptSegments.id` is a database-wide primary key, so two meetings
        // that both start at t=0 must not mint the same identifier.
        #expect(Set(minted[0]).isDisjoint(with: Set(minted[1])))
    }
}

// MARK: - Fixtures

private func configuration(
    meetingID: UUID,
    confirmationLagSegments: Int = 2
) -> TranscriptionSessionConfiguration {
    TranscriptionSessionConfiguration(
        meetingID: meetingID,
        languageCode: "en",
        confirmationLagSegments: confirmationLagSegments,
        minimumDecodeIntervalMilliseconds: 250
    )
}

private func frame(
    meetingID: UUID,
    source: AudioSource = .system,
    sequence: Int64,
    startMilliseconds: Int64,
    milliseconds: Int64 = 1_000
) -> AudioFrame {
    AudioFrame(
        meetingID: meetingID,
        source: source,
        sequenceNumber: sequence,
        startMilliseconds: startMilliseconds,
        sampleRate: 16_000,
        samples: [Float](repeating: 0.01, count: Int(milliseconds) * 16)
    )
}

private func whisperSegment(
    start: Float,
    end: Float,
    text: String,
    words: [WordTiming] = []
) -> TranscriptionSegment {
    TranscriptionSegment(
        start: start,
        end: end,
        text: text,
        avgLogprob: -0.1,
        words: words.isEmpty ? nil : words
    )
}

private func word(_ text: String, start: Float, end: Float) -> WordTiming {
    WordTiming(word: text, tokens: [], start: start, end: end, probability: 0.9)
}

/// Replays a fixed list of decoder responses so engine behaviour can be tested
/// without a Core ML model.
private actor ScriptedDecoder: LiveSpeechDecoder {
    private let scripts: [[TranscriptionSegment]]
    private var callCount = 0
    private(set) var receivedSampleCounts: [Int] = []

    init(_ scripts: [[TranscriptionSegment]]) {
        self.scripts = scripts
    }

    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        receivedSampleCounts.append(samples.count)
        let index = min(callCount, scripts.count - 1)
        callCount += 1
        let segments = scripts[index]
        return [
            TranscriptionResult(
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                language: "en",
                timings: TranscriptionTimings()
            )
        ]
    }
}
