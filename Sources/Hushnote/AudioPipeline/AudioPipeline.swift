@preconcurrency import AVFoundation
import Foundation

/// The capture device, behind a seam.
///
/// `SystemAudioTapCapture` needs a real Core Audio aggregate device and a
/// granted privacy permission, neither of which a test can conjure. The
/// pipeline's own rules — what a session's duration means, which order start
/// and stop happen in, which session a failure belongs to — are independent of
/// the device and are verified through this protocol.
protocol SystemAudioCapturing: AnyObject, Sendable {
    func start() throws
    func stop()
    func pause() throws
    func resume() throws
}

extension SystemAudioTapCapture: SystemAudioCapturing {}

/// Everything the capture device has to say that is not audio.
enum CaptureNotice: Sendable {
    /// Capture cannot continue; the session has to be torn down.
    case failure(String)
    /// Audio was lost, but capture continues.
    case dropped(AudioDropReport)
}

typealias SystemAudioCaptureFactory = @Sendable (
    _ sampleHandler: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
    _ noticeHandler: @escaping @Sendable (CaptureNotice) -> Void
) -> any SystemAudioCapturing

/// Owns one meeting capture using macOS's system-audio-only Core Audio tap.
public actor AudioPipeline {
    public nonisolated let events: AsyncStream<AudioCaptureEvent>

    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let rootDirectory: URL
    private let captureFactory: SystemAudioCaptureFactory
    private var capture: (any SystemAudioCapturing)?
    private var output: CaptureOutputBridge?
    private var currentStatus: AudioCaptureStatus = .idle
    private var sessionID: UUID?
    private var sessionDirectory: URL?
    private var systemAudioURL: URL?

    public init(rootDirectory: URL? = nil) {
        self.init(rootDirectory: rootDirectory) { sampleHandler, noticeHandler in
            SystemAudioTapCapture(sampleHandler: sampleHandler, noticeHandler: noticeHandler)
        }
    }

    init(rootDirectory: URL?, captureFactory: @escaping SystemAudioCaptureFactory) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        eventContinuation = pair.continuation
        self.rootDirectory = rootDirectory ?? Self.defaultCaptureDirectory()
        self.captureFactory = captureFactory
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

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            // A meeting can be started more than once — the failure banner offers
            // "Try Again" against the same meeting ID. Each attempt gets its own
            // take so a retry can never destroy the audio of the attempt before it.
            let systemURL = try Self.allocateTakeURL(in: directory)

            let output = try CaptureOutputBridge(
                systemAudioURL: systemURL,
                eventContinuation: eventContinuation
            )
            output.failureHandler = { [weak self] message in
                Task { await self?.captureDidFail(message) }
            }
            let continuation = eventContinuation
            let capture = captureFactory({ [weak output] buffer, presentationSeconds in
                output?.consume(buffer, presentationSeconds: presentationSeconds)
            }, { [weak self] notice in
                switch notice {
                case .failure(let message):
                    Task { await self?.captureDidFail(message) }
                case .dropped(let report):
                    // Lost audio does not stop the meeting, but it must never
                    // pass silently: the CAF has no gaps, so everything after a
                    // drop shifts earlier against the transcript.
                    continuation.yield(.dropped(report))
                }
            })

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

    /// Reserves the next unused take inside a meeting's recovery directory.
    ///
    /// `AVAudioFile(forWriting:)` truncates on open, so reusing one filename would
    /// destroy the previous attempt's audio the instant a retry began — before
    /// capture had even restarted, and even if the retry then failed.
    static func allocateTakeURL(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        for index in 0..<10_000 {
            let candidate = directory.appending(path: "system-\(index).caf")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        throw AudioPipelineError.writerFailed(
            "no unused recovery take remains in \(directory.lastPathComponent)"
        )
    }

    /// The take holding the most audio, which is the one worth recovering.
    ///
    /// The pre-take filename `system.caf` is still honoured so meetings recorded
    /// before takes existed remain recoverable.
    static func longestTake(in directory: URL, fileManager: FileManager = .default) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return names
            .filter { $0 == "system.caf" || ($0.hasPrefix("system-") && $0.hasSuffix(".caf")) }
            .compactMap { name -> (url: URL, frames: AVAudioFramePosition)? in
                let url = directory.appending(path: name)
                guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
                    return nil
                }
                return (url, file.length)
            }
            // Ties resolve by name so the choice is stable across directory reads.
            .sorted { ($0.frames, $0.url.lastPathComponent) < ($1.frames, $1.url.lastPathComponent) }
            .last?
            .url
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
