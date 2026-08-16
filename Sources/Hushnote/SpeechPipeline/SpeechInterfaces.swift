import Foundation

public enum StreamingKind: String, Codable, Sendable {
    case native
    case utterance
    case slidingWindow
}

public enum SpeechAccelerator: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
    case neuralEngine
}

public struct SpeechEngineDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var streamingKind: StreamingKind
    public var supportsWordTimestamps: Bool
    public var supportedAccelerators: Set<SpeechAccelerator>

    public init(
        id: String,
        displayName: String,
        streamingKind: StreamingKind,
        supportsWordTimestamps: Bool,
        supportedAccelerators: Set<SpeechAccelerator>
    ) {
        self.id = id
        self.displayName = displayName
        self.streamingKind = streamingKind
        self.supportsWordTimestamps = supportsWordTimestamps
        self.supportedAccelerators = supportedAccelerators
    }
}

public struct TranscriptionSessionConfiguration: Equatable, Sendable {
    public var meetingID: UUID
    public var languageCode: String?
    public var confirmationLagSegments: Int
    public var minimumDecodeIntervalMilliseconds: Int64

    public init(
        meetingID: UUID,
        languageCode: String? = nil,
        confirmationLagSegments: Int = 2,
        minimumDecodeIntervalMilliseconds: Int64 = 1_000
    ) {
        self.meetingID = meetingID
        self.languageCode = languageCode
        self.confirmationLagSegments = max(0, confirmationLagSegments)
        self.minimumDecodeIntervalMilliseconds = max(250, minimumDecodeIntervalMilliseconds)
    }
}

public protocol TranscriptionEngine: Sendable {
    var descriptor: SpeechEngineDescriptor { get }

    func load(model: SpeechModel) async throws
    func start(configuration: TranscriptionSessionConfiguration) async throws
        -> AsyncThrowingStream<TranscriptDelta, Error>
    func push(_ frame: AudioFrame) async throws
    func finish() async throws
    func cancel() async
}

public struct DiarizationConfiguration: Equatable, Sendable {
    public var minimumSpeakers: Int?
    public var maximumSpeakers: Int?

    public init(minimumSpeakers: Int? = nil, maximumSpeakers: Int? = nil) {
        self.minimumSpeakers = minimumSpeakers
        self.maximumSpeakers = maximumSpeakers
    }
}

public protocol SpeakerDiarizationEngine: Sendable {
    var descriptor: SpeechEngineDescriptor { get }

    func prepare() async throws
    func diarize(
        audioFileURL: URL,
        configuration: DiarizationConfiguration
    ) async throws -> [SpeakerTurn]
    func diarize(
        samples: [Float],
        sampleRate: Int,
        configuration: DiarizationConfiguration
    ) async throws -> [SpeakerTurn]
}

public enum SpeechPipelineError: Error, Equatable, LocalizedError, Sendable {
    case modelNotLoaded
    case sessionAlreadyRunning
    case sessionNotRunning
    case meetingMismatch
    case unsupportedSampleRate(Int)
    case invalidFrameSequence
    case noTranscriptionResult
    case invalidDiarizationConfiguration

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Load a transcription model before starting a meeting."
        case .sessionAlreadyRunning: "A transcription session is already running."
        case .sessionNotRunning: "No transcription session is running."
        case .meetingMismatch: "The audio frame belongs to a different meeting."
        case .unsupportedSampleRate(let rate): "Expected 16 kHz mono audio, received \(rate) Hz."
        case .invalidFrameSequence: "Audio frames must arrive in increasing sequence order."
        case .noTranscriptionResult: "The speech model returned no transcription result."
        case .invalidDiarizationConfiguration: "The requested speaker count range is invalid."
        }
    }
}
