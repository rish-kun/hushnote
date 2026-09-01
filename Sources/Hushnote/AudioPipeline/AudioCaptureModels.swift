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

public struct AudioCaptureConfiguration: Equatable, Sendable {
    public var capturesMicrophone: Bool
    /// Nil follows the current system-default input device.
    public var microphoneDeviceUID: String?
    /// Meeting-time offset used when appending another recording session.
    public var timelineStartMilliseconds: Int64

    public init(
        capturesMicrophone: Bool = false,
        microphoneDeviceUID: String? = nil,
        timelineStartMilliseconds: Int64 = 0
    ) {
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceUID = microphoneDeviceUID
        self.timelineStartMilliseconds = max(0, timelineStartMilliseconds)
    }
}

public enum AudioSourceCaptureState: Equatable, Sendable {
    case disabled
    case arming
    case healthy
    case unavailable(String)
}

public struct AudioSourceCaptureHealth: Equatable, Sendable {
    public let source: AudioSource
    public let state: AudioSourceCaptureState

    public init(source: AudioSource, state: AudioSourceCaptureState) {
        self.source = source
        self.state = state
    }
}

public enum AudioCaptureTransitionKind: String, Equatable, Sendable {
    case deviceChanged
    case formatChanged
}

public struct AudioCaptureTransition: Equatable, Sendable {
    public let source: AudioSource
    public let kind: AudioCaptureTransitionKind
    public let timelineMilliseconds: Int64
    public let detail: String?

    public init(
        source: AudioSource,
        kind: AudioCaptureTransitionKind,
        timelineMilliseconds: Int64,
        detail: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.timelineMilliseconds = timelineMilliseconds
        self.detail = detail
    }
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
    /// The end of the normalized audio window that produced this level. The
    /// sample-clock position lets the diagnostics layer distinguish silence
    /// from a stalled callback without borrowing wall-clock time.
    public let timelineMilliseconds: Int64?

    public init(
        source: AudioSource,
        rms: Float,
        peak: Float,
        timelineMilliseconds: Int64? = nil
    ) {
        self.source = source
        self.rms = rms
        self.peak = peak
        self.timelineMilliseconds = timelineMilliseconds
    }
}

/// Audio that never reached the recovery file.
///
/// The CAF is bare continuous PCM with no timestamps, so a dropped buffer
/// shortens the recording rather than leaving a gap: everything after it shifts
/// earlier relative to the live transcript and the diarization.
public struct AudioDropReport: Equatable, Sendable {
    /// Buffers lost since the previous report because the writer could not keep
    /// up — a disk stall longer than the queue's roughly one second of headroom.
    public let backpressureBuffers: Int
    /// Buffers lost since the previous report because the tap's buffer list no
    /// longer matched the format capture was started with.
    public let formatMismatchBuffers: Int
    /// Frames lost since the previous report, at the tap's own sample rate.
    public let droppedFrames: Int64
    /// Buffers lost over the whole session so far.
    public let totalDroppedBuffers: Int

    public init(
        backpressureBuffers: Int,
        formatMismatchBuffers: Int,
        droppedFrames: Int64,
        totalDroppedBuffers: Int
    ) {
        self.backpressureBuffers = backpressureBuffers
        self.formatMismatchBuffers = formatMismatchBuffers
        self.droppedFrames = droppedFrames
        self.totalDroppedBuffers = totalDroppedBuffers
    }
}

public enum AudioCaptureEvent: Sendable {
    case status(AudioCaptureStatus)
    case chunk(CapturedAudioChunk)
    case level(AudioLevel)
    case dropped(AudioDropReport)
    case sourceHealth(AudioSourceCaptureHealth)
    case transition(AudioCaptureTransition)
}

/// One normalized original produced by a source-specific capture writer.
public struct AudioCaptureSourceArtifact: Equatable, Sendable {
    public let source: AudioSource
    public let audioURL: URL
    public let timelineStartMilliseconds: Int64
    public let durationMilliseconds: Int64
    public let deviceUID: String?
    public let deviceName: String?

    public init(
        source: AudioSource,
        audioURL: URL,
        timelineStartMilliseconds: Int64 = 0,
        durationMilliseconds: Int64,
        deviceUID: String? = nil,
        deviceName: String? = nil
    ) {
        self.source = source
        self.audioURL = audioURL
        self.timelineStartMilliseconds = timelineStartMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.deviceUID = deviceUID
        self.deviceName = deviceName
    }
}

public struct AudioCaptureArtifacts: Equatable, Sendable {
    public let sessionID: UUID
    public let directoryURL: URL
    public let systemAudioURL: URL
    public let durationMilliseconds: Int64
    public let sourceArtifacts: [AudioCaptureSourceArtifact]

    public init(
        sessionID: UUID,
        directoryURL: URL,
        systemAudioURL: URL,
        durationMilliseconds: Int64,
        sourceArtifacts: [AudioCaptureSourceArtifact]? = nil
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.systemAudioURL = systemAudioURL
        self.durationMilliseconds = durationMilliseconds
        self.sourceArtifacts = sourceArtifacts ?? [AudioCaptureSourceArtifact(
            source: .system,
            audioURL: systemAudioURL,
            durationMilliseconds: durationMilliseconds
        )]
    }

    public func artifact(for source: AudioSource) -> AudioCaptureSourceArtifact? {
        sourceArtifacts.first { $0.source == source }
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
