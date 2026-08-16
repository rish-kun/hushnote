@preconcurrency import AVFoundation
import Foundation

/// Owns one meeting capture using macOS's system-audio-only Core Audio tap.
public actor AudioPipeline {
    public nonisolated let events: AsyncStream<AudioCaptureEvent>

    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let rootDirectory: URL
    private var capture: SystemAudioTapCapture?
    private var output: CaptureOutputBridge?
    private var currentStatus: AudioCaptureStatus = .idle
    private var sessionID: UUID?
    private var sessionDirectory: URL?
    private var systemAudioURL: URL?

    public init(rootDirectory: URL? = nil) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        eventContinuation = pair.continuation
        self.rootDirectory = rootDirectory ?? Self.defaultCaptureDirectory()
    }

    deinit {
        eventContinuation.finish()
    }

    public var status: AudioCaptureStatus { currentStatus }

    /// Starts a bot-free capture governed exclusively by the macOS System Audio
    /// Recording Only permission. No microphone or screen pixels are accessed.
    @discardableResult
    public func start(sessionID id: UUID = UUID()) async throws -> UUID {
        guard capture == nil else { throw AudioPipelineError.alreadyRunning }
        updateStatus(.preparing)

        let directory = rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        let systemURL = directory.appending(path: "system.caf")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let output = try CaptureOutputBridge(
                systemAudioURL: systemURL,
                eventContinuation: eventContinuation
            )
            output.failureHandler = { [weak self] message in
                Task { await self?.captureDidFail(message) }
            }
            let capture = SystemAudioTapCapture { [weak output] buffer, presentationSeconds in
                output?.consume(buffer, presentationSeconds: presentationSeconds)
            }

            self.sessionID = id
            self.sessionDirectory = directory
            self.systemAudioURL = systemURL
            self.output = output
            self.capture = capture

            output.begin()
            try capture.start()
            updateStatus(.recording)
            return id
        } catch {
            output?.finish()
            capture?.stop()
            capture = nil
            output = nil
            sessionID = nil
            sessionDirectory = nil
            systemAudioURL = nil
            let mappedError = Self.mapCaptureError(error)
            updateStatus(.failed(mappedError.localizedDescription))
            throw mappedError
        }
    }

    public func pause() throws {
        guard currentStatus == .recording, let output, let capture else {
            throw AudioPipelineError.notRunning
        }
        try capture.pause()
        output.pause()
        updateStatus(.paused)
    }

    public func resume() throws {
        guard currentStatus == .paused, let output, let capture else {
            throw AudioPipelineError.notRunning
        }
        try capture.resume()
        output.resume()
        updateStatus(.recording)
    }

    @discardableResult
    public func stop() async throws -> AudioCaptureArtifacts {
        guard let capture,
              let output,
              let sessionID,
              let sessionDirectory,
              let systemAudioURL
        else {
            throw AudioPipelineError.notRunning
        }

        updateStatus(.stopping)
        capture.stop()
        output.finish()
        let artifacts = AudioCaptureArtifacts(
            sessionID: sessionID,
            directoryURL: sessionDirectory,
            systemAudioURL: systemAudioURL,
            durationMilliseconds: output.durationMilliseconds
        )
        resetSession()
        updateStatus(.stopped)
        return artifacts
    }

    private func updateStatus(_ status: AudioCaptureStatus) {
        currentStatus = status
        eventContinuation.yield(.status(status))
    }

    private func captureDidFail(_ message: String) async {
        guard let capture else { return }
        capture.stop()
        output?.finish()
        resetSession()
        updateStatus(.failed(message))
    }

    private func resetSession() {
        capture = nil
        output = nil
        sessionID = nil
        sessionDirectory = nil
        systemAudioURL = nil
    }

    private static func defaultCaptureDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base
            .appending(path: "Hushnote", directoryHint: .isDirectory)
            .appending(path: "RecoveryAudio", directoryHint: .isDirectory)
    }

    private static func mapCaptureError(_ error: Error) -> Error { error }
}

private final class CaptureOutputBridge: @unchecked Sendable {
    var failureHandler: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.hushnote.audio-capture-state")
    private let systemWriter: IncrementalCAFWriter
    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation

    private var startInstant: ContinuousClock.Instant?
    private var pauseInstant: ContinuousClock.Instant?
    private var accumulatedPause: Duration = .zero
    private var timelineOriginSeconds: Double?
    private var lastEnd: [AudioSource: Int64] = [:]
    private var acceptingSamples = false
    private var finished = false

    init(
        systemAudioURL: URL,
        eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    ) throws {
        systemWriter = try IncrementalCAFWriter(url: systemAudioURL)
        self.eventContinuation = eventContinuation
    }

    var durationMilliseconds: Int64 {
        queue.sync { adjustedElapsedMilliseconds(at: .now) }
    }

    func begin() {
        queue.sync {
            startInstant = .now
            acceptingSamples = true
        }
    }

    func pause() {
        queue.sync {
            guard pauseInstant == nil, !finished else { return }
            pauseInstant = .now
            acceptingSamples = false
        }
    }

    func resume() {
        queue.sync {
            guard let pauseInstant, !finished else { return }
            accumulatedPause += pauseInstant.duration(to: .now)
            self.pauseInstant = nil
            acceptingSamples = true
        }
    }

    func finish() {
        queue.sync {
            guard !finished else { return }
            acceptingSamples = false
            if let pauseInstant {
                accumulatedPause += pauseInstant.duration(to: .now)
                self.pauseInstant = nil
            }
            systemWriter.finish()
            finished = true
        }
    }

    func consume(_ inputBuffer: AVAudioPCMBuffer, presentationSeconds: Double) {
        let source = AudioSource.system

        queue.sync {
            guard acceptingSamples, !finished else { return }
            do {
                // This write is deliberately first. AsyncStream never receives
                // a chunk that is absent from the crash-recovery track.
                let pcmBuffer = try systemWriter.append(inputBuffer)
                let nativeSamples = pcmBuffer.monoFloatSamples()
                guard !nativeSamples.isEmpty else { return }

                let sampleRate = 16_000.0
                let samples = Self.resample(
                    nativeSamples,
                    from: pcmBuffer.format.sampleRate,
                    to: sampleRate
                )
                let chunkDuration = Int64((Double(samples.count) / sampleRate * 1_000).rounded())
                if timelineOriginSeconds == nil, presentationSeconds.isFinite {
                    timelineOriginSeconds = presentationSeconds
                }
                let pausedMilliseconds = Self.milliseconds(accumulatedPause)
                let presentationStart: Int64
                if let timelineOriginSeconds, presentationSeconds.isFinite {
                    presentationStart = max(
                        0,
                        Int64(((presentationSeconds - timelineOriginSeconds) * 1_000).rounded())
                            - pausedMilliseconds
                    )
                } else {
                    presentationStart = lastEnd[source] ?? 0
                }
                let previousEnd = lastEnd[source] ?? 0
                // Keep real capture gaps while preventing a malformed or
                // repeated timestamp from moving the stream backwards.
                let start = max(previousEnd, presentationStart)
                let end = start + max(1, chunkDuration)
                lastEnd[source] = end

                eventContinuation.yield(.chunk(CapturedAudioChunk(
                    source: source,
                    startMilliseconds: start,
                    endMilliseconds: end,
                    sampleRate: sampleRate,
                    samples: samples
                )))
                eventContinuation.yield(.level(Self.level(for: samples, source: source)))
            } catch {
                acceptingSamples = false
                failureHandler?(error.localizedDescription)
            }
        }
    }

    private func adjustedElapsedMilliseconds(at instant: ContinuousClock.Instant) -> Int64 {
        guard let startInstant else { return 0 }
        let effectiveInstant = pauseInstant ?? instant
        let elapsed = startInstant.duration(to: effectiveInstant) - accumulatedPause
        let components = elapsed.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return max(0, milliseconds)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }

    private static func level(for samples: [Float], source: AudioSource) -> AudioLevel {
        var peak: Float = 0
        var energy: Double = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            energy += Double(sample * sample)
        }
        let rms = Float(sqrt(energy / Double(samples.count)))
        return AudioLevel(source: source, rms: rms, peak: peak)
    }

    /// A lightweight streaming-safe conversion for short Core Audio tap
    /// buffers. The native samples are preserved in CAF; only the model feed is
    /// converted to WhisperKit's required 16 kHz rate.
    private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        guard abs(sourceRate - targetRate) > 0.5 else { return input }
        let outputCount = max(1, Int((Double(input.count) * targetRate / sourceRate).rounded()))
        guard input.count > 1, outputCount > 1 else { return [input[0]] }

        let scale = Double(input.count - 1) / Double(outputCount - 1)
        return (0..<outputCount).map { outputIndex in
            let position = Double(outputIndex) * scale
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }
}
