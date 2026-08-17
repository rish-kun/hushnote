import Foundation
import WhisperKit
@testable import Hushnote

/// Shared scaffolding for the two suites that guard Whisper's control
/// vocabulary out of the transcript. Both drive the real engines through their
/// decoder seams, so no model is ever downloaded and no inference is run.
enum SpecialTokenFixture {
    /// Verbatim from a real meeting the user recorded, tokens and all.
    static let pollutedFirstSegment =
        "<|startoftranscript|><|en|><|transcribe|><|0.00|> Also, do not touch the releases.<|6.88|>"
    static let pollutedSecondSegment =
        "<|6.88|> I'll only increase the release patch after it has been merged to me.<|12.06|>"
    static let pollutedThirdSegment =
        "<|12.06|> So whatever changes you have to make has to be within skills, within scripts.<|18.00|>"
    static let pollutedLowercaseSegment =
        "<|startoftranscript|><|en|><|transcribe|><|2.40|> okay take light i'll uh you can get started on it<|8.40|>"

    static func configuration(meetingID: UUID) -> TranscriptionSessionConfiguration {
        TranscriptionSessionConfiguration(
            meetingID: meetingID,
            languageCode: "en",
            confirmationLagSegments: 2,
            minimumDecodeIntervalMilliseconds: 250
        )
    }

    static func frame(
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

    static func track(_ meetingID: UUID, _ source: AudioSource = .system) -> MeetingAudioTrack {
        MeetingAudioTrack(
            meetingID: meetingID,
            source: source,
            fileURL: URL(filePath: "/tmp/hushnote-tests/\(source.rawValue).caf"),
            sampleRate: 16_000,
            channelCount: 1,
            isComplete: true
        )
    }

    static func segment(
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

    static func word(_ text: String, start: Float, end: Float) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: end, probability: 0.9)
    }

    static func result(_ segments: [TranscriptionSegment]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            language: "en",
            timings: TranscriptionTimings()
        )
    }
}

/// Replays canned segments for the live engine and keeps the options it was
/// asked to decode with.
actor RecordingLiveDecoder: LiveSpeechDecoder {
    private let scripts: [[TranscriptionSegment]]
    private var callCount = 0
    private(set) var receivedOptions: [DecodingOptions] = []

    init(_ scripts: [[TranscriptionSegment]]) {
        self.scripts = scripts
    }

    func decodeWindow(
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        receivedOptions.append(options)
        let index = min(callCount, scripts.count - 1)
        callCount += 1
        return [SpecialTokenFixture.result(scripts[index])]
    }
}

/// The same for the final pass, which decodes whole files and reports one
/// outcome per path.
actor RecordingFileDecoder: FinalSpeechDecoder {
    private let outcomes: [Result<[TranscriptionResult], any Error>]
    private(set) var receivedOptions: [DecodingOptions] = []

    init(_ outcomes: [Result<[TranscriptionResult], any Error>]) {
        self.outcomes = outcomes
    }

    func decodeFiles(
        paths: [String],
        options: DecodingOptions
    ) async -> [Result<[TranscriptionResult], any Error>] {
        receivedOptions.append(options)
        return outcomes
    }
}
