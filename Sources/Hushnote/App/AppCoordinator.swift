import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog

enum CoordinatorError: Error, LocalizedError {
    case noTranscript
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noTranscript: "This meeting does not have a transcript yet."
        case .providerUnavailable(let reason): reason
        }
    }
}

@MainActor
@Observable
final class AppCoordinator {
    let state: AppViewState
    let applicationDataURL: URL
    let store: MeetingStore

    var localModelPath = ""
    var localLlamaExecutablePath = AppCoordinator.defaultLlamaServerPath
    var applicationDataPath: String { applicationDataURL.path }

    @ObservationIgnored private let credentials = KeychainCredentialStore()
    @ObservationIgnored private let codexProvider = CodexAppServerInsightProvider()
    @ObservationIgnored private let logger = Logger(subsystem: "dev.rishit.hushnote", category: "coordinator")
    @ObservationIgnored private var audioPipeline: AudioPipeline?
    @ObservationIgnored private var speechEngine: WhisperKitTranscriptionEngine?
    @ObservationIgnored private var diarizationEngine: FluidAudioDiarizationEngine?
    @ObservationIgnored private var loadedModel: SpeechModel?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var liveSetupTask: Task<Void, Never>?
    /// Invalidates asynchronous live-ASR setup whenever capture stops or a new
    /// session supersedes it. Whisper/Core ML loading is not cancellation-safe,
    /// so correctness cannot depend on the cancelled task returning promptly.
    @ObservationIgnored private var liveSessionGeneration: UUID?
    @ObservationIgnored private var sequenceNumbers: [AudioSource: Int64] = [:]
    @ObservationIgnored private var assembler: TranscriptAssembler?
    @ObservationIgnored private var cachedSegments: [UUID: [TranscriptSegment]] = [:]
    @ObservationIgnored private var pendingEditTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingNoteTasks: [UUID: Task<Void, Never>] = [:]

    init(state: AppViewState) {
        self.state = state
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hushnote", directoryHint: .isDirectory)
        applicationDataURL = base
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            store = try MeetingStore(databaseURL: base.appending(path: "hushnote.sqlite"))
        } catch {
            fatalError("Unable to open the local Hushnote database: \(error.localizedDescription)")
        }
    }

    func bootstrap() async {
        do {
            let interrupted = try await store.recoverInterruptedMeetings()
            for meeting in interrupted {
                try? await registerRecoveryAudio(for: meeting.id)
            }
            let meetings = try await store.meetings()
            state.meetings = meetings.map(Self.listItem)
        } catch {
            logger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
            state.markFailed(.init(kind: .database, message: "The local meeting database could not be loaded."))
        }
    }

    func createMeetingNote() async {
        let meeting = Meeting(
            title: "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))",
            updatedAt: Date(),
            status: .idle,
            retainsAudio: state.retainAudio
        )
        do {
            try await store.saveMeeting(meeting)
            state.meetings.insert(Self.listItem(meeting), at: 0)
            state.meetingNotes[meeting.id] = ""
            state.selection = .meeting(meeting.id)
            state.selectedWorkspaceTab = "Notes"
        } catch {
            state.markFailed(.init(kind: .database, message: "A new meeting note could not be created: \(error.localizedDescription)"))
        }
    }

    func startMeeting(meetingID requestedMeetingID: UUID? = nil) async {
        guard !state.recordingPhase.isBusy else { return }
        let generation = UUID()
        liveSessionGeneration = generation
        state.recordingPhase = .preparing
        var meeting: Meeting
        if let requestedMeetingID, let stored = try? await store.meeting(id: requestedMeetingID) {
            meeting = stored
            meeting.startedAt = Date()
            meeting.updatedAt = Date()
            meeting.status = .idle
            meeting.errorMessage = nil
        } else {
            meeting = Meeting(
                title: resolvedTitle,
                startedAt: Date(),
                updatedAt: Date(),
                status: .idle,
                retainsAudio: state.retainAudio
            )
        }

        do {
            try await store.saveMeeting(meeting)
            let item = Self.listItem(meeting)
            if let index = state.meetings.firstIndex(where: { $0.id == meeting.id }) {
                state.meetings[index] = item
            } else {
                state.meetings.insert(item, at: 0)
            }
            state.selection = .meeting(meeting.id)
            assembler = TranscriptAssembler(meetingID: meeting.id)
            sequenceNumbers = [:]

            let pipeline = AudioPipeline(rootDirectory: applicationDataURL.appending(path: "RecoveryAudio"))
            audioPipeline = pipeline
            observeAudioEvents(pipeline, meetingID: meeting.id)
            _ = try await pipeline.start(sessionID: meeting.id)
            try await store.updateMeetingStatus(id: meeting.id, status: .recording)
            if let index = state.meetings.firstIndex(where: { $0.id == meeting.id }) {
                state.meetings[index].status = .recording
            }
            state.markRecordingStarted(meetingID: meeting.id)
            startLiveTranscription(meetingID: meeting.id, generation: generation)
        } catch {
            if let audioPipeline {
                _ = try? await audioPipeline.stop()
            }
            eventTask?.cancel()
            transcriptTask?.cancel()
            self.audioPipeline = nil
            if liveSessionGeneration == generation { liveSessionGeneration = nil }
            logger.error("Start failed: \(error.localizedDescription, privacy: .public)")
            try? await store.updateMeetingStatus(id: meeting.id, status: .failed, errorMessage: error.localizedDescription)
            state.markFailed(.init(
                kind: .classifyCapture(error),
                message: error.localizedDescription,
                meetingID: meeting.id
            ))
        }
    }

    private func startLiveTranscription(meetingID: UUID, generation: UUID) {
        liveSetupTask?.cancel()
        liveSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let liveModel = self.speechModel(named: self.state.draft.liveModel)
                let engine = self.speechEngine ?? WhisperKitTranscriptionEngine()
                if self.loadedModel != liveModel {
                    try await engine.load(model: liveModel)
                    guard self.liveSessionGeneration == generation,
                          self.state.activeMeetingID == meetingID,
                          self.state.recordingPhase.isCapturing else {
                        await engine.cancel()
                        return
                    }
                    self.speechEngine = engine
                    self.loadedModel = liveModel
                }
                guard self.liveSessionGeneration == generation,
                      self.state.activeMeetingID == meetingID,
                      self.state.recordingPhase.isCapturing else {
                    await engine.cancel()
                    return
                }
                let stream = try await engine.start(configuration: .init(
                    meetingID: meetingID,
                    languageCode: self.languageCode,
                    confirmationLagSegments: 2,
                    minimumDecodeIntervalMilliseconds: 1_000
                ))
                guard self.liveSessionGeneration == generation,
                      self.state.activeMeetingID == meetingID,
                      self.state.recordingPhase.isCapturing else {
                    await engine.cancel()
                    return
                }
                self.observeTranscript(stream, meetingID: meetingID, generation: generation)
            } catch {
                self.logger.warning("Live transcription unavailable; recording continues: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled,
                      self.liveSessionGeneration == generation,
                      self.state.activeMeetingID == meetingID,
                      self.state.recordingPhase.isCapturing else { return }
                self.state.recordingNotice = "Recording is safe. Live transcription is unavailable; the final pass will run after Stop."
            }
        }
    }

    func togglePause() async {
        guard let audioPipeline else { return }
        do {
            if state.recordingPhase == .paused {
                try await audioPipeline.resume()
                state.markPaused(false)
            } else {
                try await audioPipeline.pause()
                state.markPaused(true)
            }
        } catch {
            state.markFailed(.init(
                kind: .classifyCapture(error),
                message: error.localizedDescription,
                meetingID: state.activeMeetingID
            ))
        }
    }

    func stopMeeting() async {
        guard let meetingID = state.activeMeetingID, let audioPipeline else { return }
        // Invalidate setup before the first suspension. A Whisper model load can
        // outlive cancellation; its late result must never attach to a stopped
        // meeting or a subsequent recording.
        liveSessionGeneration = nil
        state.markFinalizing(stage: .savingAudio, progress: 0.05)

        do {
            // Stop the Core Audio tap first. Model cancellation or finalization
            // must never extend recording after the user presses Stop.
            let artifacts = try await audioPipeline.stop()
            eventTask?.cancel()
            eventTask = nil

            // Make the durable recovery boundary immediately after audio close.
            // Nothing model-related is allowed to delay these writes.
            try await store.updateMeetingStatus(id: meetingID, status: .finalizing)
            if let index = state.meetings.firstIndex(where: { $0.id == meetingID }) {
                state.meetings[index].status = .finalizing
            }
            let systemTrack = MeetingAudioTrack(
                meetingID: meetingID,
                source: .system,
                fileURL: artifacts.systemAudioURL,
                sampleRate: 48_000,
                channelCount: 1,
                durationMilliseconds: artifacts.durationMilliseconds,
                isComplete: true
            )
            try await store.saveAudioTrack(systemTrack)

            state.updateFinalization(stage: .stoppingLiveTranscription, progress: 0.15)
            liveSetupTask?.cancel()
            // Do not await this task. WhisperKit/Core ML model construction does
            // not reliably cooperate with cancellation.
            liveSetupTask = nil
            transcriptTask?.cancel()
            transcriptTask = nil
            if let liveEngine = speechEngine {
                // Best-effort cleanup occurs independently. Waiting can block
                // behind an in-flight Core ML decode, while the final pass owns
                // a separate engine and can begin safely.
                Task { await liveEngine.cancel() }
            }

            let liveSegments = assembler?.snapshot.segments ?? []
            speechEngine = nil
            loadedModel = nil

            let finalRevision = (assembler?.snapshot.revision ?? 0) + 1
            var finalSegments: [TranscriptSegment]
            do {
                let finalizer = WhisperKitFinalTranscriber()
                let snapshot = try await finalizer.transcribe(
                    meetingID: meetingID,
                    tracks: [systemTrack],
                    model: speechModel(named: state.draft.finalModel),
                    languageCode: languageCode,
                    revision: finalRevision,
                    progress: { [weak self] progress in
                        await MainActor.run {
                            guard let self,
                                  self.state.activeMeetingID == meetingID,
                                  case .finalizing = self.state.recordingPhase else { return }
                            switch progress {
                            case .loadingModel:
                                self.state.updateFinalization(stage: .loadingFinalModel, progress: 0.25)
                            case .transcribing:
                                self.state.updateFinalization(stage: .transcribing, progress: 0.45)
                            }
                        }
                    }
                )
                finalSegments = snapshot.segments
            } catch {
                logger.warning("Final ASR unavailable; preserving live transcript: \(error.localizedDescription, privacy: .public)")
                guard !liveSegments.isEmpty else { throw error }
                finalSegments = liveSegments
            }
            if !finalSegments.isEmpty {
                let target = systemTrack
                if FileManager.default.fileExists(atPath: target.fileURL.path) {
                    state.updateFinalization(stage: .diarizing, progress: 0.72)
                    do {
                        let diarizer = diarizationEngine ?? FluidAudioDiarizationEngine()
                        diarizationEngine = diarizer
                        let turns = try await diarizer.diarize(audioFileURL: target.fileURL)
                        finalSegments = SpeakerAttributor.assign(turns: turns, to: finalSegments)
                    } catch {
                        logger.warning("Diarization unavailable: \(error.localizedDescription, privacy: .public)")
                        finalSegments = SpeakerAttributor.assign(turns: [], to: finalSegments)
                    }
                }

                let nextRevision = finalRevision
                let final = finalSegments.map { segment in
                    var copy = segment
                    copy.revision = nextRevision
                    copy.stability = .final
                    return copy
                }
                let snapshot = TranscriptSnapshot(meetingID: meetingID, revision: nextRevision, segments: final)
                try await store.replaceTranscript(snapshot)
                cachedSegments[meetingID] = final
                state.transcript = final.map(Self.lineItem)
            }

            var meeting = try await store.meeting(id: meetingID) ?? Meeting(id: meetingID, title: resolvedTitle)
            meeting.endedAt = Date()
            meeting.updatedAt = Date()
            meeting.status = .ready
            try await store.saveMeeting(meeting)
            updateListItem(meeting, excerpt: finalSegments.first?.text ?? "Meeting captured locally")

            state.updateFinalization(stage: .generatingInsights, progress: 0.9)
            await generateAutomaticInsightsIfAvailable(meetingID: meetingID, segments: finalSegments)

            if !state.retainAudio {
                try await store.deleteAudioFiles(meetingID: meetingID)
            }

            self.audioPipeline = nil
            state.selectedWorkspaceTab = "Summary"
            state.markFinished()
        } catch {
            logger.error("Finalization failed: \(error.localizedDescription, privacy: .public)")
            try? await store.updateMeetingStatus(id: meetingID, status: .interrupted, errorMessage: error.localizedDescription)
            if var meeting = try? await store.meeting(id: meetingID) {
                meeting.status = .interrupted
                meeting.errorMessage = error.localizedDescription
                updateListItem(meeting, excerpt: "Recording is safe. Retry finalization when ready.")
            }
            self.audioPipeline = nil
            state.markFailed(.init(
                kind: .finalization,
                message: "The recording is safe, but finalization stopped: \(error.localizedDescription)",
                meetingID: meetingID
            ))
        }
    }

    private func generateAutomaticInsightsIfAvailable(
        meetingID: UUID,
        segments: [TranscriptSegment]
    ) async {
        guard !segments.isEmpty else { return }
        do {
            let provider = try await selectedInsightProvider()
            guard case .available = await provider.healthCheck() else { return }
            let output = try await InsightPipeline(provider: provider).generateInsights(
                transcript: segments.map(InsightTranscriptSegment.init(transcriptSegment:))
            )
            try await store.saveInsightSnapshot(
                meetingID: meetingID,
                providerID: provider.descriptor.id,
                output: output
            )
            let insights = output.insights
            state.insights.summary = insights.overview.text
            state.insights.topics = insights.topics.map(\.text)
            state.insights.decisions = insights.decisions.map(\.text)
            state.insights.actions = insights.actionItems.map { action in
                [action.text, action.owner.map { "Owner: \($0)" }, action.dueDate.map { "Due: \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            state.insights.openQuestions = insights.openQuestions.map(\.text)
        } catch {
            logger.info("Automatic insights skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMeeting(_ id: UUID) async {
        do {
            let segments = try await store.segments(meetingID: id)
            let snapshots = try await store.insightSnapshots(meetingID: id)
            if let meeting = try await store.meeting(id: id),
               NoteReloadPolicy.shouldAdopt(
                   stored: meeting.notes,
                   current: state.meetingNotes[id],
                   hasPendingSave: pendingNoteTasks[id] != nil
               ) {
                state.meetingNotes[id] = meeting.notes
            }
            if let latest = snapshots.first {
                applyInsights(latest.output.insights)
            } else if state.activeMeetingID != id {
                state.insights = InsightWorkspaceState()
            }
            cachedSegments[id] = segments
            guard state.activeMeetingID != id else { return }
            state.transcript = segments.map(Self.lineItem)
        } catch {
            state.report(.meetingLoad, error.localizedDescription)
        }
    }

    func queueMeetingNotes(meetingID: UUID, text: String) {
        state.meetingNotes[meetingID] = text
        pendingNoteTasks[meetingID]?.cancel()
        pendingNoteTasks[meetingID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                try await self.store.updateMeetingNotes(id: meetingID, notes: text)
                self.pendingNoteTasks[meetingID] = nil
            } catch is CancellationError {
                return
            } catch {
                self?.state.report(.noteSave, error.localizedDescription)
            }
        }
    }

    func recoverMeeting(_ id: UUID) async {
        state.activeMeetingID = id
        state.markFinalizing(stage: .savingAudio, progress: 0.05, detail: "Checking saved audio…")
        do {
            try await registerRecoveryAudio(for: id)
            let tracks = try await store.audioTracks(meetingID: id)
            guard !tracks.isEmpty else {
                throw CoordinatorError.providerUnavailable("No recoverable audio was found for this meeting.")
            }
            try await store.updateMeetingStatus(id: id, status: .finalizing)

            let finalizer = WhisperKitFinalTranscriber()
            var final = try await finalizer.transcribe(
                meetingID: id,
                tracks: tracks,
                model: speechModel(named: state.draft.finalModel),
                languageCode: languageCode,
                revision: 1,
                progress: { [weak self] progress in
                    await MainActor.run {
                        guard let self,
                              self.state.activeMeetingID == id,
                              case .finalizing = self.state.recordingPhase else { return }
                        switch progress {
                        case .loadingModel:
                            self.state.updateFinalization(stage: .loadingFinalModel, progress: 0.25)
                        case .transcribing:
                            self.state.updateFinalization(stage: .transcribing, progress: 0.45)
                        }
                    }
                }
            ).segments

            if let systemTrack = tracks.first(where: { $0.source == .system }) {
                state.updateFinalization(stage: .diarizing, progress: 0.72)
                do {
                    let diarizer = FluidAudioDiarizationEngine()
                    let turns = try await diarizer.diarize(audioFileURL: systemTrack.fileURL)
                    final = SpeakerAttributor.assign(turns: turns, to: final)
                } catch {
                    final = SpeakerAttributor.assign(turns: [], to: final)
                }
            }
            final = final.map { segment in
                var copy = segment
                copy.stability = .final
                return copy
            }
            try await store.replaceTranscript(.init(meetingID: id, revision: 1, segments: final))
            cachedSegments[id] = final
            state.transcript = final.map(Self.lineItem)

            guard var meeting = try await store.meeting(id: id) else {
                throw CoordinatorError.providerUnavailable("The interrupted meeting could not be loaded.")
            }
            meeting.endedAt = Date()
            meeting.updatedAt = Date()
            meeting.status = .ready
            meeting.errorMessage = nil
            try await store.saveMeeting(meeting)
            updateListItem(meeting, excerpt: final.first?.text ?? "Recovered local transcript")
            if !meeting.retainsAudio { try await store.deleteAudioFiles(meetingID: id) }
            state.markFinished()
        } catch {
            try? await store.updateMeetingStatus(id: id, status: .interrupted, errorMessage: error.localizedDescription)
            if var meeting = try? await store.meeting(id: id) {
                meeting.status = .interrupted
                meeting.errorMessage = error.localizedDescription
                updateListItem(meeting, excerpt: "Recording is safe. Retry finalization when ready.")
            }
            state.markFailed(.init(
                kind: .finalization,
                message: "Recovery stopped, but the original audio remains safe: \(error.localizedDescription)",
                meetingID: id
            ))
        }
    }

    func searchMeetings(_ query: String) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            state.applySearchMatches(nil, for: cleaned)
            return
        }
        do {
            let matches = try await store.searchSegments(cleaned, limit: 200)
            state.applySearchMatches(Set(matches.map(\.meetingID)), for: cleaned)
        } catch {
            state.applySearchMatches([], for: cleaned)
        }
    }

    func queueTranscriptEdit(id: String, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        for meetingID in cachedSegments.keys {
            guard let index = cachedSegments[meetingID]?.firstIndex(where: { $0.id == id }) else { continue }
            cachedSegments[meetingID]?[index].text = cleaned
            break
        }
        pendingEditTasks[id]?.cancel()
        pendingEditTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                try await self.store.editSegmentText(id: id, text: cleaned)
                self.pendingEditTasks[id] = nil
            } catch is CancellationError {
                return
            } catch {
                self?.state.report(.transcriptEditSave, error.localizedDescription)
            }
        }
    }

    func generateInsights(meetingID: UUID) async {
        state.insights.isGenerating = true
        state.insights.error = nil
        defer { state.insights.isGenerating = false }
        do {
            let segments = try await transcriptSegments(for: meetingID)
            guard !segments.isEmpty else { throw CoordinatorError.noTranscript }
            let provider = try await selectedInsightProvider()
            guard case .available = await provider.healthCheck() else {
                throw CoordinatorError.providerUnavailable("The selected provider is not ready. Check Settings and try again.")
            }
            let runID = try await store.beginProviderRun(
                meetingID: meetingID,
                providerID: provider.descriptor.id,
                purpose: "meeting-insights"
            )
            let output: ValidatedMeetingInsights
            do {
                output = try await InsightPipeline(provider: provider).generateInsights(
                    transcript: segments.map(InsightTranscriptSegment.init(transcriptSegment:))
                )
                try await store.saveInsightSnapshot(
                    meetingID: meetingID,
                    providerID: provider.descriptor.id,
                    output: output
                )
                try await store.finishProviderRun(id: runID, status: .succeeded)
            } catch {
                try? await store.finishProviderRun(id: runID, status: .failed, errorMessage: error.localizedDescription)
                throw error
            }
            let insights = output.insights
            state.insights.summary = insights.overview.text
            state.insights.topics = insights.topics.map(\.text)
            state.insights.decisions = insights.decisions.map(\.text)
            state.insights.actions = insights.actionItems.map { action in
                [action.text, action.owner.map { "Owner: \($0)" }, action.dueDate.map { "Due: \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            state.insights.openQuestions = insights.openQuestions.map(\.text)
        } catch {
            state.insights.error = error.localizedDescription
        }
    }

    func answerQuestion() async {
        guard let meetingID = selectedMeetingID else { return }
        state.insights.error = nil
        // Without this the Ask button produced no visual change at all for the
        // length of an LLM round trip.
        state.insights.isGenerating = true
        defer { state.insights.isGenerating = false }
        do {
            let segments = try await transcriptSegments(for: meetingID)
            let provider = try await selectedInsightProvider()
            let output = try await InsightPipeline(provider: provider).answer(
                question: state.question,
                transcript: segments.map(InsightTranscriptSegment.init(transcriptSegment:))
            )
            state.insights.answer = output.answer.answer
            state.insights.answerTimestamps = output.answer.citations.map { Double($0.startMilliseconds) / 1_000 }
        } catch {
            state.insights.error = error.localizedDescription
        }
    }

    /// What the models screen knows about each model, keyed by model id.
    private(set) var modelAvailability: [String: ModelAvailability] = [:]

    func downloadModel(_ model: SpeechModel) async {
        guard ModelListPolicy.canDownload(
            availability: modelAvailability[model.id] ?? .notInstalled,
            phase: state.recordingPhase
        ) else { return }
        modelAvailability[model.id] = .downloading
        do {
            let engine = speechEngine ?? WhisperKitTranscriptionEngine()
            try await engine.load(model: model)
            speechEngine = engine
            loadedModel = model
            modelAvailability[model.id] = .ready
        } catch {
            modelAvailability[model.id] = .failed(error.localizedDescription)
            state.markFailed(.init(kind: .modelDownload, message: "Model download failed: \(error.localizedDescription)"))
        }
    }

    func export(meetingID: UUID, format: MeetingExportFormat) {
        guard let meeting = state.meetings.first(where: { $0.id == meetingID }) else { return }
        let transcript = cachedSegments[meetingID] ?? []
        do {
            try MeetingExporter.export(meeting: meeting, transcript: transcript, insights: state.insights, format: format)
        } catch {
            state.report(.export, error.localizedDescription)
        }
    }

    /// Whether a key is already in the Keychain, so the field can say so.
    func hasStoredCredential(for provider: InsightProviderChoice) async -> Bool {
        guard let key = Self.credentialKey(for: provider) else { return false }
        return (try? await credentials.credential(for: key)) ?? nil != nil
    }

    /// Saves the key, then actually verifies it. The key is never held anywhere
    /// but the Keychain and the caller's own field.
    func saveAndVerifyAPIKey(
        _ key: String,
        provider: InsightProviderChoice
    ) async -> CredentialFieldState {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let credentialKey = Self.credentialKey(for: provider) else {
            return .absent
        }
        do {
            try await credentials.setCredential(value, for: credentialKey)
        } catch {
            return .failed("The Keychain refused to save the key: \(error.localizedDescription)")
        }
        guard case .available = await (try? selectedInsightProvider())?.healthCheck()
            ?? .unavailable("The provider could not be created.")
        else {
            return .failed("The key was saved, but the provider did not accept it.")
        }
        return .verified
    }

    private static func credentialKey(for provider: InsightProviderChoice) -> ProviderCredential? {
        switch provider {
        case .openAI: .openAIAPIKey
        case .anthropic: .anthropicAPIKey
        default: nil
        }
    }

    func connectChatGPT() async {
        do {
            let challenge = try await codexProvider.beginBrowserLogin()
            if case .browser(let url) = challenge.mode {
                NSWorkspace.shared.open(url)
            }
            try await codexProvider.waitForLogin(loginID: challenge.loginID)
        } catch {
            state.markFailed(.init(kind: .providerConnection, message: "ChatGPT connection failed: \(error.localizedDescription)"))
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealApplicationData() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationDataURL])
    }

    private func observeAudioEvents(_ pipeline: AudioPipeline, meetingID: UUID) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in pipeline.events {
                guard let self else { return }
                switch event {
                case .level(let level):
                    let value = min(1, max(0, Double(level.rms) * 8))
                    self.state.systemLevel = value
                case .chunk(let chunk):
                    guard let speechEngine = self.speechEngine, self.loadedModel != nil else { continue }
                    let sequence = self.sequenceNumbers[chunk.source, default: 0] + 1
                    self.sequenceNumbers[chunk.source] = sequence
                    try? await speechEngine.push(chunk.audioFrame(meetingID: meetingID, sequenceNumber: sequence))
                case .dropped(let report):
                    self.logger.warning("""
                        Audio buffers dropped: \(report.backpressureBuffers, privacy: .public) to \
                        backpressure, \(report.formatMismatchBuffers, privacy: .public) to format \
                        mismatch, \(report.droppedFrames, privacy: .public) frames; \
                        \(report.totalDroppedBuffers, privacy: .public) this session
                        """)
                case .status(let status):
                    if case .failed(let message) = status {
                        self.state.markFailed(.init(
                            kind: .capture,
                            message: message,
                            meetingID: meetingID
                        ))
                    }
                }
            }
        }
    }

    private func observeTranscript(
        _ stream: AsyncThrowingStream<TranscriptDelta, Error>,
        meetingID: UUID,
        generation: UUID
    ) {
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in stream {
                    guard self.liveSessionGeneration == generation,
                          self.state.activeMeetingID == meetingID,
                          self.state.recordingPhase.isCapturing else { return }
                    guard var assembler = self.assembler else { return }
                    let snapshot = assembler.apply(delta)
                    guard snapshot.meetingID == meetingID else { continue }
                    self.assembler = assembler
                    self.cachedSegments[snapshot.meetingID] = snapshot.segments
                    self.state.transcript = snapshot.segments.map(Self.lineItem)
                    let stable = snapshot.segments.filter { $0.stability >= .stable }
                    if !stable.isEmpty { try? await self.store.upsertSegments(stable) }
                }
            } catch {
                self.logger.error("Live transcription ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func selectedInsightProvider() async throws -> any InsightProvider {
        switch state.selectedProvider {
        case .local:
            let executable = localLlamaExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = localModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !executable.isEmpty, FileManager.default.isExecutableFile(atPath: executable) else {
                throw CoordinatorError.providerUnavailable("Choose a valid llama-server executable in Settings.")
            }
            guard !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
                throw CoordinatorError.providerUnavailable("Choose a downloaded GGUF model in Settings.")
            }
            let configuration = try LocalLlamaServer.Configuration(
                executableURL: URL(filePath: executable),
                modelURL: URL(filePath: model)
            )
            let server = LocalLlamaServer(configuration: configuration)
            return try LlamaCppInsightProvider(localServer: server)
        case .openAI:
            return OpenAIInsightProvider(model: "gpt-5-mini", credentials: credentials)
        case .anthropic:
            return AnthropicInsightProvider(model: "claude-sonnet-4-5-20250929", credentials: credentials)
        case .chatGPT:
            return codexProvider
        }
    }

    private func transcriptSegments(for id: UUID) async throws -> [TranscriptSegment] {
        if let cached = cachedSegments[id], !cached.isEmpty { return cached }
        let result = try await store.segments(meetingID: id)
        cachedSegments[id] = result
        return result
    }

    private var selectedMeetingID: UUID? {
        if case .meeting(let id) = state.selection { return id }
        return state.activeMeetingID
    }

    private var languageCode: String? {
        switch state.draft.language {
        case "English": "en"
        case "English + Hindi": nil
        default: nil
        }
    }

    private var resolvedTitle: String {
        let value = state.draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))" : value
    }

    private func speechModel(named name: String) -> SpeechModel {
        SpeechModelResolver.model(named: name)
    }

    private func updateListItem(_ meeting: Meeting, excerpt: String) {
        let replacement = MeetingListItem(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt ?? meeting.createdAt,
            duration: (meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt ?? meeting.createdAt),
            template: state.draft.template,
            excerpt: excerpt,
            isRecoverable: meeting.status == .interrupted,
            status: meeting.status
        )
        if let index = state.meetings.firstIndex(where: { $0.id == meeting.id }) {
            state.meetings[index] = replacement
        } else {
            state.meetings.insert(replacement, at: 0)
        }
    }

    private static func listItem(_ meeting: Meeting) -> MeetingListItem {
        MeetingListItem(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt ?? meeting.createdAt,
            duration: meeting.endedAt?.timeIntervalSince(meeting.startedAt ?? meeting.createdAt) ?? 0,
            template: .general,
            excerpt: meeting.status == .interrupted ? "Recording can be recovered and finalized." : "Local meeting transcript",
            isRecoverable: meeting.status == .interrupted,
            status: meeting.status
        )
    }

    private static func lineItem(_ segment: TranscriptSegment) -> TranscriptLineItem {
        TranscriptLineItem(
            id: UUID(uuidString: segment.id) ?? stableUUID(segment.id),
            segmentID: segment.id,
            speaker: segment.speakerName ?? segment.speakerID ?? "Speaker",
            start: Double(segment.startMilliseconds) / 1_000,
            end: Double(segment.endMilliseconds) / 1_000,
            text: segment.text,
            isProvisional: segment.stability != .final
        )
    }

    private static var defaultLlamaServerPath: String {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
    }

    private func applyInsights(_ insights: MeetingInsights) {
        state.insights.summary = insights.overview.text
        state.insights.topics = insights.topics.map(\.text)
        state.insights.decisions = insights.decisions.map(\.text)
        state.insights.actions = insights.actionItems.map { action in
            [action.text, action.owner.map { "Owner: \($0)" }, action.dueDate.map { "Due: \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
        state.insights.openQuestions = insights.openQuestions.map(\.text)
        state.insights.error = nil
    }

    private func registerRecoveryAudio(for meetingID: UUID) async throws {
        let directory = applicationDataURL
            .appending(path: "RecoveryAudio", directoryHint: .isDirectory)
            .appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        // A meeting may hold several takes if capture was retried; recover the
        // longest one. Pre-take `system.caf` recordings are still found.
        guard let url = AudioPipeline.longestTake(in: directory) else { return }
        let file = try AVAudioFile(forReading: url)
        let milliseconds = Int64((Double(file.length) / file.processingFormat.sampleRate * 1_000).rounded())
        try await store.saveAudioTrack(.init(
            meetingID: meetingID,
            source: .system,
            fileURL: url,
            sampleRate: file.processingFormat.sampleRate,
            channelCount: Int(file.processingFormat.channelCount),
            durationMilliseconds: milliseconds,
            isComplete: true
        ))
    }

    private static func stableUUID(_ string: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in string.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(index & 0xff)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

}
