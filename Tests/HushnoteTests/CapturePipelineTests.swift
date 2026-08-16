@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// A stand-in for the Core Audio tap. Tests drive it directly, so the pipeline's
/// own rules can be checked without an aggregate device or a privacy grant.
final class FakeSystemAudioCapture: SystemAudioCapturing, @unchecked Sendable {
    enum Call: Equatable {
        case start
        case stop
        case pause
        case resume
    }

    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    private var _calls: [Call] = []
    private var _isRunning = false

    /// Simulates the real teardown cost: `AudioHardwareDestroyAggregateDevice`
    /// plus `AudioHardwareDestroyProcessTap` take real time.
    var stopCost: TimeInterval = 0
    var startError: Error?
    var resumeError: Error?

    var calls: [Call] { lock.withLock { _calls } }
    var isRunning: Bool { lock.withLock { _isRunning } }

    func install(_ handler: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func start() throws {
        lock.withLock { _calls.append(.start) }
        if let startError { throw startError }
        lock.withLock { _isRunning = true }
    }

    func stop() {
        lock.withLock {
            _calls.append(.stop)
            _isRunning = false
        }
        if stopCost > 0 { Thread.sleep(forTimeInterval: stopCost) }
    }

    func pause() throws {
        lock.withLock {
            _calls.append(.pause)
            _isRunning = false
        }
    }

    func resume() throws {
        lock.withLock { _calls.append(.resume) }
        if let resumeError { throw resumeError }
        lock.withLock { _isRunning = true }
    }

    /// Emits capture-sized 48 kHz buffers the way the HAL's IOProc would.
    /// Delivery is refused while stopped, exactly like a dead IOProc.
    @discardableResult
    func emit(
        milliseconds: Int,
        startingAt presentationSeconds: Double = 1_000,
        amplitude: Float = 0.25
    ) -> Int {
        let frameRate = 48_000.0
        let framesPerBuffer = 1_024
        let totalFrames = Int((Double(milliseconds) / 1_000 * frameRate).rounded())
        var emitted = 0
        var frame = 0
        while frame < totalFrames {
            let count = min(framesPerBuffer, totalFrames - frame)
            let buffer = Self.buffer(frames: count, amplitude: amplitude)
            let handler = lock.withLock { self.handler }
            guard let handler, isRunning else { break }
            handler(buffer, presentationSeconds + Double(frame) / frameRate)
            emitted += count
            frame += count
        }
        return emitted
    }

    static func buffer(frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frames {
            samples[index] = amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        return buffer
    }
}

@Suite("Recorded duration")
struct CaptureDurationTests {
    /// A meeting's stored duration is what the recovery file will report if the
    /// app ever has to reopen it. The two must not be able to disagree.
    @Test("Duration counts the audio actually written, not the wall clock")
    func durationFollowsWrittenFrames() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler in
            fake.install(handler)
            return fake
        }

        let session = UUID()
        _ = try await pipeline.start(sessionID: session)
        let frames = fake.emit(milliseconds: 2_000)
        #expect(frames == 96_000, "fixture should have delivered two seconds of capture")
        let artifacts = try await pipeline.stop()

        let file = try AVAudioFile(forReading: artifacts.systemAudioURL)
        let fileMilliseconds = Int64((Double(file.length) / file.fileFormat.sampleRate * 1_000).rounded())

        #expect(
            abs(artifacts.durationMilliseconds - 2_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms for two seconds of audio"
        )
        #expect(
            artifacts.durationMilliseconds == fileMilliseconds,
            "stored \(artifacts.durationMilliseconds) ms but the recovery file reports \(fileMilliseconds) ms"
        )
    }

    /// `capture.stop()` synchronously destroys the aggregate device and the
    /// process tap. None of that is recorded audio.
    @Test("Teardown after the last buffer is not counted as recorded audio")
    func teardownIsNotRecordedAudio() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        fake.stopCost = 0.4
        let pipeline = AudioPipeline(rootDirectory: directory) { handler in
            fake.install(handler)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 1_000)
        let artifacts = try await pipeline.stop()

        #expect(
            abs(artifacts.durationMilliseconds - 1_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms for one second of audio plus 400 ms of teardown"
        )
    }

    /// Paused time is not written to the file, so it must not be stored either.
    @Test("A pause does not lengthen the recording")
    func pauseIsExcluded() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler in
            fake.install(handler)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 500)
        try await pipeline.pause()
        try await Task.sleep(for: .milliseconds(120))
        try await pipeline.resume()
        fake.emit(milliseconds: 500, startingAt: 1_002)
        let artifacts = try await pipeline.stop()

        #expect(
            abs(artifacts.durationMilliseconds - 1_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms for one second of audio around a 120 ms pause"
        )
    }

    static func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
