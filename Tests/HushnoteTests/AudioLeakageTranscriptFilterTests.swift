@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Hushnote

@Suite("Transcript leakage filtering")
struct AudioLeakageTranscriptFilterTests {
    @Test("System echo is removed from the microphone transcript without touching originals")
    func removesEchoSegment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signal = Self.signal(count: 24_000, frequency: 431)
        try fixture.write(signal, to: fixture.systemURL)
        try fixture.write(signal.map { $0 * 0.7 }, to: fixture.microphoneURL)

        let segments = [
            fixture.segment(source: .system, text: "Remote speech"),
            fixture.segment(source: .microphone, text: "Remote speech")
        ]
        let filtered = await AudioLeakageTranscriptFilter()
            .removingLikelySystemLeakage(from: segments, tracks: fixture.tracks)

        #expect(filtered.map(\.source) == [.system])
        #expect(FileManager.default.fileExists(atPath: fixture.microphoneURL.path))
    }

    @Test("Independent local speech remains labelled as microphone audio")
    func preservesIndependentSpeech() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.signal(count: 24_000, frequency: 431), to: fixture.systemURL)
        try fixture.write(Self.signal(count: 24_000, frequency: 983), to: fixture.microphoneURL)
        let microphone = fixture.segment(source: .microphone, text: "My own point")

        let filtered = await AudioLeakageTranscriptFilter()
            .removingLikelySystemLeakage(from: [microphone], tracks: fixture.tracks)

        #expect(filtered == [microphone])
    }

    @Test("Microphone speech is preserved when system ASR found no overlapping speech")
    func preservesSpeechWithoutATranscriptDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signal = Self.signal(count: 24_000, frequency: 431)
        try fixture.write(signal, to: fixture.systemURL)
        try fixture.write(signal, to: fixture.microphoneURL)
        let microphone = fixture.segment(source: .microphone, text: "Only the local track decoded this")

        let filtered = await AudioLeakageTranscriptFilter()
            .removingLikelySystemLeakage(from: [microphone], tracks: fixture.tracks)

        #expect(filtered == [microphone])
    }

    private static func signal(count: Int, frequency: Double) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / 48_000))
                + Float(sin(2 * Double.pi * 719 * Double(index) / 48_000)) * 0.23
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let systemURL: URL
        let microphoneURL: URL
        let meetingID = UUID()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            systemURL = directory.appending(path: "system.caf")
            microphoneURL = directory.appending(path: "microphone.caf")
        }

        var tracks: [MeetingAudioTrack] {
            [
                track(source: .system, url: systemURL),
                track(source: .microphone, url: microphoneURL)
            ]
        }

        func segment(source: AudioSource, text: String) -> TranscriptSegment {
            TranscriptSegment(
                id: UUID().uuidString,
                meetingID: meetingID,
                source: source,
                revision: 1,
                startMilliseconds: 0,
                endMilliseconds: 500,
                text: text,
                stability: .final
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func write(_ samples: [Float], to url: URL) throws {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )!
            buffer.frameLength = buffer.frameCapacity
            for index in samples.indices {
                buffer.floatChannelData![0][index] = samples[index]
            }
            try file.write(from: buffer)
        }

        private func track(source: AudioSource, url: URL) -> MeetingAudioTrack {
            MeetingAudioTrack(
                meetingID: meetingID,
                source: source,
                fileURL: url,
                sampleRate: 48_000,
                channelCount: 1,
                timelineStartMilliseconds: 0,
                durationMilliseconds: 500,
                isComplete: true
            )
        }
    }
}
