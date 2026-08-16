import Foundation
import AVFoundation
import XCTest
@testable import Hushnote

final class LeakageDetectorTests: XCTestCase {
    func testDetectsDelayedEcho() {
        let sampleRate = 16_000.0
        let system = (0..<2_048).map { index in
            Float(sin(2 * Double.pi * 431 * Double(index) / sampleRate))
                + Float(sin(2 * Double.pi * 719 * Double(index) / sampleRate)) * 0.37
        }
        let delay = 96
        let microphone = Array(repeating: Float.zero, count: delay) + system.dropLast(delay)

        let result = AudioLeakageDetector().analyze(
            system: system,
            microphone: Array(microphone),
            sampleRate: sampleRate
        )

        XCTAssertTrue(result.isLikelyLeakage)
        XCTAssertGreaterThan(result.correlation, 0.98)
        XCTAssertEqual(abs(result.lagSamples), delay)
    }

    func testRejectsIndependentSignals() {
        let sampleRate = 16_000.0
        let system = (0..<2_048).map { index in
            Float(sin(2 * Double.pi * 307 * Double(index) / sampleRate))
        }
        let microphone = (0..<2_048).map { index in
            Float(sin(2 * Double.pi * 983 * Double(index) / sampleRate + 0.3))
        }

        let result = AudioLeakageDetector().analyze(
            system: system,
            microphone: microphone,
            sampleRate: sampleRate
        )

        XCTAssertFalse(result.isLikelyLeakage)
        XCTAssertLessThan(result.correlation, 0.25)
    }

    func testIgnoresSilence() {
        let result = AudioLeakageDetector().analyze(
            system: Array(repeating: 0, count: 1_024),
            microphone: Array(repeating: 0, count: 1_024),
            sampleRate: 16_000
        )

        XCTAssertEqual(result, AudioLeakageResult(
            correlation: 0,
            lagSamples: 0,
            isLikelyLeakage: false
        ))
    }

    func testDetectsCandidateThatLeadsReference() {
        let sampleRate = 16_000.0
        let signal = deterministicSignal(count: 2_048, sampleRate: sampleRate)
        let lead = 80
        let system = Array(repeating: Float.zero, count: lead) + signal.dropLast(lead)

        let result = AudioLeakageDetector().analyze(
            system: Array(system),
            microphone: signal,
            sampleRate: sampleRate
        )

        XCTAssertTrue(result.isLikelyLeakage)
        XCTAssertGreaterThan(result.correlation, 0.98)
        XCTAssertEqual(result.lagSamples, -lead)
    }

    func testHonorsConfiguredMaximumLag() {
        let sampleRate = 16_000.0
        let signal = deterministicNoise(count: 2_048)
        let delay = 96
        let microphone = Array(repeating: Float.zero, count: delay) + signal.dropLast(delay)

        let result = AudioLeakageDetector(maximumLagMilliseconds: 2).analyze(
            system: signal,
            microphone: Array(microphone),
            sampleRate: sampleRate
        )

        XCTAssertLessThanOrEqual(abs(result.lagSamples), 32)
        XCTAssertFalse(result.isLikelyLeakage)
    }

    func testRejectsInvalidSampleRateAndShortWindows() {
        let detector = AudioLeakageDetector()
        let samples = Array(repeating: Float(0.5), count: 64)

        XCTAssertEqual(
            detector.analyze(system: samples, microphone: samples, sampleRate: 0),
            AudioLeakageResult(correlation: 0, lagSamples: 0, isLikelyLeakage: false)
        )
        XCTAssertEqual(
            detector.analyze(system: Array(samples.prefix(31)), microphone: samples, sampleRate: 16_000),
            AudioLeakageResult(correlation: 0, lagSamples: 0, isLikelyLeakage: false)
        )
    }

    private func deterministicSignal(count: Int, sampleRate: Double) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * Double.pi * 431 * Double(index) / sampleRate))
                + Float(sin(2 * Double.pi * 719 * Double(index) / sampleRate)) * 0.37
        }
    }

    private func deterministicNoise(count: Int) -> [Float] {
        var state: UInt64 = 0xC0FFEE
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let sample = Float((state >> 40) & 0xFFFF) / Float(UInt16.max)
            return sample * 2 - 1
        }
    }
}

final class RecoveryCAFWriterTests: XCTestCase {
    func testNormalizesStereo44100PCMToMono48000CAF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "recovery.caf")
        let writer = try IncrementalCAFWriter(url: url)
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_410)!
        input.frameLength = 4_410
        for channel in 0..<2 {
            let samples = input.floatChannelData![channel]
            for frame in 0..<Int(input.frameLength) {
                samples[frame] = channel == 0 ? 0.25 : -0.125
            }
        }

        let normalized = try writer.append(input)
        writer.finish()
        let file = try AVAudioFile(forReading: url)

        XCTAssertEqual(normalized.format.sampleRate, 48_000)
        XCTAssertEqual(normalized.format.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 4_700)
        XCTAssertLessThan(file.length, 4_900)
    }
}
