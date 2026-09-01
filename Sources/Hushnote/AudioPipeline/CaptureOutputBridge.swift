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

    let source: AudioSource

    private let queue: DispatchQueue
    private let sourceWriter: IncrementalCAFWriter
    private let timelineCoordinator: CapturedMediaTimelineCoordinator
    private let timelineStartMilliseconds: Int64
    private var firstRecordedStartMilliseconds: Int64?
    private var committedDurationMilliseconds: Int64 = 0
    /// A source is verified only after its first non-empty recovery write. The
    /// bridge is recreated for every take, so this naturally re-arms after a
    /// device transition, wake, or retry.
    private var emittedDurableHealth = false
    // One resampler for the whole session: its polyphase filter state has to
    // stay continuous across tap callbacks.
    private let resampler = SpeechFeedResampler(targetSampleRate: 16_000)
    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation

    private var acceptingSamples = false
    private var finished = false

    convenience init(
        systemAudioURL: URL,
        eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    ) throws {
        try self.init(
            source: .system,
            audioURL: systemAudioURL,
            timelineCoordinator: CapturedMediaTimelineCoordinator(),
            eventContinuation: eventContinuation
        )
    }

    /// Creates one source-specific output path. Pass the same timeline
    /// coordinator to the system and microphone bridges so their independently
    /// written originals share one host-time-aligned meeting clock.
    init(
        source: AudioSource,
        audioURL: URL,
        timelineCoordinator: CapturedMediaTimelineCoordinator,
        eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    ) throws {
        self.source = source
        queue = DispatchQueue(
            label: "com.hushnote.audio-capture-state.\(source.rawValue)"
        )
        sourceWriter = try IncrementalCAFWriter(url: audioURL)
        self.timelineCoordinator = timelineCoordinator
        timelineStartMilliseconds = timelineCoordinator.beginTake(for: source)
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
                frames: sourceWriter.framesWritten,
                sampleRate: IncrementalCAFWriter.recoverySampleRate
            )
        }
    }

    var sourceArtifact: AudioCaptureSourceArtifact {
        queue.sync {
            AudioCaptureSourceArtifact(
                source: source,
                audioURL: sourceWriter.url,
                timelineStartMilliseconds: firstRecordedStartMilliseconds
                    ?? timelineStartMilliseconds,
                durationMilliseconds: Self.milliseconds(
                    frames: sourceWriter.framesWritten,
                    sampleRate: IncrementalCAFWriter.recoverySampleRate
                )
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
            guard !finished else { return }
            acceptingSamples = false
            timelineCoordinator.suspend(
                reason: .pause,
                at: ProcessInfo.processInfo.systemUptime
            )
        }
    }

    func resume() {
        queue.sync {
            guard !finished else { return }
            timelineCoordinator.resume(at: ProcessInfo.processInfo.systemUptime)
            acceptingSamples = true
        }
    }

    func finish() {
        queue.sync {
            guard !finished else { return }
            acceptingSamples = false
            sourceWriter.finish()
            finished = true
        }
    }

    func consume(_ inputBuffer: AVAudioPCMBuffer, presentationSeconds: Double) {
        queue.sync {
            guard acceptingSamples, !finished else { return }
            do {
                let recorded = try timelineCoordinator.record(
                    source: source,
                    presentationSeconds: presentationSeconds
                ) {
                    // The write is deliberately first. AsyncStream never
                    // receives a chunk absent from the source's recovery track.
                    let pcmBuffer = try sourceWriter.append(inputBuffer)
                    guard pcmBuffer.frameLength > 0,
                          pcmBuffer.format.sampleRate > 0
                    else {
                        return (
                            value: pcmBuffer,
                            durationMilliseconds: 0
                        )
                    }
                    // Use recovery frames, not resampler output: a converter's
                    // filter latency is not captured-media duration.
                    // Compute a delta from the exact cumulative frame count.
                    // Rounding each 1,024-frame callback independently loses
                    // roughly a third of a millisecond per callback.
                    let totalDuration = Self.milliseconds(
                        frames: sourceWriter.framesWritten,
                        sampleRate: IncrementalCAFWriter.recoverySampleRate
                    )
                    let duration = max(0, totalDuration - committedDurationMilliseconds)
                    committedDurationMilliseconds = totalDuration
                    return (
                        value: pcmBuffer,
                        durationMilliseconds: duration
                    )
                }
                guard let recorded,
                      recorded.range.endMilliseconds > recorded.range.startMilliseconds
                else { return }
                if firstRecordedStartMilliseconds == nil {
                    firstRecordedStartMilliseconds = recorded.range.startMilliseconds
                }

                // The source writer has already accepted the frames above.
                // Verify system audio at this durable boundary, not when the
                // device merely reports that it started. Microphone writes
                // remain source-local and must never establish system capture.
                if source == .system, !emittedDurableHealth {
                    emittedDurableHealth = true
                    eventContinuation.yield(.sourceHealth(.init(
                        source: .system,
                        state: .healthy
                    )))
                }

                let sampleRate = resampler.targetSampleRate
                let samples = try resampler.resample(recorded.value)
                guard !samples.isEmpty else { return }

                eventContinuation.yield(.chunk(CapturedAudioChunk(
                    source: source,
                    startMilliseconds: recorded.range.startMilliseconds,
                    endMilliseconds: recorded.range.endMilliseconds,
                    sampleRate: sampleRate,
                    samples: samples
                )))
                eventContinuation.yield(.level(Self.level(
                    for: samples,
                    source: source,
                    timelineMilliseconds: recorded.range.endMilliseconds
                )))
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

    static func level(
        for samples: [Float],
        source: AudioSource,
        timelineMilliseconds: Int64? = nil
    ) -> AudioLevel {
        // Without this the empty case divides by zero and reports NaN, which
        // poisons every meter arithmetic downstream of it.
        guard !samples.isEmpty else {
            return AudioLevel(
                source: source,
                rms: 0,
                peak: 0,
                timelineMilliseconds: timelineMilliseconds
            )
        }
        var peak: Float = 0
        var energy: Double = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            energy += Double(sample * sample)
        }
        let rms = Float(sqrt(energy / Double(samples.count)))
        // A rate converter's ringing can overshoot full scale. A meter reports
        // full scale, never more.
        return AudioLevel(
            source: source,
            rms: min(1, rms),
            peak: min(1, peak),
            timelineMilliseconds: timelineMilliseconds
        )
    }

}
