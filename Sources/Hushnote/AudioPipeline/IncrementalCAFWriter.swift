import AVFoundation
import CoreMedia
import Foundation

/// AVAudioConverter invokes its input block synchronously and serially for one
/// conversion, although the SDK declares that block `@Sendable`. Keeping the
/// non-Sendable AVAudio buffer behind this narrowly scoped wrapper makes that
/// lifetime guarantee explicit to Swift 6.
private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class ConverterFlushState: @unchecked Sendable {
    var sentEndOfStream = false
}

/// Eagerly creates a normalized 48 kHz mono LPCM CAF. Calls are made from one
/// serial capture queue, so every accepted sample is appended before downstream
/// transcription sees it.
final class IncrementalCAFWriter {
    let url: URL

    private static let recoveryFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(url: URL) throws {
        self.url = url

        // AVAudioFile(forWriting:) truncates at open time, before a single frame
        // is written. A take that already holds audio is the only copy of a
        // meeting, so refuse rather than clobber it. A zero-frame file left by an
        // aborted start carries nothing and may be reused.
        if let existing = try? AVAudioFile(forReading: url), existing.length > 0 {
            throw AudioPipelineError.writerFailed(
                "\(url.lastPathComponent) already holds \(existing.length) frames of recorded audio"
            )
        }

        do {
            // Open eagerly so even a silent or abruptly interrupted meeting
            // leaves a valid, inspectable 48 kHz mono LPCM CAF artifact.
            file = try AVAudioFile(
                forWriting: url,
                settings: Self.recoveryFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioPipelineError.writerFailed(error.localizedDescription)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            throw AudioPipelineError.invalidAudioBuffer
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw AudioPipelineError.unsupportedAudioFormat
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw AudioPipelineError.writerFailed("CoreMedia error \(status)")
        }

        return try append(pcmBuffer)
    }

    /// Internal PCM entry point keeps normalization independently testable
    /// without manufacturing ScreenCaptureKit sample buffers.
    func append(_ pcmBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        do {
            let recoveryBuffer = try recoveryPCMBuffer(from: pcmBuffer)
            if recoveryBuffer.frameLength > 0 {
                try file?.write(from: recoveryBuffer)
                framesWritten += AVAudioFramePosition(recoveryBuffer.frameLength)
            }
            // Downstream inference also receives the normalized float/mono
            // representation, avoiding format-specific channel pointer paths.
            return recoveryBuffer
        } catch let error as AudioPipelineError {
            throw error
        } catch {
            throw AudioPipelineError.writerFailed(error.localizedDescription)
        }
    }

    /// AVAudioFile updates the CAF header as audio is appended. Dropping the
    /// handle completes the final header update while leaving every prior
    /// packet recoverable if the process had terminated earlier.
    func finish() {
        flushConverterTail()
        converter = nil
        converterInputFormat = nil
        file = nil
    }

    private func flushConverterTail() {
        guard let converter else { return }
        let flushState = ConverterFlushState()
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: Self.recoveryFormat,
                frameCapacity: 4_096
            ) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if flushState.sentEndOfStream {
                    inputStatus.pointee = .noDataNow
                } else {
                    flushState.sentEndOfStream = true
                    inputStatus.pointee = .endOfStream
                }
                return nil
            }
            guard error == nil, status != .error else { return }
            if output.frameLength > 0 {
                try? file?.write(from: output)
                framesWritten += AVAudioFramePosition(output.frameLength)
            }
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private func recoveryPCMBuffer(from input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = input.format
        if inputFormat == Self.recoveryFormat { return input }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: Self.recoveryFormat)
            // Live capture has no opportunity for look-ahead priming, and a
            // primed converter would otherwise discard the start of the first
            // buffer and require an explicit tail flush at shutdown.
            converter?.primeMethod = .none
            converterInputFormat = inputFormat
        }
        guard let converter else { throw AudioPipelineError.unsupportedAudioFormat }

        let ratio = Self.recoveryFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(
            1,
            Int(ceil(Double(input.frameLength) * ratio)) + 64
        ))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.recoveryFormat,
            frameCapacity: capacity
        ) else {
            throw AudioPipelineError.unsupportedAudioFormat
        }

        let inputState = ConverterInputState(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputState.wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.wasSupplied = true
            inputStatus.pointee = .haveData
            return inputState.buffer
        }
        if let conversionError {
            throw AudioPipelineError.writerFailed(conversionError.localizedDescription)
        }
        guard status != .error else {
            throw AudioPipelineError.writerFailed("AVAudioConverter failed")
        }
        return output
    }
}

extension AVAudioPCMBuffer {
    func monoFloatSamples() -> [Float] {
        guard frameLength > 0 else { return [] }
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        guard channels > 0 else { return [] }

        if let data = floatChannelData {
            var output = [Float](repeating: 0, count: frames)
            if format.isInterleaved {
                let values = data[0]
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        output[frame] += values[frame * channels + channel]
                    }
                }
            } else {
                for channel in 0..<channels {
                    let values = data[channel]
                    for frame in 0..<frames {
                        output[frame] += values[frame]
                    }
                }
            }
            let scale = 1 / Float(channels)
            return output.map { $0 * scale }
        }

        if let data = int16ChannelData {
            var output = [Float](repeating: 0, count: frames)
            if format.isInterleaved {
                let values = data[0]
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        output[frame] += Float(values[frame * channels + channel]) / Float(Int16.max)
                    }
                }
            } else {
                for channel in 0..<channels {
                    let values = data[channel]
                    for frame in 0..<frames {
                        output[frame] += Float(values[frame]) / Float(Int16.max)
                    }
                }
            }
            let scale = 1 / Float(channels)
            return output.map { $0 * scale }
        }

        if let data = int32ChannelData {
            var output = [Float](repeating: 0, count: frames)
            if format.isInterleaved {
                let values = data[0]
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        output[frame] += Float(values[frame * channels + channel]) / Float(Int32.max)
                    }
                }
            } else {
                for channel in 0..<channels {
                    let values = data[channel]
                    for frame in 0..<frames {
                        output[frame] += Float(values[frame]) / Float(Int32.max)
                    }
                }
            }
            let scale = 1 / Float(channels)
            return output.map { $0 * scale }
        }

        return []
    }
}
