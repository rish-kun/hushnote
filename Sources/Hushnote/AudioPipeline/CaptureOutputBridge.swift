@preconcurrency import AVFoundation
import Foundation

/// Turns raw tap buffers into the two things a meeting needs: a durable CAF and
/// a 16 kHz feed for the speech model.
///
/// This type is internal rather than nested-and-private on purpose. Its
/// arithmetic — resampling, level metering, and the pause-aware timeline — is
/// the part of capture most likely to be silently wrong, and none of it can be
/// exercised through `AudioPipeline` without a real Core Audio device.
final class CaptureOutputBridge: @unchecked Sendable {
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

    static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }

    static func level(for samples: [Float], source: AudioSource) -> AudioLevel {
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
    static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
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
