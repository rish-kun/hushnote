@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// `monoFloatSamples()` is the gate every captured buffer passes through, and
/// its interleaved and integer branches had no coverage at all.
@Suite("Buffer normalization")
struct MonoFloatSamplesTests {
    /// Dividing by `Int16.max` maps full negative scale to -1.000031, which is
    /// outside the range every downstream stage assumes. Full scale is 32768,
    /// not 32767.
    @Test("Full negative scale is exactly -1")
    func int16FullNegativeScale() {
        let samples = Self.int16Buffer([Int16.min, Int16.min], channels: 1, interleaved: false)
            .monoFloatSamples()

        #expect(samples == [-1.0, -1.0])
    }

    @Test("Full positive scale never exceeds +1")
    func int16FullPositiveScale() {
        let samples = Self.int16Buffer([Int16.max], channels: 1, interleaved: false)
            .monoFloatSamples()

        #expect((samples.first ?? 0) <= 1.0)
        #expect(abs((samples.first ?? 0) - 1.0) < 0.0001)
    }

    @Test("Interleaved integer channels are averaged frame by frame")
    func interleavedInt16IsAveraged() {
        // Two frames, two channels: (+full, -full) then (0, -full).
        let buffer = Self.int16Buffer(
            [Int16.max, Int16.min, 0, Int16.min],
            channels: 2,
            interleaved: true
        )

        let samples = buffer.monoFloatSamples()

        #expect(samples.count == 2)
        #expect(abs(samples[0] - 0.0) < 0.0001, "opposite channels cancel")
        #expect(abs(samples[1] - -0.5) < 0.0001)
    }

    @Test("32-bit integer samples reach full scale without overshooting")
    func int32FullScale() {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatInt32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )!,
            frameCapacity: 2
        )!
        buffer.frameLength = 2
        buffer.int32ChannelData![0][0] = Int32.min
        buffer.int32ChannelData![0][1] = Int32.max

        let samples = buffer.monoFloatSamples()

        #expect(samples[0] == -1.0)
        #expect(samples[1] <= 1.0)
    }

    @Test("Interleaved float channels are averaged")
    func interleavedFloatIsAveraged() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let values = buffer.floatChannelData![0]
        values[0] = 1.0
        values[1] = 0.0
        values[2] = -0.5
        values[3] = -0.5

        #expect(buffer.monoFloatSamples() == [0.5, -0.5])
    }

    private static func int16Buffer(
        _ values: [Int16],
        channels: AVAudioChannelCount,
        interleaved: Bool
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: channels,
            interleaved: interleaved
        )!
        let frames = AVAudioFrameCount(values.count / Int(channels))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if interleaved {
            for (index, value) in values.enumerated() {
                buffer.int16ChannelData![0][index] = value
            }
        } else {
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(frames) {
                    buffer.int16ChannelData![channel][frame] = values[channel * Int(frames) + frame]
                }
            }
        }
        return buffer
    }
}

@Suite("Level metering")
struct CaptureLevelTests {
    @Test("Silence reads as zero, not as not-a-number")
    func silenceIsZero() {
        let level = CaptureOutputBridge.level(for: [Float](repeating: 0, count: 128), source: .system)

        #expect(level.rms == 0)
        #expect(level.peak == 0)
    }

    /// Reachable through the guard in `consume`, but a meter that returns NaN
    /// poisons every arithmetic it touches downstream.
    @Test("An empty buffer reads as zero")
    func emptyIsZero() {
        let level = CaptureOutputBridge.level(for: [], source: .system)

        #expect(!level.rms.isNaN)
        #expect(level.rms == 0)
        #expect(level.peak == 0)
    }

    @Test("Full scale reads as one")
    func fullScaleIsOne() {
        let level = CaptureOutputBridge.level(for: [1, -1, 1, -1], source: .system)

        #expect(level.rms == 1)
        #expect(level.peak == 1)
    }

    /// A rate converter's ringing can overshoot full scale. A meter must not
    /// report more than full scale when it does.
    @Test("An overshooting sample is clamped, not reported above full scale")
    func overshootIsClamped() {
        let level = CaptureOutputBridge.level(for: [1.4, -1.4], source: .system)

        #expect(level.peak <= 1)
        #expect(level.rms <= 1)
    }
}

/// The chunk timeline is what aligns the transcript against the audio. It has
/// to move forward, and it has to keep real gaps rather than papering over them.
@Suite("Chunk timeline")
struct CaptureTimelineTests {
    @Test("A gap in capture stays a gap, and time never runs backwards")
    func timelineIsMonotonicAndGapPreserving() throws {
        let harness = try Harness()

        harness.consume(milliseconds: 100, at: 1_000.0)
        harness.consume(milliseconds: 100, at: 1_000.1)
        // The device went quiet for five seconds.
        harness.consume(milliseconds: 100, at: 1_005.1)
        // A malformed or repeated timestamp arrives from the past.
        harness.consume(milliseconds: 100, at: 1_000.0)

        let chunks = harness.chunks
        #expect(chunks.count == 4)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.startMilliseconds >= previous.endMilliseconds, "the timeline moved backwards")
        }
        #expect(chunks[0].startMilliseconds == 0)
        #expect(abs(chunks[1].startMilliseconds - 100) <= 1)
        #expect(abs(chunks[2].startMilliseconds - 5_100) <= 1, "the five-second gap was not preserved")
        #expect(chunks.allSatisfy { $0.endMilliseconds > $0.startMilliseconds })
        #expect(chunks.allSatisfy { abs(($0.endMilliseconds - $0.startMilliseconds) - 100) <= 1 })
    }

    @Test("Paused time is removed from the timeline instead of appearing as a gap")
    func pauseIsSubtracted() async throws {
        let harness = try Harness()

        harness.consume(milliseconds: 100, at: 2_000.0)
        harness.bridge.pause()
        try await Task.sleep(for: .milliseconds(300))
        harness.bridge.resume()
        // The device timeline advanced through the pause: 300 ms of pause plus
        // the 100 ms already recorded.
        harness.consume(milliseconds: 100, at: 2_000.4)

        let chunks = harness.chunks
        #expect(chunks.count == 2)
        #expect(
            abs(chunks[1].startMilliseconds - 100) <= 60,
            "second chunk starts at \(chunks[1].startMilliseconds) ms; the 300 ms pause was not removed"
        )
    }

    struct Harness {
        let bridge: CaptureOutputBridge
        private let collector = ChunkCollector()
        private let directory: URL

        init() throws {
            directory = CaptureDurationTests.makeDirectory()
            let continuation = collector.continuation
            bridge = try CaptureOutputBridge(
                systemAudioURL: directory.appending(path: "system-0.caf"),
                eventContinuation: continuation
            )
            bridge.begin()
        }

        func consume(milliseconds: Int, at presentationSeconds: Double) {
            let frames = Int((Double(milliseconds) / 1_000 * 48_000).rounded())
            bridge.consume(
                FakeSystemAudioCapture.buffer(frames: frames, amplitude: 0.2),
                presentationSeconds: presentationSeconds
            )
        }

        var chunks: [CapturedAudioChunk] { collector.chunks }
    }

    final class ChunkCollector: @unchecked Sendable {
        let continuation: AsyncStream<AudioCaptureEvent>.Continuation
        private let stream: AsyncStream<AudioCaptureEvent>

        init() {
            let pair = AsyncStream<AudioCaptureEvent>.makeStream(bufferingPolicy: .unbounded)
            stream = pair.stream
            continuation = pair.continuation
        }

        /// The bridge yields synchronously, so everything emitted so far is
        /// already buffered and can be drained without awaiting.
        var chunks: [CapturedAudioChunk] {
            continuation.finish()
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            Task { [stream] in
                for await event in stream {
                    if case .chunk(let chunk) = event { box.append(chunk) }
                }
                semaphore.signal()
            }
            semaphore.wait()
            return box.values
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CapturedAudioChunk] = []

        func append(_ chunk: CapturedAudioChunk) {
            lock.withLock { storage.append(chunk) }
        }

        var values: [CapturedAudioChunk] { lock.withLock { storage } }
    }
}
