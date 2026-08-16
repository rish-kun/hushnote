import Foundation

public enum AudioCaptureStatus: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case stopped
    case failed(String)
}

/// A model-friendly copy of a captured PCM buffer. The matching CAF data is
/// durably appended before this value is emitted by ``AudioPipeline``.
public struct CapturedAudioChunk: Sendable {
    public let source: AudioSource
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let sampleRate: Double
    public let samples: [Float]

    public init(
        source: AudioSource,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        sampleRate: Double,
        samples: [Float]
    ) {
        self.source = source
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public func audioFrame(meetingID: UUID, sequenceNumber: Int64) -> AudioFrame {
        AudioFrame(
            meetingID: meetingID,
            source: source,
            sequenceNumber: sequenceNumber,
            startMilliseconds: startMilliseconds,
            sampleRate: Int(sampleRate.rounded()),
            samples: samples
        )
    }
}

public struct AudioLevel: Equatable, Sendable {
    public let source: AudioSource
    public let rms: Float
    public let peak: Float

    public init(source: AudioSource, rms: Float, peak: Float) {
        self.source = source
        self.rms = rms
        self.peak = peak
    }
}

public enum AudioCaptureEvent: Sendable {
    case status(AudioCaptureStatus)
    case chunk(CapturedAudioChunk)
    case level(AudioLevel)
}

public struct AudioCaptureArtifacts: Equatable, Sendable {
    public let sessionID: UUID
    public let directoryURL: URL
    public let systemAudioURL: URL
    public let durationMilliseconds: Int64

    public init(
        sessionID: UUID,
        directoryURL: URL,
        systemAudioURL: URL,
        durationMilliseconds: Int64
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.systemAudioURL = systemAudioURL
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum AudioPipelineError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case noDisplayAvailable
    case invalidAudioBuffer
    case unsupportedAudioFormat
    case writerFailed(String)
    case permissionDenied
    case audioCaptureFailed
    case coreAudioFailure(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A capture session is already running."
        case .notRunning: "No capture session is running."
        case .noDisplayAvailable: "No display is available for system audio capture."
        case .invalidAudioBuffer: "macOS returned an invalid system-audio buffer."
        case .unsupportedAudioFormat: "The captured audio format is unsupported."
        case .writerFailed(let reason): "The recovery audio track could not be written: \(reason)"
        case .permissionDenied: "System Audio Recording is not authorized for Hushnote. Enable the System Audio Recording Only toggle, then quit and reopen the app."
        case .audioCaptureFailed: "macOS could not start system-audio capture. Quit and reopen Hushnote, then try again."
        case .coreAudioFailure(let operation, let status):
            if status == OSStatus(bitPattern: 0x6E6F7065) {
                "Core Audio was temporarily busy while Hushnote tried to \(operation). No other audio app needs to be closed; wait a moment and try again."
            } else {
                "Hushnote could not \(operation) (Core Audio error \(status)). Check System Audio Recording Only access, quit and reopen Hushnote, then try again."
            }
        }
    }
}
