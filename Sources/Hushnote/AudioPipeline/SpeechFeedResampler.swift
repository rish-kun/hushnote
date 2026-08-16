@preconcurrency import AVFoundation
import Foundation

/// AVAudioConverter calls its input block synchronously and serially within one
/// `convert` call even though the SDK marks the block `@Sendable`. Holding the
/// non-Sendable buffer here makes that lifetime explicit to Swift 6.
private final class ResamplerInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Converts the normalized 48 kHz capture stream to the 16 kHz mono feed the
/// speech model requires.
///
/// The naive version of this was a 3:1 decimation by linear interpolation with
/// no low-pass, which folded everything from 8–24 kHz back onto the speech
/// band: sibilance, keyboard clicks and notification chimes landed on top of
/// vowel formants. It also anchored its index math to the buffer endpoints,
/// losing one 48 kHz frame per callback — 0.098% of time-compression, about
/// 3.5 s per recorded hour, against chunk labels taken from the host clock,
/// which do not compress.
///
/// One converter is held for the life of a session so its polyphase filter
/// state stays continuous across tap callbacks. Rebuilding it per buffer would
/// reintroduce a discontinuity at every boundary.
final class SpeechFeedResampler {
    let targetSampleRate: Double

    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Frames of 48 kHz input the converter has been handed, which is the only
    /// honest basis for a chunk's duration: the output count is a filtered,
    /// rate-converted quantity and lags by the filter's own latency.
    private(set) var inputFramesAccepted: AVAudioFramePosition = 0

    func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        inputFramesAccepted += AVAudioFramePosition(buffer.frameLength)

        let inputFormat = buffer.format
        if inputFormat.sampleRate == targetSampleRate,
           inputFormat.channelCount == 1,
           inputFormat.commonFormat == .pcmFormatFloat32 {
            return buffer.monoFloatSamples()
        }

        if converter == nil || converterInputFormat != inputFormat {
            guard let created = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioPipelineError.unsupportedAudioFormat
            }
            // Live capture cannot look ahead, so priming would swallow the
            // start of the first buffer and require a tail flush at shutdown.
            created.primeMethod = .none
            created.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = created
            converterInputFormat = inputFormat
        }
        guard let converter else { throw AudioPipelineError.unsupportedAudioFormat }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 64))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioPipelineError.unsupportedAudioFormat
        }

        let state = ResamplerInputState(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if state.wasSupplied {
                // Not an error: the converter has drained this callback's
                // buffer and will resume from its retained filter state.
                inputStatus.pointee = .noDataNow
                return nil
            }
            state.wasSupplied = true
            inputStatus.pointee = .haveData
            return state.buffer
        }
        if let conversionError {
            throw AudioPipelineError.writerFailed(conversionError.localizedDescription)
        }
        guard status != .error else {
            throw AudioPipelineError.writerFailed("AVAudioConverter failed to produce the model feed")
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
