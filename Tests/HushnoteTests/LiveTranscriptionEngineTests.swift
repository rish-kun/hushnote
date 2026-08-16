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

    @Test("Committed audio leaves the live window instead of being re-decoded")
    func dropsCommittedAudioFromTheWindow() async throws {
        let meetingID = UUID()
        let decoder = WindowMirroringDecoder()
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(
            configuration: configuration(meetingID: meetingID, confirmationLagSegments: 2)
        )
        var deltas = stream.makeAsyncIterator()

        var last: TranscriptDelta?
        for index in 0..<60 {
            try await engine.push(frame(
                meetingID: meetingID,
                sequence: Int64(index) + 1,
                startMilliseconds: Int64(index) * 1_000
            ))
            last = try await deltas.next()
        }

        let windows = await decoder.receivedSampleCounts
        // A minute of speech must never be re-encoded from t=0. Only the audio
        // after the committed prefix is still in play.
        #expect(windows.max() ?? 0 <= 16_000 * 6)
        // Timestamps stay in meeting time even though the window no longer
        // starts at t=0.
        #expect(last?.segments.last?.endMilliseconds == 60_000)
        #expect(last?.segments.count == 60)
    }

    @Test("The live window is capped even when nothing ever commits")
    func capsTheWindowWhenNothingCommits() async throws {
        let meetingID = UUID()
        let decoder = ScriptedDecoder([[]])
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))
        var deltas = stream.makeAsyncIterator()

        for index in 0..<60 {
            try await engine.push(frame(
                meetingID: meetingID,
                sequence: Int64(index) + 1,
                startMilliseconds: Int64(index) * 1_000
            ))
            _ = try await deltas.next()
        }

        // 480_000 samples is WhisperKit's own 30s window; past it every decode
        // pays for VAD chunking on top of an unbounded buffer.
        let windows = await decoder.receivedSampleCounts
        #expect(windows.max() ?? 0 <= 480_000)
    }

    @Test("Clip timestamps are never sent, because the VAD path discards them")
    func neverSendsClipTimestamps() async throws {
        let meetingID = UUID()
        let decoder = WindowMirroringDecoder()
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))
        var deltas = stream.makeAsyncIterator()

        for index in 0..<6 {
            try await engine.push(frame(
                meetingID: meetingID,
                sequence: Int64(index) + 1,
                startMilliseconds: Int64(index) * 1_000
            ))
            _ = try await deltas.next()
        }

        let options = await decoder.receivedOptions
        #expect(options.count == 6)
        #expect(options.allSatisfy { $0.clipTimestamps.isEmpty })
    }

    @Test("A hypothesis never carries a segment that overlaps committed audio")
    func clipsTailSegmentsThatReachBackIntoFrozenAudio() async throws {
        let meetingID = UUID()
        // The second segment claims to end past the audio it was decoded from,
        // which pushes the committed boundary beyond the window origin. The next
        // decode then reports speech that starts inside already-frozen audio.
        let decoder = ScriptedDecoder([
            [whisperSegment(start: 0, end: 1, text: "one"), whisperSegment(start: 1, end: 5, text: "two")],
            [whisperSegment(start: 0, end: 4, text: "two again")],
        ])
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(
            configuration: configuration(meetingID: meetingID, confirmationLagSegments: 0)
        )
        var deltas = stream.makeAsyncIterator()

        try await engine.push(frame(
            meetingID: meetingID,
            sequence: 1,
            startMilliseconds: 0,
            milliseconds: 2_000
        ))
        _ = try await deltas.next()
        try await engine.push(frame(meetingID: meetingID, sequence: 2, startMilliseconds: 2_000))
        let delta = try #require(await deltas.next())

        let overlaps = zip(delta.segments, delta.segments.dropFirst())
            .contains { $0.endMilliseconds > $1.startMilliseconds }
        #expect(!overlaps)
    }

    @Test("push enqueues audio instead of waiting for the decoder")
    func pushReturnsBeforeTheDecodeCompletes() async throws {
        let meetingID = UUID()
        let decoder = GatedDecoder()
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))
        var deltas = stream.makeAsyncIterator()

        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        await decoder.waitForStart(count: 1)
        let completedWhenPushReturned = await decoder.completedCalls
        // A second chunk must be accepted while the first decode is still
        // running. The capture stream buffers only the newest 256 chunks, so a
        // blocking push silently discards audio that is already on disk.
        try await engine.push(frame(meetingID: meetingID, sequence: 2, startMilliseconds: 1_000))
        await decoder.open()
        _ = try await deltas.next()

        #expect(completedWhenPushReturned == 0)
    }

    @Test("cancel stops the in-flight decode and cannot be resurrected")
    func cancelStopsTheInFlightDecode() async throws {
        let meetingID = UUID()
        let decoder = GatedDecoder()
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))

        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        await decoder.waitForStart(count: 1)
        await engine.cancel()
        await decoder.waitForCancellation(count: 1)

        #expect(await decoder.cancelledCalls == 1)
        // The stream is closed and no delta from the dead session may arrive.
        var received = 0
        for try await _ in stream { received += 1 }
        #expect(received == 0)

        // A cancelled session must not accept audio, and the next session must
        // start from a clean buffer rather than inheriting the dead one.
        await #expect(throws: SpeechPipelineError.sessionNotRunning) {
            try await engine.push(frame(meetingID: meetingID, sequence: 2, startMilliseconds: 1_000))
        }
        await decoder.open()
        let next = try await engine.start(configuration: configuration(meetingID: meetingID))
        var deltas = next.makeAsyncIterator()
        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        let delta = try #require(await deltas.next())
        #expect(delta.revision == 1)
    }

    @Test("finish waits for the in-flight decode instead of starting a second one")
    func finishDoesNotDecodeConcurrently() async throws {
        let meetingID = UUID()
        let decoder = GatedDecoder()
        let engine = WhisperKitTranscriptionEngine(decoder: decoder)
        let stream = try await engine.start(configuration: configuration(meetingID: meetingID))

        let collected = Task {
            var deltas: [TranscriptDelta] = []
            for try await delta in stream { deltas.append(delta) }
            return deltas
        }

        try await engine.push(frame(meetingID: meetingID, sequence: 1, startMilliseconds: 0))
        await decoder.waitForStart(count: 1)
        async let finished: Void = engine.finish()
        // Let both the live decode and the final decode run. WhisperKit has
        // mutable timing and decoder state and gives no re-entrancy guarantee,
        // so they must not overlap.
        await decoder.open()
        try await finished

        #expect(await decoder.peakConcurrentCalls == 1)
        let deltas = try await collected.value
        // A late non-final delta landing after the final one would un-finalize
        // the transcript.
        #expect(deltas.last?.isFinal == true)
        #expect(deltas.filter(\.isFinal).count == 1)
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
    private(set) var receivedOptions: [DecodingOptions] = []

    init(_ scripts: [[TranscriptionSegment]]) {
        self.scripts = scripts
    }

    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        receivedSampleCounts.append(samples.count)
        receivedOptions.append(options)
        let index = min(callCount, scripts.count - 1)
        callCount += 1
        return [result(segments: scripts[index])]
    }
}

/// Behaves the way Whisper does: it only ever sees the window it is handed, and
/// reports timings relative to the start of that window.
private actor WindowMirroringDecoder: LiveSpeechDecoder {
    private(set) var receivedSampleCounts: [Int] = []
    private(set) var receivedOptions: [DecodingOptions] = []

    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        receivedSampleCounts.append(samples.count)
        receivedOptions.append(options)
        let seconds = samples.count / 16_000
        let segments = (0..<seconds).map { index in
            whisperSegment(
                start: Float(index),
                end: Float(index + 1),
                text: "second \(index)"
            )
        }
        return [result(segments: segments)]
    }
}

/// Holds every decode open until the test releases it, so the engine's
/// concurrency can be observed. The wait is bounded and cancellable: a broken
/// engine makes the test fail slowly rather than hang.
private actor GatedDecoder: LiveSpeechDecoder {
    private var isOpen = false
    private(set) var startedCalls = 0
    private(set) var completedCalls = 0
    private(set) var cancelledCalls = 0
    private(set) var activeCalls = 0
    private(set) var peakConcurrentCalls = 0

    func open() {
        isOpen = true
    }

    func waitForStart(count: Int) async {
        await poll { self.startedCalls >= count }
    }

    func waitForCancellation(count: Int) async {
        await poll { self.cancelledCalls >= count }
    }

    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        startedCalls += 1
        activeCalls += 1
        peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
        defer { activeCalls -= 1 }
        var waited = Duration.zero
        while !isOpen, waited < .seconds(5) {
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch {
                cancelledCalls += 1
                throw CancellationError()
            }
            waited += .milliseconds(2)
        }
        completedCalls += 1
        return [result(segments: [whisperSegment(start: 0, end: 1, text: "gated")])]
    }

    private func poll(_ condition: () -> Bool) async {
        var waited = Duration.zero
        while !condition(), waited < .seconds(5) {
            try? await Task.sleep(for: .milliseconds(2))
            waited += .milliseconds(2)
        }
    }
}

private func result(segments: [TranscriptionSegment]) -> TranscriptionResult {
    TranscriptionResult(
        text: segments.map(\.text).joined(separator: " "),
        segments: segments,
        language: "en",
        timings: TranscriptionTimings()
    )
}
