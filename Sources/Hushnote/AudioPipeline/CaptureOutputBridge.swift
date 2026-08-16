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
    // One resampler for the whole session: its polyphase filter state has to
    // stay continuous across tap callbacks.
    private let resampler = SpeechFeedResampler(targetSampleRate: 16_000)
    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation

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

    /// How much audio this session actually recorded.
    ///
    /// This used to be `ContinuousClock` elapsed time minus pauses, which
    /// counted the 100–400 ms of HAL start-up before the first IOProc callback,
    /// every dropped buffer, and — because `stop()` reads it after
    /// `AudioHardwareDestroyAggregateDevice` — the teardown as well. Frames in
    /// the file are the only figure that cannot drift from the recording, and
    /// they are what recovery recomputes when a meeting is reopened.
    var durationMilliseconds: Int64 {
        queue.sync {
            Self.milliseconds(
                frames: systemWriter.framesWritten,
                sampleRate: IncrementalCAFWriter.recoverySampleRate
            )
        }
    }

    func begin() {
        queue.sync {
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
                guard pcmBuffer.frameLength > 0, pcmBuffer.format.sampleRate > 0 else { return }

                // Duration is taken from the 48 kHz frames handed to the
                // converter, never from the converted count: a rate converter's
                // output lags its input by its own filter latency, so a
                // per-callback output count is not a duration.
                let chunkDuration = Int64(
                    (Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate * 1_000).rounded()
                )
                let sampleRate = resampler.targetSampleRate
                let samples = try resampler.resample(pcmBuffer)
                guard !samples.isEmpty else { return }
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

    static func milliseconds(frames: AVAudioFramePosition, sampleRate: Double) -> Int64 {
        guard frames > 0, sampleRate > 0 else { return 0 }
        return Int64((Double(frames) / sampleRate * 1_000).rounded())
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

}
