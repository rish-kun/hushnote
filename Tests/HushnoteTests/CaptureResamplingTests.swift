import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// The 48 kHz → 16 kHz step is the single largest accuracy lever on live
/// transcription: everything it gets wrong is fed straight to the speech model.
@Suite("Speech feed resampling")
struct CaptureResamplingTests {
    private static let captureRate = 48_000.0
    private static let modelRate = 16_000.0
    private static let chunkFrames = 1_024

    @Test("Content above the 8 kHz model Nyquist is removed, not folded back onto speech")
    func rejectsAliasing() throws {
        // 12 kHz at 48 kHz folds to |12000 - 16000| = 4 kHz once decimated —
        // squarely on top of vowel formants. Sibilance, key clicks and
        // notification chimes all live up here.
        let tone = Self.sine(frequency: 12_000, amplitude: 0.9, frames: Int(Self.captureRate))
        let output = try Self.feed(tone)

        // Skip the filter's start-up transient before measuring.
        let settled = Array(output.dropFirst(2_000))
        let aliasAmplitude = Self.amplitude(of: settled, at: 4_000, sampleRate: Self.modelRate)
        let residualRMS = Self.rms(settled)

        #expect(
            aliasAmplitude < 0.001,
            "12 kHz folded back at amplitude \(aliasAmplitude) (input amplitude 0.9)"
        )
        #expect(residualRMS < 0.001, "out-of-band residual RMS \(residualRMS)")
    }

    @Test("Speech-band content survives at full amplitude")
    func preservesPassband() throws {
        let tone = Self.sine(frequency: 1_000, amplitude: 0.5, frames: Int(Self.captureRate))
        let output = try Self.feed(tone)
        let settled = Array(output.dropFirst(2_000))

        let amplitude = Self.amplitude(of: settled, at: 1_000, sampleRate: Self.modelRate)
        #expect(abs(amplitude - 0.5) < 0.02, "1 kHz arrived at amplitude \(amplitude)")
    }

    @Test("The model feed keeps real time instead of compressing it")
    func doesNotDrift() throws {
        // 1000 buffers of 1024 frames is 21.3 s of capture. Anything that loses
        // a fraction of a frame per buffer shows up here as a frame deficit.
        let frames = Self.chunkFrames * 1_000
        let silence = [Float](repeating: 0, count: frames)
        let output = try Self.feed(silence)

        let expected = Double(frames) * Self.modelRate / Self.captureRate
        let driftFrames = Double(output.count) - expected
        let driftFraction = driftFrames / expected

        let report = "produced \(output.count) frames, expected \(expected) — drift \(driftFrames) frames"
            + " (\(driftFraction * 100)%, \(driftFraction * 3_600) s per hour)"
        #expect(abs(driftFrames) <= 32, "\(report)")
    }

    // MARK: - Helpers

    /// Feeds capture-sized buffers through the pipeline's resampler exactly the
    /// way `CaptureOutputBridge.consume` does, one tap callback at a time.
    private static func feed(_ samples: [Float]) throws -> [Float] {
        let resampler = SpeechFeedResampler(targetSampleRate: modelRate)
        var output: [Float] = []
        var offset = 0
        while offset < samples.count {
            let count = min(chunkFrames, samples.count - offset)
            let buffer = pcmBuffer(Array(samples[offset..<(offset + count)]))
            output.append(contentsOf: try resampler.resample(buffer))
            offset += count
        }
        return output
    }

    private static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: captureRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func sine(frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / captureRate))
        }
    }

    /// Single-bin DFT: the amplitude of one frequency inside a signal.
    private static func amplitude(of samples: [Float], at frequency: Double, sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(index) / sampleRate
            real += Double(sample) * cos(angle)
            imaginary -= Double(sample) * sin(angle)
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(samples.count)).squareRoot()
    }
}
