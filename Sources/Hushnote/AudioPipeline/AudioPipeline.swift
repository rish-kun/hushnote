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
    /// The source graph changed and this take must be closed before capture is
    /// recreated against the new device configuration.
    case reconfigure(AudioCaptureTransitionKind, detail: String?)
}

typealias SystemAudioCaptureFactory = @Sendable (
    _ sampleHandler: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
    _ noticeHandler: @escaping @Sendable (CaptureNotice) -> Void
) -> any SystemAudioCapturing

typealias MicrophoneAudioCaptureFactory = @Sendable () -> MicrophoneAudioCapture

/// Owns one meeting capture using macOS's system-audio-only Core Audio tap.
public actor AudioPipeline {
    public nonisolated let events: AsyncStream<AudioCaptureEvent>

    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let rootDirectory: URL
    private let captureFactory: SystemAudioCaptureFactory
    private let microphoneCaptureFactory: MicrophoneAudioCaptureFactory
    private let reconfigurationRetryDelays: [Double]
    private let reconfigurationSleep: @Sendable (Double) async -> Void
    private var systemCapture: (any SystemAudioCapturing)?
    private var microphoneCapture: MicrophoneAudioCapture?
    private var systemOutput: CaptureOutputBridge?
    private var microphoneOutput: CaptureOutputBridge?
    private var timeline: CapturedMediaTimelineCoordinator?
    private var completedSourceArtifacts: [AudioCaptureSourceArtifact] = []
    private var selectedMicrophone: MicrophoneInputDevice?
    /// Invalidates work across actor reentrancy. Permission prompts and
    /// `MicrophoneAudioCapture` calls suspend this actor, so ownership cannot
    /// be inferred from which method started first.
    private var microphoneConfigurationGeneration: UInt64 = 0
    private var systemCaptureGeneration: UInt64 = 0
    private var isReconfiguringSystemCapture = false
    private var activeMicrophoneTakeID: UUID?
    private var currentStatus: AudioCaptureStatus = .idle
    private var sessionID: UUID?
    private var sessionDirectory: URL?
    private var systemAudioURL: URL?
    private var timelineStartMilliseconds: Int64 = 0
    private var isSleeping = false
    private var statusBeforeSleep: AudioCaptureStatus?
    private var microphoneWasEnabledBeforeSleep = false
    private var microphoneDeviceUIDBeforeSleep: String?

    public init(rootDirectory: URL? = nil) {
        self.init(
            rootDirectory: rootDirectory,
            captureFactory: { sampleHandler, noticeHandler in
                SystemAudioTapCapture(sampleHandler: sampleHandler, noticeHandler: noticeHandler)
            },
            microphoneCaptureFactory: { MicrophoneAudioCapture() },
            reconfigurationRetryDelays: [0, 0.25, 0.5, 1, 2, 4]
        )
    }

    init(rootDirectory: URL?, captureFactory: @escaping SystemAudioCaptureFactory) {
        self.init(
            rootDirectory: rootDirectory,
            captureFactory: captureFactory,
            microphoneCaptureFactory: { MicrophoneAudioCapture() },
            reconfigurationRetryDelays: [0, 0.25, 0.5, 1, 2, 4]
        )
    }

    init(
        rootDirectory: URL?,
        captureFactory: @escaping SystemAudioCaptureFactory,
        microphoneCaptureFactory: @escaping MicrophoneAudioCaptureFactory,
        reconfigurationRetryDelays: [Double] = [0, 0.25, 0.5, 1, 2, 4],
        reconfigurationSleep: @escaping @Sendable (Double) async -> Void = { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        eventContinuation = pair.continuation
        self.rootDirectory = rootDirectory ?? Self.defaultCaptureDirectory()
        self.captureFactory = captureFactory
        self.microphoneCaptureFactory = microphoneCaptureFactory
        self.reconfigurationRetryDelays = reconfigurationRetryDelays
        self.reconfigurationSleep = reconfigurationSleep
    }

    deinit {
        eventContinuation.finish()
    }

    public var status: AudioCaptureStatus { currentStatus }
    public var timelinePositionMilliseconds: Int64 {
        timeline?.positionMilliseconds ?? timelineStartMilliseconds
    }

    /// Starts a bot-free capture. System audio is always written; microphone
    /// capture is optional and remains a separate original when enabled.
    @discardableResult
    public func start(
        sessionID id: UUID = UUID(),
        configuration: AudioCaptureConfiguration = .init()
    ) async throws -> UUID {
        guard systemCapture == nil else { throw AudioPipelineError.alreadyRunning }
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
            let systemURL = try Self.allocateTakeURL(for: .system, in: directory)
            let timeline = CapturedMediaTimelineCoordinator(
                meetingStartMilliseconds: configuration.timelineStartMilliseconds
            )

            let output = try CaptureOutputBridge(
                source: .system,
                audioURL: systemURL,
                timelineCoordinator: timeline,
                eventContinuation: eventContinuation
            )
            let systemGeneration = advanceSystemCaptureGeneration()
            // Every failure route is stamped with the session that owns it.
            // Without that, a failure fired by a meeting the user has already
            // stopped tears down the next one, with the old message.
            output.failureHandler = { [weak self] message in
                Task {
                    await self?.captureDidFail(
                        message,
                        session: id,
                        generation: systemGeneration
                    )
                }
            }
            let continuation = eventContinuation
            let capture = captureFactory({ [weak output] buffer, presentationSeconds in
                output?.consume(buffer, presentationSeconds: presentationSeconds)
            }, { [weak self] notice in
                switch notice {
                case .failure(let message):
                    Task {
                        await self?.captureDidFail(
                            message,
                            session: id,
                            generation: systemGeneration
                        )
                    }
                case .dropped(let report):
                    // Lost audio does not stop the meeting, but it must never
                    // pass silently: the CAF has no gaps, so everything after a
                    // drop shifts earlier against the transcript.
                    continuation.yield(.dropped(report))
                case .reconfigure(let kind, let detail):
                    Task {
                        await self?.systemCaptureNeedsReconfiguration(
                            kind: kind,
                            detail: detail,
                            session: id,
                            generation: systemGeneration
                        )
                    }
                }
            })

            self.sessionID = id
            self.sessionDirectory = directory
            self.systemAudioURL = systemURL
            self.timelineStartMilliseconds = configuration.timelineStartMilliseconds
            self.timeline = timeline
            self.systemOutput = output
            self.systemCapture = capture
            completedSourceArtifacts = []
            selectedMicrophone = nil

            eventContinuation.yield(.sourceHealth(.init(source: .system, state: .arming)))
            output.begin()
            try capture.start()
            eventContinuation.yield(.sourceHealth(.init(source: .system, state: .healthy)))

            if configuration.capturesMicrophone {
                let generation = advanceMicrophoneConfigurationGeneration()
                do {
                    try await startMicrophone(
                        deviceUID: configuration.microphoneDeviceUID,
                        generation: generation
                    )
                } catch {
                    // System audio is already durable and healthy. An expected
                    // microphone failure is source-specific, not a reason to
                    // discard the meeting.
                }
            } else {
                eventContinuation.yield(.sourceHealth(.init(source: .microphone, state: .disabled)))
            }
            updateStatus(.recording)
            return id
        } catch {
            systemOutput?.finish()
            systemCapture?.stop()
            if let microphoneCapture { try? await microphoneCapture.stop() }
            sessionID = nil
            sessionDirectory = nil
            systemAudioURL = nil
            resetSession()
            let mappedError = Self.mapCaptureError(error)
            updateStatus(.failed(mappedError.localizedDescription))
            throw mappedError
        }
    }

    public func pause() async throws {
        guard currentStatus == .recording, let systemOutput, let systemCapture else {
            throw AudioPipelineError.notRunning
        }
        try systemCapture.pause()
        // Freeze the shared media clock before crossing to the microphone
        // actor. A disappearing microphone must not delay the global pause
        // boundary or turn a healthy system recording into a failed meeting.
        systemOutput.pause()
        microphoneOutput?.pause()
        let microphone = microphoneCapture
        let takeID = activeMicrophoneTakeID
        if let microphone {
            do {
                try await microphone.pause()
            } catch {
                // A toggle may have replaced this take while the await yielded.
                // Only a failure from the still-current take is actionable.
                if activeMicrophoneTakeID == takeID, microphoneCapture === microphone {
                    await closeMicrophoneTake()
                    eventContinuation.yield(.sourceHealth(.init(
                        source: .microphone,
                        state: .unavailable(error.localizedDescription)
                    )))
                }
            }
        }
        updateStatus(.paused)
    }

    public func resume() async throws {
        guard currentStatus == .paused, let systemOutput, let systemCapture else {
            throw AudioPipelineError.notRunning
        }
        // Accept samples before starting the device, mirroring `pause()`, which
        // stops accepting before it stops the device. The other order discards
        // whatever the HAL delivers between the two calls — and the device
        // starts delivering before `resume()` even returns.
        systemOutput.resume()
        microphoneOutput?.resume()
        do {
            try systemCapture.resume()
        } catch {
            // The device never restarted, so nothing may be accepted into a
            // meeting the user still sees as paused.
            systemOutput.pause()
            microphoneOutput?.pause()
            throw error
        }
        let microphone = microphoneCapture
        let takeID = activeMicrophoneTakeID
        if let microphone {
            do {
                try await microphone.resume()
            } catch {
                if activeMicrophoneTakeID == takeID, microphoneCapture === microphone {
                    await closeMicrophoneTake()
                    eventContinuation.yield(.sourceHealth(.init(
                        source: .microphone,
                        state: .unavailable(error.localizedDescription)
                    )))
                }
            }
        }
        updateStatus(.recording)
    }

    /// Closes every active take before macOS suspends the process while keeping
    /// ownership of the meeting. The shared media clock is frozen first, so a
    /// callback racing the sleep notification is either durably included in
    /// the closing take or rejected from the meeting entirely.
    @discardableResult
    public func prepareForSleep(
        at monotonicSeconds: Double = ProcessInfo.processInfo.systemUptime
    ) async throws -> Int64 {
        guard currentStatus == .recording || currentStatus == .paused,
              let timeline,
              !isSleeping
        else { throw AudioPipelineError.notRunning }

        statusBeforeSleep = currentStatus
        microphoneWasEnabledBeforeSleep = microphoneCapture != nil
        microphoneDeviceUIDBeforeSleep = selectedMicrophone?.id
        timeline.suspend(reason: .sleep, at: monotonicSeconds)
        let boundary = timeline.positionMilliseconds

        isSleeping = true
        _ = advanceSystemCaptureGeneration()
        closeSystemTake()
        await closeMicrophoneTake()
        return boundary
    }

    /// Recreates fresh source takes after wake without inserting the sleep
    /// interval into captured-media time. A failed system restart leaves the
    /// timeline suspended so a bounded caller may safely retry.
    @discardableResult
    func resumeAfterWake(
        at monotonicSeconds: Double = ProcessInfo.processInfo.systemUptime
    ) async throws -> CapturedMediaOmission? {
        guard isSleeping,
              let sessionID,
              let sessionDirectory,
              let timeline,
              let statusBeforeSleep
        else { throw AudioPipelineError.notRunning }

        let systemURL = try Self.allocateTakeURL(for: .system, in: sessionDirectory)
        let output = try CaptureOutputBridge(
            source: .system,
            audioURL: systemURL,
            timelineCoordinator: timeline,
            eventContinuation: eventContinuation
        )
        let systemGeneration = advanceSystemCaptureGeneration()
        output.failureHandler = { [weak self] message in
            Task {
                await self?.captureDidFail(
                    message,
                    session: sessionID,
                    generation: systemGeneration
                )
            }
        }
        let continuation = eventContinuation
        let capture = captureFactory({ [weak output] buffer, presentationSeconds in
            output?.consume(buffer, presentationSeconds: presentationSeconds)
        }, { [weak self] notice in
            switch notice {
            case .failure(let message):
                Task {
                    await self?.captureDidFail(
                        message,
                        session: sessionID,
                        generation: systemGeneration
                    )
                }
            case .dropped(let report):
                continuation.yield(.dropped(report))
            case .reconfigure(let kind, let detail):
                Task {
                    await self?.systemCaptureNeedsReconfiguration(
                        kind: kind,
                        detail: detail,
                        session: sessionID,
                        generation: systemGeneration
                    )
                }
            }
        })

        eventContinuation.yield(.sourceHealth(.init(source: .system, state: .arming)))
        output.begin()
        do {
            try capture.start()
            if statusBeforeSleep == .paused {
                try capture.pause()
                output.pause()
            }
        } catch {
            capture.stop()
            output.finish()
            try? FileManager.default.removeItem(at: systemURL)
            eventContinuation.yield(.sourceHealth(.init(
                source: .system,
                state: .unavailable(error.localizedDescription)
            )))
            throw error
        }

        systemCapture = capture
        systemOutput = output
        eventContinuation.yield(.sourceHealth(.init(source: .system, state: .healthy)))

        let omission: CapturedMediaOmission?
        if statusBeforeSleep == .recording {
            // System audio owns wake success. Resume its durable clock before
            // microphone permission or hardware work can suspend this actor.
            omission = timeline.resume(at: monotonicSeconds)
        } else {
            // The user's pause already owns the suspended timeline. Sleep is
            // still persisted by the lifecycle observer using its wall clock,
            // and Resume later ends the original pause normally.
            omission = CapturedMediaOmission(
                reason: .sleep,
                atMilliseconds: timeline.positionMilliseconds,
                wallDurationMilliseconds: nil
            )
        }

        if microphoneWasEnabledBeforeSleep {
            let generation = advanceMicrophoneConfigurationGeneration()
            do {
                try await startMicrophone(
                    deviceUID: microphoneDeviceUIDBeforeSleep,
                    generation: generation
                )
            } catch {
                // System audio is healthy. A missing microphone remains a
                // source-specific warning and does not abort wake recovery.
            }
        }

        isSleeping = false
        self.statusBeforeSleep = nil
        microphoneWasEnabledBeforeSleep = false
        microphoneDeviceUIDBeforeSleep = nil
        return omission
    }

    /// Applies the microphone toggle to the current meeting. Enabling or
    /// changing devices opens a fresh take; disabling closes the current one.
    /// System audio remains untouched throughout.
    public func setMicrophoneCaptureEnabled(
        _ isEnabled: Bool,
        deviceUID: String? = nil
    ) async throws {
        guard currentStatus == .recording || currentStatus == .paused else {
            throw AudioPipelineError.notRunning
        }
        let generation = advanceMicrophoneConfigurationGeneration()
        if !isEnabled {
            await closeMicrophoneTake()
            if microphoneConfigurationGeneration == generation {
                eventContinuation.yield(.sourceHealth(.init(source: .microphone, state: .disabled)))
            }
            return
        }

        if microphoneCapture != nil, selectedMicrophone?.id == deviceUID ||
            (deviceUID == nil && selectedMicrophone?.isDefault == true) {
            return
        }
        if microphoneCapture != nil { await closeMicrophoneTake() }
        guard microphoneConfigurationGeneration == generation else { return }
        try await startMicrophone(deviceUID: deviceUID, generation: generation)
    }

    @discardableResult
    public func stop() async throws -> AudioCaptureArtifacts {
        guard let sessionID,
              let sessionDirectory,
              let systemAudioURL
        else {
            throw AudioPipelineError.notRunning
        }

        updateStatus(.stopping)
        _ = advanceMicrophoneConfigurationGeneration()
        closeSystemTake()
        await closeMicrophoneTake()
        let sourceArtifacts = completedSourceArtifacts
        // Use exact written-frame durations for the durable session boundary.
        // The addressing timeline rounds every callback to milliseconds, and
        // accumulating that sub-millisecond loss would undercount long takes.
        let sessionDuration = sourceArtifacts.reduce(Int64(0)) { duration, artifact in
            max(
                duration,
                artifact.timelineStartMilliseconds
                    + artifact.durationMilliseconds
                    - timelineStartMilliseconds
            )
        }
        let artifacts = AudioCaptureArtifacts(
            sessionID: sessionID,
            directoryURL: sessionDirectory,
            systemAudioURL: systemAudioURL,
            durationMilliseconds: sessionDuration,
            sourceArtifacts: sourceArtifacts
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
        try allocateTakeURL(for: .system, in: directory, fileManager: fileManager)
    }

    static func allocateTakeURL(
        for source: AudioSource,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        for index in 0..<10_000 {
            let candidate = directory.appending(path: "\(source.rawValue)-\(index).caf")
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

    private func captureDidFail(
        _ message: String,
        session: UUID,
        generation: UInt64
    ) async {
        // A failure only speaks for the session that raised it. Anything else
        // is a message from a meeting that is already over.
        guard sessionID == session, systemCaptureGeneration == generation else { return }
        currentStatus = .stopping
        _ = advanceMicrophoneConfigurationGeneration()
        closeSystemTake()
        await closeMicrophoneTake()
        resetSession()
        updateStatus(.failed(message))
    }

    private func systemCaptureNeedsReconfiguration(
        kind: AudioCaptureTransitionKind,
        detail: String?,
        session: UUID,
        generation: UInt64
    ) async {
        guard sessionID == session,
              systemCaptureGeneration == generation,
              !isSleeping,
              !isReconfiguringSystemCapture,
              currentStatus == .recording || currentStatus == .paused,
              let sessionDirectory,
              let timeline
        else { return }

        isReconfiguringSystemCapture = true
        _ = advanceSystemCaptureGeneration()
        closeSystemTake()
        let boundary = timeline.positionMilliseconds
        eventContinuation.yield(.transition(.init(
            source: .system,
            kind: kind,
            timelineMilliseconds: boundary,
            detail: detail
        )))
        eventContinuation.yield(.sourceHealth(.init(source: .system, state: .arming)))

        var finalError: Error?
        for delay in reconfigurationRetryDelays {
            await reconfigurationSleep(delay)
            guard sessionID == session,
                  isReconfiguringSystemCapture,
                  !isSleeping,
                  currentStatus == .recording || currentStatus == .paused
            else { return }
            do {
                try openSystemTake(
                    sessionID: session,
                    sessionDirectory: sessionDirectory,
                    timeline: timeline,
                    paused: currentStatus == .paused
                )
                isReconfiguringSystemCapture = false
                eventContinuation.yield(.sourceHealth(.init(source: .system, state: .healthy)))
                return
            } catch {
                finalError = error
            }
        }

        isReconfiguringSystemCapture = false
        let message = finalError?.localizedDescription
            ?? "The system audio device did not become available."
        eventContinuation.yield(.sourceHealth(.init(
            source: .system,
            state: .unavailable(message)
        )))
    }

    private func openSystemTake(
        sessionID: UUID,
        sessionDirectory: URL,
        timeline: CapturedMediaTimelineCoordinator,
        paused: Bool
    ) throws {
        let url = try Self.allocateTakeURL(for: .system, in: sessionDirectory)
        let output = try CaptureOutputBridge(
            source: .system,
            audioURL: url,
            timelineCoordinator: timeline,
            eventContinuation: eventContinuation
        )
        let generation = advanceSystemCaptureGeneration()
        output.failureHandler = { [weak self] message in
            Task {
                await self?.captureDidFail(
                    message,
                    session: sessionID,
                    generation: generation
                )
            }
        }
        let continuation = eventContinuation
        let capture = captureFactory({ [weak output] buffer, presentationSeconds in
            output?.consume(buffer, presentationSeconds: presentationSeconds)
        }, { [weak self] notice in
            switch notice {
            case .failure(let message):
                Task {
                    await self?.captureDidFail(
                        message,
                        session: sessionID,
                        generation: generation
                    )
                }
            case .dropped(let report):
                continuation.yield(.dropped(report))
            case .reconfigure(let kind, let detail):
                Task {
                    await self?.systemCaptureNeedsReconfiguration(
                        kind: kind,
                        detail: detail,
                        session: sessionID,
                        generation: generation
                    )
                }
            }
        })
        output.begin()
        do {
            try capture.start()
            if paused {
                try capture.pause()
                output.pause()
            }
        } catch {
            capture.stop()
            output.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        systemCapture = capture
        systemOutput = output
    }

    private func closeSystemTake() {
        let capture = systemCapture
        let output = systemOutput
        systemCapture = nil
        systemOutput = nil

        capture?.stop()
        if let output {
            output.finish()
            if output.durationMilliseconds > 0 {
                completedSourceArtifacts.append(output.sourceArtifact)
            } else {
                try? FileManager.default.removeItem(at: output.sourceArtifact.audioURL)
            }
        }
    }

    private func startMicrophone(deviceUID: String?, generation: UInt64) async throws {
        guard let sessionID, let sessionDirectory, let timeline else {
            throw AudioPipelineError.notRunning
        }
        guard microphoneConfigurationGeneration == generation else { return }
        let takeID = UUID()
        activeMicrophoneTakeID = takeID
        eventContinuation.yield(.sourceHealth(.init(source: .microphone, state: .arming)))
        let url = try Self.allocateTakeURL(for: .microphone, in: sessionDirectory)
        let output = try CaptureOutputBridge(
            source: .microphone,
            audioURL: url,
            timelineCoordinator: timeline,
            eventContinuation: eventContinuation
        )
        output.failureHandler = { [weak self] message in
            Task {
                await self?.microphoneDidFail(
                    message,
                    session: sessionID,
                    takeID: takeID
                )
            }
        }
        let capture = microphoneCaptureFactory()
        output.begin()

        do {
            let device = try await capture.start(
                selectedDeviceUID: deviceUID,
                sampleHandler: { [weak output] buffer, presentationSeconds in
                    output?.consume(buffer, presentationSeconds: presentationSeconds)
                }
            )
            guard sessionID == self.sessionID,
                  microphoneConfigurationGeneration == generation,
                  activeMicrophoneTakeID == takeID
            else {
                try? await capture.stop()
                output.finish()
                try? FileManager.default.removeItem(at: url)
                return
            }
            if currentStatus == .paused {
                output.pause()
                try await capture.pause()
                guard sessionID == self.sessionID,
                      microphoneConfigurationGeneration == generation,
                      activeMicrophoneTakeID == takeID
                else {
                    try? await capture.stop()
                    output.finish()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
            }
            microphoneOutput = output
            microphoneCapture = capture
            selectedMicrophone = device
            eventContinuation.yield(.sourceHealth(.init(source: .microphone, state: .healthy)))
        } catch {
            try? await capture.stop()
            output.finish()
            let isCurrent = sessionID == self.sessionID
                && microphoneConfigurationGeneration == generation
                && activeMicrophoneTakeID == takeID
            if isCurrent {
                microphoneOutput = nil
                microphoneCapture = nil
                selectedMicrophone = nil
                activeMicrophoneTakeID = nil
            }
            if output.durationMilliseconds == 0 {
                try? FileManager.default.removeItem(at: url)
            } else if isCurrent {
                completedSourceArtifacts.append(output.sourceArtifact)
            }
            if isCurrent {
                eventContinuation.yield(.sourceHealth(.init(
                    source: .microphone,
                    state: .unavailable(error.localizedDescription)
                )))
            }
            if isCurrent { throw error }
            return
        }
    }

    private func closeMicrophoneTake() async {
        // Relinquish actor-owned state before awaiting another actor. If a new
        // take starts during teardown, this close must only finish its snapshot.
        let capture = microphoneCapture
        let output = microphoneOutput
        let device = selectedMicrophone
        activeMicrophoneTakeID = nil
        microphoneCapture = nil
        microphoneOutput = nil
        selectedMicrophone = nil

        if let capture { try? await capture.stop() }
        if let output {
            output.finish()
            if output.durationMilliseconds > 0 {
                completedSourceArtifacts.append(
                    microphoneArtifact(from: output, device: device)
                )
            } else {
                try? FileManager.default.removeItem(at: output.sourceArtifact.audioURL)
            }
        }
    }

    private func microphoneArtifact(
        from output: CaptureOutputBridge,
        device: MicrophoneInputDevice?
    ) -> AudioCaptureSourceArtifact {
        let artifact = output.sourceArtifact
        return AudioCaptureSourceArtifact(
            source: artifact.source,
            audioURL: artifact.audioURL,
            timelineStartMilliseconds: artifact.timelineStartMilliseconds,
            durationMilliseconds: artifact.durationMilliseconds,
            deviceUID: device?.id,
            deviceName: device?.name
        )
    }

    func microphoneDidFail(_ message: String, session: UUID, takeID: UUID) async {
        guard sessionID == session, activeMicrophoneTakeID == takeID else { return }
        await closeMicrophoneTake()
        eventContinuation.yield(.sourceHealth(.init(
            source: .microphone,
            state: .unavailable(message)
        )))
    }

    private func resetSession() {
        _ = advanceSystemCaptureGeneration()
        _ = advanceMicrophoneConfigurationGeneration()
        systemCapture = nil
        microphoneCapture = nil
        systemOutput = nil
        microphoneOutput = nil
        timeline = nil
        completedSourceArtifacts = []
        selectedMicrophone = nil
        activeMicrophoneTakeID = nil
        sessionID = nil
        sessionDirectory = nil
        systemAudioURL = nil
        timelineStartMilliseconds = 0
        isSleeping = false
        statusBeforeSleep = nil
        microphoneWasEnabledBeforeSleep = false
        microphoneDeviceUIDBeforeSleep = nil
        isReconfiguringSystemCapture = false
    }

    var microphoneTakeIdentifier: UUID? { activeMicrophoneTakeID }

    @discardableResult
    private func advanceMicrophoneConfigurationGeneration() -> UInt64 {
        microphoneConfigurationGeneration &+= 1
        return microphoneConfigurationGeneration
    }

    @discardableResult
    private func advanceSystemCaptureGeneration() -> UInt64 {
        systemCaptureGeneration &+= 1
        return systemCaptureGeneration
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

    /// Turns a raw Core Audio status into the failure the user can act on.
    ///
    /// `'nope'` (kAudioHardwareIllegalOperationError) is what the HAL returns
    /// both for a privacy denial and for a device-graph update still in flight,
    /// so the operation it arrived at is what tells them apart. Tap creation is
    /// where TCC refuses; `AudioDeviceStart` is where the genuine transient
    /// occurs, and `startDeviceWithRecovery` already retries that one. Without
    /// this, a user who has never granted System Audio Recording was told to
    /// "wait a moment and try again", and `.permissionDenied` — the message
    /// naming the toggle to turn on — was thrown from nowhere at all.
    static func mapCaptureError(_ error: Error) -> Error {
        guard case AudioPipelineError.coreAudioFailure(let operation, let status) = error,
              operation == SystemAudioTapCapture.Operation.createTap,
              status == OSStatus(bitPattern: 0x6E6F7065)
        else { return error }
        return AudioPipelineError.permissionDenied
    }
}
