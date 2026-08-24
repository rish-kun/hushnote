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
    private(set) var modelStoragePaths: ModelStoragePaths
    private(set) var modelStorageMigrationProgress: ModelStorageMigrationProgress?
    private(set) var isChangingModelStorage = false
    private(set) var modelStorageStatus: String?
    private(set) var queuedModelStoragePath: String?
    private(set) var installedModelFolders: [String: URL] = [:]
    private(set) var installedModelAllocatedBytes: [String: Int64] = [:]
    @ObservationIgnored private var storageScanGeneration: UUID?

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
    /// The assembler's snapshot is the whole meeting on every delta; this is
    /// what keeps the live upsert to the part of it that changed.
    @ObservationIgnored private var liveWrites = LiveTranscriptWriteSet()
    @ObservationIgnored private var cachedSegments: [UUID: [TranscriptSegment]] = [:]
    @ObservationIgnored private var pendingEditTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingNoteTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let downloader: any SpeechModelDownloading
    @ObservationIgnored private let storageAccounting: any StorageAccounting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferences: AppPreferences
    /// One per model, so a download can be cancelled by the row that started it.
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var queuedModelStorageChange: (destination: ModelStoragePaths, migrate: Bool)?
    @ObservationIgnored private var meetingLoadGeneration: UUID?
    @ObservationIgnored private var insightTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var insightGenerations: [UUID: UUID] = [:]
    @ObservationIgnored private let meetingAudioExporter = MeetingAudioExportService()
    @ObservationIgnored private var audioExportTasks: [UUID: Task<Void, Never>] = [:]
    /// Cancellation is cooperative. A replaced export can finish after its
    /// successor starts, so every UI update is stamped with its own generation.
    @ObservationIgnored private var audioExportGenerations: [UUID: UUID] = [:]

    init(
        state: AppViewState,
        downloader: any SpeechModelDownloading = WhisperKitModelDownloader(),
        storageAccounting: any StorageAccounting = StorageAccountingService(),
        defaults: UserDefaults = .standard
    ) {
        self.state = state
        self.downloader = downloader
        self.storageAccounting = storageAccounting
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        self.preferences = preferences
        self.modelStoragePaths = preferences.modelStoragePaths
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hushnote", directoryHint: .isDirectory)
        applicationDataURL = base
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            store = try MeetingStore(databaseURL: base.appending(path: "hushnote.sqlite"))
        } catch {
            fatalError("Unable to open the local Hushnote database: \(error.localizedDescription)")
        }
        // The models screen writes the choice down; this is where a later launch
        // reads it back, before anything can render the draft.
        SpeechModelDefaults.apply(to: &self.state.draft, from: defaults)
        self.state.liveTranscriptionEnabled = SpeechModelDefaults.liveTranscriptionEnabled(from: defaults)
        self.state.selectedProvider = preferences.selectedProvider
        self.state.retainAudio = preferences.retainAudio
        self.state.meetingWorkspaceTabs = preferences.meetingTabs
        self.localModelPath = preferences.localModelPath
        self.localLlamaExecutablePath = preferences.llamaExecutablePath ?? Self.defaultLlamaServerPath
    }

    func bootstrap() async {
        refreshInstalledModels()
        await refreshInstalledModelSizes()
        do {
            _ = try await store.failInterruptedProviderRuns()
            _ = try await store.purgeDeletedMeetings(
                olderThan: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
            let interrupted = try await store.recoverInterruptedMeetings()
            for meeting in interrupted {
                try? await registerRecoveryAudio(for: meeting.id)
            }
            let meetings = try await store.meetings()
            state.meetings = meetings.map(Self.listItem)
            state.recentlyDeletedMeetings = try await store.recentlyDeleted().map(Self.listItem)
            try await refreshFolderState()
            let ids = Set(meetings.map(\.id))
            state.meetingWorkspaceTabs = preferences.pruneMeetingTabs(keeping: ids)
            if let destination = preferences.sidebarDestination {
                let resolved = AppViewState.resolvedSidebarDestination(
                    destination,
                    meetingIDs: ids,
                    folderIDs: Set(state.folders.map(\.id))
                )
                if resolved != destination {
                    state.selection = .meetings
                    preferences.sidebarDestination = .meetings
                } else {
                    state.selection = destination
                }
            }
        } catch {
            logger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
            state.markFailed(.init(kind: .database, message: "The local meeting database could not be loaded."))
        }
    }

    func createMeetingNote(inFolder requestedFolderID: UUID? = nil) async {
        let folderID = requestedFolderID ?? state.selectedFolderID
        let meeting = Meeting(
            title: "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))",
            updatedAt: Date(),
            status: .idle,
            retainsAudio: state.retainAudio,
            folderID: folderID
        )
        do {
            try await store.saveMeeting(meeting)
            state.meetings.insert(Self.listItem(meeting), at: 0)
            state.meetingNotes[meeting.id] = ""
            setSelection(.meeting(meeting.id))
            setWorkspaceTab(.notes, for: meeting.id)
        } catch {
            state.markFailed(.init(kind: .database, message: "A new meeting note could not be created: \(error.localizedDescription)"))
        }
    }

    // MARK: - Meeting folders

    @discardableResult
    func createMeetingFolder(named name: String) async -> MeetingFolder? {
        do {
            let folder = try await store.createMeetingFolder(name: name)
            state.folders.append(folder)
            state.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            state.folderMeetingCounts[folder.id] = 0
            return folder
        } catch {
            state.report(.folderManagement, error.localizedDescription)
            return nil
        }
    }

    func renameMeetingFolder(_ id: UUID, to name: String) async {
        do {
            try await store.renameMeetingFolder(id: id, name: name)
            try await refreshFolderState()
        } catch {
            state.report(.folderManagement, error.localizedDescription)
        }
    }

    func deleteMeetingFolder(_ id: UUID) async {
        do {
            try await store.deleteMeetingFolder(id: id)
            // Folder deletion may unfile meetings that are selected, recording,
            // or in Recently Deleted. Reloading the durable lists keeps every
            // projection coherent without changing meeting timestamps.
            let meetings = try await store.meetings()
            state.meetings = meetings.map(Self.listItem)
            state.recentlyDeletedMeetings = try await store.recentlyDeleted().map(Self.listItem)
            try await refreshFolderState()
            if state.selection == .folder(id) { setSelection(.meetings) }
        } catch {
            state.report(.folderManagement, error.localizedDescription)
        }
    }

    /// Organization is safe during capture: the store changes only `folderID`.
    func moveMeeting(_ id: UUID, toFolder folderID: UUID?) async {
        do {
            try await store.moveMeeting(id: id, toFolder: folderID)
            if let meeting = try await store.meeting(id: id) {
                replaceMeetingListItem(meeting)
            }
            try await refreshFolderState()
        } catch {
            state.report(.folderManagement, error.localizedDescription)
        }
    }

    func startMeeting(meetingID requestedMeetingID: UUID? = nil) async {
        guard !state.recordingPhase.isBusy else { return }
        let generation = UUID()
        liveSessionGeneration = generation
        state.recordingPhase = .preparing
        state.recordingStartupStage = .arming
        var meeting: Meeting
        if let requestedMeetingID, let stored = try? await store.meeting(id: requestedMeetingID) {
            meeting = stored
            meeting.startedAt = Date()
            meeting.updatedAt = Date()
            meeting.status = .idle
            meeting.errorMessage = nil
            meeting.retainsAudio = state.retainAudio
        } else {
            meeting = Meeting(
                title: resolvedTitle,
                startedAt: Date(),
                updatedAt: Date(),
                status: .idle,
                retainsAudio: state.retainAudio,
                folderID: state.selectedFolderID
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
            setSelection(.meeting(meeting.id))
            state.activeMeetingID = meeting.id
            assembler = TranscriptAssembler(meetingID: meeting.id)
            sequenceNumbers = [:]
            liveWrites.reset()

            let pipeline = AudioPipeline(rootDirectory: applicationDataURL.appending(path: "RecoveryAudio"))
            audioPipeline = pipeline
            observeAudioEvents(pipeline, meetingID: meeting.id, generation: generation)
            _ = try await pipeline.start(sessionID: meeting.id)
            // AudioDeviceStart can deliver its first callback before `start()`
            // returns. Never regress the ready state that callback established.
            if state.recordingPhase == .preparing {
                state.recordingStartupStage = .waitingForFirstBuffer
            }
            try await store.updateMeetingStatus(id: meeting.id, status: .recording)
            if let index = state.meetings.firstIndex(where: { $0.id == meeting.id }) {
                state.meetings[index].status = .recording
            }
            // The first audio callback promotes Preparing to Recording and only
            // then begins optional live ASR. The file writer is upstream of
            // both, so no opening audio waits for a model.
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
                    try await engine.load(
                        model: liveModel,
                        modelFolder: nil,
                        downloadBase: self.modelStoragePaths.whisperDownloadBase
                    )
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
        defer {
            Task { @MainActor [weak self] in
                await self?.applyQueuedModelStorageChangeIfPossible()
            }
        }
        // Invalidate setup before the first suspension. A Whisper model load can
        // outlive cancellation; its late result must never attach to a stopped
        // meeting or a subsequent recording.
        liveSessionGeneration = nil
        // The final pass replaces this meeting's rows wholesale under new
        // identifiers, so what the live loop wrote stops describing the database.
        liveWrites.reset()
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

            state.updateFinalization(
                stage: LiveTranscriptionPolicy.stageAfterSavingAudio(
                    isEnabled: state.liveTranscriptionEnabled
                ),
                progress: 0.15
            )
            liveSetupTask?.cancel()
            // Do not await this task. WhisperKit/Core ML model construction does
            // not reliably cooperate with cancellation.
            liveSetupTask = nil
            transcriptTask?.cancel()
            transcriptTask = nil
            if let liveEngine = speechEngine {
                // The live model (large-v3-turbo, 616 MB) and the final model
                // (large-v3, 598 MB) are different artifacts, so an unfinished
                // teardown leaves both resident exactly at the final pass's peak.
                // `cancel()` releases the decoder, which makes this wait worth
                // roughly 600 MB at the moment the machine has least to spare.
                //
                // It stays bounded because the risk is real: `cancel()` queues on
                // the engine actor behind an in-flight Core ML decode. Five
                // seconds comfortably exceeds one decode of Whisper's 30-second
                // window on the slowest Mac this ships to, and a wedged decode
                // then costs a pause in finalization rather than a hang — the
                // teardown finishes on its own and its memory is merely late.
                await BoundedWait.finish(within: .seconds(5)) { await liveEngine.cancel() }
            }

            let liveSegments = assembler?.snapshot.segments ?? []
            speechEngine = nil
            loadedModel = nil

            let finalRevision = (assembler?.snapshot.revision ?? 0) + 1
            var finalSegments: [TranscriptSegment]
            do {
                let finalizer = WhisperKitFinalTranscriber(
                    downloadBase: modelStoragePaths.whisperDownloadBase
                )
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
                guard LiveTranscriptionPolicy.fallback(liveSegmentCount: liveSegments.count)
                    == .keepLiveTranscript else { throw error }
                finalSegments = liveSegments
            }
            if !finalSegments.isEmpty {
                let target = systemTrack
                if FileManager.default.fileExists(atPath: target.fileURL.path) {
                    state.updateFinalization(stage: .diarizing, progress: 0.72)
                    do {
                        let diarizer = diarizationEngine ?? FluidAudioDiarizationEngine(
                            modelsDirectory: modelStoragePaths.diarizationModelsDirectory
                        )
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

            if MeetingAudioRetentionPolicy.shouldDeleteAfterFinalization(
                meetingRetainsAudio: meeting.retainsAudio
            ) {
                try await store.deleteAudioFiles(meetingID: meetingID)
            }

            self.audioPipeline = nil
            setWorkspaceTab(.summary, for: meetingID)
            state.markFinished()
            // Insights are useful, but they must not hold the completed meeting
            // hostage behind a multi-minute CLI or network round trip.
            Task { [weak self] in
                await self?.generateInsights(meetingID: meetingID)
            }
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
            let saved = try await store.saveGeneratedInsights(
                meetingID: meetingID,
                providerID: provider.descriptor.id,
                output: output
            )
            applySavedGeneratedInsights(saved, output: output, meetingID: meetingID)
        } catch {
            logger.info("Automatic insights skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMeeting(_ id: UUID) async {
        let generation = UUID()
        meetingLoadGeneration = generation
        do {
            let segments = try await store.segments(meetingID: id)
            let versions = try await store.summaryVersions(meetingID: id, limit: 50)
            let activeVersion = try await store.activeSummaryVersion(meetingID: id)
            if let meeting = try await store.meeting(id: id),
               NoteReloadPolicy.shouldAdopt(
                   stored: meeting.notes,
                   current: state.meetingNotes[id],
                   hasPendingSave: pendingNoteTasks[id] != nil
               ) {
                state.meetingNotes[id] = meeting.notes
            }
            guard meetingLoadGeneration == generation,
                  state.selection == .meeting(id) else {
                cachedSegments[id] = segments
                return
            }
            if let activeVersion {
                if !state.insights(for: id).hasUnsavedSummaryChanges {
                    await applySummaryVersion(activeVersion, meetingID: id)
                }
                state.updateInsights(for: id) {
                    $0.summaryVersions = versions
                    $0.hasMoreSummaryVersions = versions.count == 50
                    $0.candidateSummaryVersionID = nil
                }
            } else if state.activeMeetingID != id,
                      !state.insights(for: id).isGenerating {
                // Navigating away and back starts another load. Do not erase an
                // in-flight summary's meeting-scoped progress merely because it
                // has not produced its first durable snapshot yet.
                state.replaceInsights(InsightWorkspaceState(), for: id)
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

    // MARK: - Authored meeting content

    func renameMeeting(meetingID: UUID, title: String) async -> Bool {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 200 else {
            state.report(.meetingRename, "Use a meeting name between 1 and 200 characters.")
            return false
        }
        do {
            try await store.updateMeetingTitle(id: meetingID, title: cleaned)
            if let index = state.meetings.firstIndex(where: { $0.id == meetingID }) {
                state.meetings[index].title = cleaned
            }
            if let index = state.recentlyDeletedMeetings.firstIndex(where: { $0.id == meetingID }) {
                state.recentlyDeletedMeetings[index].title = cleaned
            }
            return true
        } catch {
            state.report(.meetingRename, error.localizedDescription)
            return false
        }
    }

    func promptToRenameMeeting(meetingID: UUID) {
        let current = state.meetings.first(where: { $0.id == meetingID })?.title
            ?? state.recentlyDeletedMeetings.first(where: { $0.id == meetingID })?.title
            ?? "Meeting"
        let field = NSTextField(string: current)
        field.placeholderString = "Meeting name"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename meeting"
        alert.informativeText = "This name is used throughout Hushnote and for future exports."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await renameMeeting(meetingID: meetingID, title: field.stringValue) }
    }

    func renameSpeaker(segmentID: String, name: String) async -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        do {
            let cached = cachedSegments.values.lazy.compactMap { segments in
                segments.first(where: { $0.id == segmentID })
            }.first
            let segment: TranscriptSegment?
            if let cached {
                segment = cached
            } else {
                segment = try await store.segment(id: segmentID)
            }
            guard let segment, let speakerID = segment.speakerID else {
                throw CoordinatorError.providerUnavailable("This transcript line has no speaker identity to rename.")
            }
            _ = try await store.renameSpeaker(
                meetingID: segment.meetingID,
                speakerID: speakerID,
                to: cleaned
            )
            if var segments = cachedSegments[segment.meetingID] {
                for index in segments.indices where segments[index].speakerID == speakerID {
                    segments[index].speakerName = cleaned
                }
                cachedSegments[segment.meetingID] = segments
            }
            if selectedMeetingID == segment.meetingID {
                for index in state.transcript.indices
                where cachedSegments[segment.meetingID]?.contains(where: {
                    $0.id == state.transcript[index].segmentID && $0.speakerID == speakerID
                }) == true {
                    state.transcript[index].speaker = cleaned
                }
            }
            return true
        } catch {
            state.report(.speakerRename, error.localizedDescription)
            return false
        }
    }

    func beginSummaryEditing(meetingID: UUID) {
        state.updateInsights(for: meetingID) {
            $0.summaryDraft = $0.summary
            $0.isEditingSummary = true
            $0.error = nil
        }
    }

    func cancelSummaryEditing(meetingID: UUID) {
        let workspace = state.insights(for: meetingID)
        if workspace.hasUnsavedSummaryChanges {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Discard summary changes?"
            alert.informativeText = "Your unsaved summary edits will be lost."
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        discardSummaryChanges(meetingID: meetingID)
    }

    private func discardSummaryChanges(meetingID: UUID) {
        state.updateInsights(for: meetingID) {
            $0.summaryDraft = $0.summary
            $0.isEditingSummary = false
            $0.isSavingSummary = false
        }
    }

    func saveSummary(meetingID: UUID) async -> Bool {
        let workspace = state.insights(for: meetingID)
        let text = workspace.summaryDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text != workspace.summary else {
            discardSummaryChanges(meetingID: meetingID)
            return true
        }
        state.updateInsights(for: meetingID) { $0.isSavingSummary = true; $0.error = nil }
        do {
            let cachedActive = workspace.summaryVersions.first {
                $0.id == workspace.activeSummaryVersionID
            }
            let active: SummaryVersion?
            if let cachedActive {
                active = cachedActive
            } else {
                active = try await store.activeSummaryVersion(meetingID: meetingID)
            }
            let version = try await store.createSummaryVersion(
                meetingID: meetingID,
                kind: .manual,
                text: text,
                sourceInsightSnapshotID: active?.sourceInsightSnapshotID,
                activate: true
            )
            state.updateInsights(for: meetingID) {
                $0.summary = version.text
                $0.summaryDraft = version.text
                $0.activeSummaryVersionID = version.id
                $0.summaryVersions.removeAll { $0.id == version.id }
                $0.summaryVersions.insert(version, at: 0)
                $0.isEditingSummary = false
                $0.isSavingSummary = false
                $0.summarySaveConfirmation = Date()
            }
            return true
        } catch {
            state.updateInsights(for: meetingID) {
                $0.isSavingSummary = false
            }
            state.report(.summarySave, error.localizedDescription)
            return false
        }
    }

    func activateSummaryVersion(_ version: SummaryVersion, meetingID: UUID) async {
        guard await resolveUnsavedSummaryChanges(meetingID: meetingID) else { return }
        do {
            try await store.activateSummaryVersion(id: version.id, meetingID: meetingID)
            await applySummaryVersion(version, meetingID: meetingID)
            state.updateInsights(for: meetingID) { $0.candidateSummaryVersionID = nil }
        } catch {
            state.updateInsights(for: meetingID) { $0.error = error.localizedDescription }
        }
    }

    func keepCurrentSummary(meetingID: UUID) {
        state.updateInsights(for: meetingID) { $0.candidateSummaryVersionID = nil }
    }

    func loadMoreSummaryVersions(meetingID: UUID) async {
        let workspace = state.insights(for: meetingID)
        guard workspace.hasMoreSummaryVersions,
              !workspace.isLoadingSummaryVersions,
              let oldest = workspace.summaryVersions.last else { return }
        state.updateInsights(for: meetingID) { $0.isLoadingSummaryVersions = true }
        do {
            let page = try await store.summaryVersions(
                meetingID: meetingID,
                limit: 50,
                before: oldest.createdAt
            )
            state.updateInsights(for: meetingID) {
                let known = Set($0.summaryVersions.map(\.id))
                $0.summaryVersions.append(contentsOf: page.filter { !known.contains($0.id) })
                $0.hasMoreSummaryVersions = page.count == 50
                $0.isLoadingSummaryVersions = false
            }
        } catch {
            state.updateInsights(for: meetingID) { $0.isLoadingSummaryVersions = false }
            state.report(.meetingLoad, error.localizedDescription)
        }
    }

    func copySummary(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private enum UnsavedSummaryDecision {
        case save
        case discard
        case cancel
    }

    private func unsavedSummaryDecision() -> UnsavedSummaryDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save summary changes?"
        alert.informativeText = "You have unsaved edits in the meeting summary."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func resolveUnsavedSummaryChanges(meetingID: UUID) async -> Bool {
        guard state.insights(for: meetingID).hasUnsavedSummaryChanges else { return true }
        switch unsavedSummaryDecision() {
        case .save:
            return await saveSummary(meetingID: meetingID)
        case .discard:
            discardSummaryChanges(meetingID: meetingID)
            return true
        case .cancel:
            return false
        }
    }

    private func resolveUnsavedSummaryChangesForNavigation(
        meetingID: UUID,
        proceed: @escaping @MainActor () -> Void
    ) {
        switch unsavedSummaryDecision() {
        case .save:
            Task { [weak self] in
                guard let self, await self.saveSummary(meetingID: meetingID) else { return }
                proceed()
            }
        case .discard:
            discardSummaryChanges(meetingID: meetingID)
            proceed()
        case .cancel:
            break
        }
    }

    private func applySummaryVersion(_ version: SummaryVersion, meetingID: UUID) async {
        if let snapshotID = version.sourceInsightSnapshotID,
           let snapshot = try? await store.insightSnapshot(id: snapshotID) {
            applyInsights(snapshot.output.insights, meetingID: meetingID)
        } else {
            state.updateInsights(for: meetingID) {
                $0.topics = []
                $0.decisions = []
                $0.actions = []
                $0.openQuestions = []
            }
        }
        state.updateInsights(for: meetingID) {
            $0.summary = version.text
            $0.summaryDraft = version.text
            $0.activeSummaryVersionID = version.id
            $0.isEditingSummary = false
            $0.error = nil
        }
    }

    // MARK: - Meeting lifecycle

    func softDeleteMeeting(_ id: UUID) async {
        guard state.activeMeetingID != id else { return }
        guard await resolveUnsavedSummaryChanges(meetingID: id) else { return }
        insightTasks[id]?.cancel()
        audioExportTasks[id]?.cancel()
        do {
            try await store.softDeleteMeeting(id: id)
            guard let index = state.meetings.firstIndex(where: { $0.id == id }) else { return }
            let item = state.meetings.remove(at: index)
            state.recentlyDeletedMeetings.insert(item, at: 0)
            if state.selection == .meeting(id) { setSelection(.meetings) }
        } catch {
            state.report(.meetingDelete, error.localizedDescription)
        }
    }

    func restoreMeeting(_ id: UUID) async {
        do {
            try await store.restoreMeeting(id: id)
            guard let meeting = try await store.meeting(id: id) else { return }
            state.recentlyDeletedMeetings.removeAll { $0.id == id }
            state.meetings.insert(Self.listItem(meeting), at: 0)
        } catch {
            state.report(.meetingDelete, error.localizedDescription)
        }
    }

    func confirmPermanentDelete(meetingID: UUID) {
        guard state.activeMeetingID != meetingID else { return }
        let title = state.recentlyDeletedMeetings.first(where: { $0.id == meetingID })?.title ?? "this meeting"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(title)” permanently?"
        alert.informativeText = "Its transcript, summaries, notes, and retained recording will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await permanentlyDeleteMeeting(meetingID) }
    }

    private func permanentlyDeleteMeeting(_ id: UUID) async {
        insightTasks[id]?.cancel()
        audioExportTasks[id]?.cancel()
        do {
            try await store.deleteMeeting(id: id, deleteAudioFiles: true)
            state.recentlyDeletedMeetings.removeAll { $0.id == id }
            cachedSegments[id] = nil
            state.meetingNotes[id] = nil
            state.meetingWorkspaceTabs[id] = nil
        } catch {
            state.report(.meetingDelete, error.localizedDescription)
        }
    }

    func recoverMeeting(_ id: UUID) async {
        defer {
            Task { @MainActor [weak self] in
                await self?.applyQueuedModelStorageChangeIfPossible()
            }
        }
        state.activeMeetingID = id
        state.markFinalizing(stage: .savingAudio, progress: 0.05, detail: "Checking saved audio…")
        do {
            try await registerRecoveryAudio(for: id)
            let tracks = try await store.audioTracks(meetingID: id)
            guard !tracks.isEmpty else {
                throw CoordinatorError.providerUnavailable("No recoverable audio was found for this meeting.")
            }
            try await store.updateMeetingStatus(id: id, status: .finalizing)

            let finalizer = WhisperKitFinalTranscriber(
                downloadBase: modelStoragePaths.whisperDownloadBase
            )
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
                    // The same engine as finalization, and for the same reason:
                    // both ask for the default configuration, which is the one
                    // whose 21 MB of Core ML models the engine memoizes.
                    let diarizer = diarizationEngine ?? FluidAudioDiarizationEngine(
                        modelsDirectory: modelStoragePaths.diarizationModelsDirectory
                    )
                    diarizationEngine = diarizer
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
            if MeetingAudioRetentionPolicy.shouldDeleteAfterFinalization(
                meetingRetainsAudio: meeting.retainsAudio
            ) {
                try await store.deleteAudioFiles(meetingID: id)
            }
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
            // The segments carry the matched line, who said it, and when. All
            // of that used to be reduced to a set of meeting identifiers and
            // thrown away one line later, which is why search could say a
            // meeting matched but never which moment in it did.
            let results = MeetingSearchResultBuilder.results(
                segmentMatches: matches,
                meetings: state.meetings,
                titleMatches: state.meetingsMatchingTitle(cleaned)
            )
            state.applySearchMatches(
                Set(matches.map(\.meetingID)),
                results: results,
                for: cleaned
            )
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
        let generation = UUID()
        insightTasks[meetingID]?.cancel()
        insightGenerations[meetingID] = generation
        state.updateInsights(for: meetingID) {
            $0.isGenerating = true
            $0.generationStage = .checkingProvider
            $0.generationProgress = InsightGenerationStage.checkingProvider.progress
            $0.generationStartedAt = Date()
            $0.error = nil
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performInsightGeneration(meetingID: meetingID, generation: generation)
        }
        insightTasks[meetingID] = task
        await task.value
    }

    func cancelInsightGeneration(meetingID: UUID) {
        insightTasks[meetingID]?.cancel()
    }

    private func performInsightGeneration(meetingID: UUID, generation: UUID) async {
        defer {
            if insightGenerations[meetingID] == generation {
                insightTasks[meetingID] = nil
                insightGenerations[meetingID] = nil
                state.updateInsights(for: meetingID) {
                    $0.isGenerating = false
                    $0.generationStage = nil
                    $0.generationProgress = 0
                    $0.generationStartedAt = nil
                }
            }
        }
        do {
            let segments = try await transcriptSegments(for: meetingID)
            guard !segments.isEmpty else { throw CoordinatorError.noTranscript }
            let provider = try await selectedInsightProvider()
            let health = await provider.healthCheck()
            // CLI health checks are non-throwing by protocol and translate a
            // cancelled probe into "unavailable". Reassert task cancellation
            // before interpreting that result so Cancel stays a cancellation,
            // not a misleading provider error.
            try Task.checkCancellation()
            switch health {
            case .available: break
            case .unavailable(let reason):
                throw CoordinatorError.providerUnavailable(reason)
            }
            try Task.checkCancellation()
            let runID = try await store.beginProviderRun(
                meetingID: meetingID,
                providerID: provider.descriptor.id,
                purpose: "meeting-insights"
            )
            do {
                let output = try await InsightPipeline(provider: provider).generateInsights(
                    transcript: segments.map(InsightTranscriptSegment.init(transcriptSegment:)),
                    progress: { [weak self] progress in
                        await self?.applyInsightProgress(
                            progress,
                            meetingID: meetingID,
                            generation: generation
                        )
                    }
                )
                try Task.checkCancellation()
                updateInsightStage(.saving, meetingID: meetingID, generation: generation)
                let saved = try await store.saveGeneratedInsights(
                    meetingID: meetingID,
                    providerID: provider.descriptor.id,
                    output: output
                )
                try await store.finishProviderRun(id: runID, status: .succeeded)
                guard insightGenerations[meetingID] == generation else { return }
                applySavedGeneratedInsights(saved, output: output, meetingID: meetingID)
            } catch {
                try? await store.finishProviderRun(
                    id: runID,
                    status: .failed,
                    errorMessage: error is CancellationError ? "Cancelled by the user." : error.localizedDescription
                )
                throw error
            }
        } catch is CancellationError {
            guard insightGenerations[meetingID] == generation else { return }
            state.updateInsights(for: meetingID) { $0.error = nil }
        } catch {
            guard insightGenerations[meetingID] == generation else { return }
            state.updateInsights(for: meetingID) { $0.error = error.localizedDescription }
        }
    }

    private func applyInsightProgress(
        _ progress: InsightPipelineProgress,
        meetingID: UUID,
        generation: UUID
    ) {
        let stage: InsightGenerationStage? = switch progress {
        case .preparing: .checkingProvider
        case .extracting(let current, let total): .extracting(current: current, total: total)
        case .synthesizing: .synthesizing
        case .validating: .validating
        case .completed: nil
        }
        if let stage { updateInsightStage(stage, meetingID: meetingID, generation: generation) }
    }

    private func updateInsightStage(
        _ stage: InsightGenerationStage,
        meetingID: UUID,
        generation: UUID
    ) {
        guard insightGenerations[meetingID] == generation else { return }
        state.updateInsights(for: meetingID) {
            $0.generationStage = stage
            $0.generationProgress = stage.progress
        }
    }

    func answerQuestion() async {
        guard let meetingID = selectedMeetingID else { return }
        let question = state.insights.question
        state.updateInsights(for: meetingID) { $0.error = nil }
        // Without this the Ask button produced no visual change at all for the
        // length of an LLM round trip.
        state.updateInsights(for: meetingID) { $0.isGenerating = true }
        defer { state.updateInsights(for: meetingID) { $0.isGenerating = false } }
        do {
            let segments = try await transcriptSegments(for: meetingID)
            let provider = try await selectedInsightProvider()
            let output = try await InsightPipeline(provider: provider).answer(
                question: question,
                transcript: segments.map(InsightTranscriptSegment.init(transcriptSegment:))
            )
            state.updateInsights(for: meetingID) {
                $0.answer = output.answer.answer
                $0.answerCitations = output.answer.citations
                $0.rejectedCitations = output.validation.rejectedCitations
            }
        } catch {
            state.updateInsights(for: meetingID) { $0.error = error.localizedDescription }
        }
    }

    /// What the models screen knows about each model, keyed by model id.
    private(set) var modelAvailability: [String: ModelAvailability] = [:]

    var modelStorageDisplayPath: String {
        modelStoragePaths.managedDirectory?.path ?? "Default system locations"
    }

    var canChangeModelStorage: Bool {
        ModelStorageChangePolicy.canApply(
            recordingIsBusy: state.recordingPhase.isBusy,
            activeDownloadCount: downloadTasks.count,
            isMigrating: isChangingModelStorage
        )
    }

    func refreshInstalledModels() {
        let installed = InstalledSpeechModelDiscovery.installedModels(at: modelStoragePaths)
        installedModelFolders = installed
        for model in SpeechModelCatalog.all {
            if modelAvailability[model.id]?.isDownloading == true { continue }
            modelAvailability[model.id] = installed[model.id] == nil ? .notInstalled : .ready
        }
    }

    func refreshInstalledModelSizes() async {
        let request = StorageScanRequest(models: SpeechModelCatalog.all.compactMap { model in
            installedModelFolders[model.id].map {
                ModelStorageScanLocation(modelID: model.id, displayName: model.displayName, url: $0)
            }
        })
        do {
            let report = try await StorageAccountingService().report(for: request)
            installedModelAllocatedBytes = Dictionary(
                uniqueKeysWithValues: report.modelDetails.map { ($0.modelID, $0.allocatedBytes) }
            )
        } catch is CancellationError {
            return
        } catch {
            logger.info("Model storage size scan skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func installedModelSizeText(_ model: SpeechModel) -> String? {
        installedModelAllocatedBytes[model.id].map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    func chooseModelStorageDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for Hushnote models"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = modelStoragePaths.parentDirectory
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        promptForModelStorageChange(to: ModelStoragePaths(parentDirectory: parent))
    }

    func resetModelStorageDirectory() {
        promptForModelStorageChange(to: ModelStoragePaths())
    }

    private func promptForModelStorageChange(to destination: ModelStoragePaths) {
        guard destination != modelStoragePaths else { return }
        let alert = NSAlert()
        alert.messageText = "Change model storage location?"
        alert.informativeText = "Hushnote can copy complete speech and speaker models to the new location, or start using it without copying. Existing files are never deleted automatically."
        alert.addButton(withTitle: "Copy Models")
        alert.addButton(withTitle: "Use Without Copying")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let migrate = response == .alertFirstButtonReturn
        requestModelStorageChange(destination, migrate: migrate)
    }

    private func requestModelStorageChange(_ destination: ModelStoragePaths, migrate: Bool) {
        guard canChangeModelStorage else {
            queuedModelStorageChange = (destination, migrate)
            queuedModelStoragePath = destination.parentDirectory?.path ?? "Default system locations"
            modelStorageStatus = "The storage change is queued until recording and downloads finish."
            return
        }
        Task { await applyModelStorageChange(destination, migrate: migrate) }
    }

    private func applyQueuedModelStorageChangeIfPossible() async {
        guard canChangeModelStorage, let queued = queuedModelStorageChange else { return }
        queuedModelStorageChange = nil
        queuedModelStoragePath = nil
        await applyModelStorageChange(queued.destination, migrate: queued.migrate)
    }

    private func applyModelStorageChange(_ destination: ModelStoragePaths, migrate: Bool) async {
        guard destination != modelStoragePaths, !isChangingModelStorage else { return }
        isChangingModelStorage = true
        defer {
            isChangingModelStorage = false
            Task { @MainActor [weak self] in
                await self?.applyQueuedModelStorageChangeIfPossible()
            }
        }
        do {
            try await ModelStorageOperations().prepare(destination)
            if migrate {
                modelStorageStatus = "Copying models…"
                _ = try await ModelStorageOperations().migrate(
                    from: modelStoragePaths,
                    to: destination,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in self?.modelStorageMigrationProgress = progress }
                    }
                )
            }
            modelStorageMigrationProgress = nil
            modelStoragePaths = destination
            preferences.modelStorageParentPath = destination.parentDirectory?.path
            speechEngine = nil
            loadedModel = nil
            diarizationEngine = nil
            refreshInstalledModels()
            await refreshInstalledModelSizes()
            modelStorageStatus = migrate
                ? "Models were copied and the new location is active."
                : "The new model location is active."
            if state.selection == .storage { await refreshStorageReport() }
        } catch {
            modelStorageMigrationProgress = nil
            modelStorageStatus = nil
            state.report(.storage, error.localizedDescription)
        }
    }

    func revealModelStorage() {
        let target = modelStoragePaths.managedDirectory
            ?? modelStoragePaths.effectiveWhisperDownloadBase
        if modelStoragePaths.managedDirectory != nil {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func promptToRemoveModel(_ model: SpeechModel) {
        guard model.id != SpeechModelResolver.model(named: state.draft.liveModel).id,
              model.id != SpeechModelResolver.model(named: state.draft.finalModel).id else {
            state.report(.storage, "Choose a different default model before removing this one.")
            return
        }
        guard canChangeModelStorage else {
            state.report(.storage, "Wait for recording, downloads, or model copying to finish.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(model.displayName)?"
        alert.informativeText = "This removes only this model from the active location. You can download it again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await ModelStorageOperations().removeSpeechModel(model, from: modelStoragePaths)
                refreshInstalledModels()
                await refreshInstalledModelSizes()
                if state.selection == .storage { await refreshStorageReport() }
            } catch {
                state.report(.storage, error.localizedDescription)
            }
        }
    }

    func promptToRemoveDiarizationModels() {
        guard canChangeModelStorage else {
            state.report(.storage, "Wait for recording, downloads, or model copying to finish.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove speaker model?"
        alert.informativeText = "Speaker labels will be unavailable until Hushnote downloads the diarization model again. Other FluidAudio caches are not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await ModelStorageOperations().removeDiarizationModels(from: modelStoragePaths)
                diarizationEngine = nil
                modelStorageStatus = "The speaker model was removed."
                if state.selection == .storage { await refreshStorageReport() }
            } catch {
                state.report(.storage, error.localizedDescription)
            }
        }
    }

    func downloadModel(_ model: SpeechModel) async {
        guard ModelListPolicy.canDownload(
            availability: modelAvailability[model.id] ?? .notInstalled,
            phase: state.recordingPhase
        ) else { return }
        modelAvailability[model.id] = .downloading(.starting)

        // The work runs in a task the coordinator owns so the row's Cancel
        // button has something to cancel. HubApi wraps its transfer in
        // `withTaskCancellationHandler`, so cancelling this stops the fetch
        // rather than merely abandoning it.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(model)
        }
        downloadTasks[model.id] = task
        await task.value
        downloadTasks[model.id] = nil
        refreshInstalledModels()
        await refreshInstalledModelSizes()
        if state.selection == .storage { await refreshStorageReport() }
        await applyQueuedModelStorageChangeIfPossible()
    }

    /// Stops a download in flight. Not gated on the recording phase: a transfer
    /// started before Record is still saturating the same link during the
    /// meeting, so stopping it is precisely what a busy machine needs to allow.
    func cancelDownload(_ model: SpeechModel) {
        guard let task = downloadTasks.removeValue(forKey: model.id) else { return }
        downloadGeneration += 1
        task.cancel()
        modelAvailability[model.id] = .notInstalled
    }

    /// Turns the live pass on or off and remembers the answer.
    ///
    /// Takes effect from the next meeting: a capture already running has either
    /// loaded a model or not, and swapping that out underneath it would be a
    /// worse surprise than the setting not applying until Stop.
    func setLiveTranscriptionEnabled(_ isEnabled: Bool) {
        state.liveTranscriptionEnabled = isEnabled
        SpeechModelDefaults.store(liveTranscriptionEnabled: isEnabled, in: defaults)
    }

    func setRetainAudio(_ retainsAudio: Bool) {
        state.retainAudio = retainsAudio
        preferences.retainAudio = retainsAudio
    }

    func setSelectedProvider(_ provider: InsightProviderChoice) {
        state.selectedProvider = provider
        preferences.selectedProvider = provider
    }

    func setLocalLlamaExecutablePath(_ path: String) {
        localLlamaExecutablePath = path
        preferences.llamaExecutablePath = path
    }

    func setLocalModelPath(_ path: String) {
        localModelPath = path
        preferences.localModelPath = path
    }

    /// Brings one segment of the meeting already on screen into view, and
    /// switches to the transcript to show it.
    func revealTranscriptSegment(_ segmentID: String) {
        if let meetingID = selectedMeetingID {
            setWorkspaceTab(.transcript, for: meetingID)
        }
        state.transcriptJumpRequest = TranscriptJumpRequest(segmentID: segmentID)
    }

    /// Opens a meeting at one transcript moment.
    ///
    /// This does write through to the meeting's remembered tab, which is
    /// deliberate: the user asked for something said out loud, so the
    /// transcript is the tab they want next time too.
    func openMeetingMoment(meetingID: UUID, segmentID: String) {
        setSelection(.meeting(meetingID))
        setWorkspaceTab(.transcript, for: meetingID)
        state.transcriptJumpRequest = TranscriptJumpRequest(segmentID: segmentID)
    }

    func setSelection(_ destination: SidebarDestination?) {
        if case .meeting(let currentID) = state.selection,
           state.selection != destination,
           state.insights(for: currentID).hasUnsavedSummaryChanges {
            resolveUnsavedSummaryChangesForNavigation(meetingID: currentID) { [weak self] in
                self?.applySelection(destination)
            }
            return
        }
        applySelection(destination)
    }

    private func applySelection(_ destination: SidebarDestination?) {
        state.selection = destination
        preferences.sidebarDestination = destination
    }

    func setWorkspaceTab(_ tab: WorkspaceTab, for meetingID: UUID) {
        if state.workspaceTab(for: meetingID) == .summary,
           tab != .summary,
           state.insights(for: meetingID).hasUnsavedSummaryChanges {
            resolveUnsavedSummaryChangesForNavigation(meetingID: meetingID) { [weak self] in
                self?.applyWorkspaceTab(tab, for: meetingID)
            }
            return
        }
        applyWorkspaceTab(tab, for: meetingID)
    }

    private func applyWorkspaceTab(_ tab: WorkspaceTab, for meetingID: UUID) {
        state.setWorkspaceTab(tab, for: meetingID)
        preferences.meetingTabs = state.meetingWorkspaceTabs
    }

    func refreshStorageReport() async {
        let generation = UUID()
        storageScanGeneration = generation
        state.isScanningStorage = true
        defer {
            if storageScanGeneration == generation { state.isScanningStorage = false }
        }
        do {
            let request = try await storageScanRequest()
            let report = try await storageAccounting.report(for: request)
            guard storageScanGeneration == generation else { return }
            state.storageReport = report
        } catch is CancellationError {
            return
        } catch {
            guard storageScanGeneration == generation else { return }
            state.report(.storage, error.localizedDescription)
        }
    }

    func canRemoveRecordingAudio(meetingID: UUID) -> Bool {
        guard let meeting = (state.meetings + state.recentlyDeletedMeetings)
            .first(where: { $0.id == meetingID }) else { return false }
        return RecordingStorageCleanupPolicy.canRemove(
            meetingID: meetingID,
            status: meeting.status,
            activeMeetingID: state.activeMeetingID,
            recordingPhase: state.recordingPhase
        )
    }

    /// Removes only retained audio. Notes, transcript, summaries and the
    /// meeting row remain available; interrupted recordings are refused above.
    func removeRecordingAudio(meetingID: UUID) async {
        guard canRemoveRecordingAudio(meetingID: meetingID) else { return }
        state.storageDeletingRecordingIDs.insert(meetingID)
        defer { state.storageDeletingRecordingIDs.remove(meetingID) }
        do {
            try await store.deleteAudioFiles(meetingID: meetingID)
            if var meeting = try await store.meeting(id: meetingID) {
                meeting.retainsAudio = false
                meeting.updatedAt = Date()
                try await store.saveMeeting(meeting)
            }
            if let index = state.meetings.firstIndex(where: { $0.id == meetingID }) {
                state.meetings[index].retainsAudio = false
            }
            if let index = state.recentlyDeletedMeetings.firstIndex(where: { $0.id == meetingID }) {
                state.recentlyDeletedMeetings[index].retainsAudio = false
            }
            await refreshStorageReport()
        } catch {
            state.report(.storage, error.localizedDescription)
        }
    }

    private func storageScanRequest() async throws -> StorageScanRequest {
        let paths = modelStoragePaths
        let installed = await Task.detached(priority: .utility) {
            InstalledSpeechModelDiscovery.installedModels(at: paths)
        }.value
        var modelLocations = installed.compactMap { modelID, url -> ModelStorageScanLocation? in
            guard let model = SpeechModelCatalog.model(id: modelID) else { return nil }
            return .init(modelID: modelID, displayName: model.displayName, url: url)
        }

        // Keep a cache remainder row after known model folders claim their own
        // files. It accounts for partial or obsolete downloads without counting
        // them twice.
        let whisperRepository = paths.effectiveWhisperDownloadBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: whisperRepository.path) {
            modelLocations.append(.init(
                modelID: "whisperkit-cache",
                displayName: "WhisperKit cache remainder",
                url: whisperRepository
            ))
        }
        if let diarization = ModelStorageOperations.installedDiarizationFolder(
            at: paths,
            fileManager: .default
        ) {
            modelLocations.append(.init(
                modelID: "speaker-diarization",
                displayName: "Speaker identification",
                url: diarization
            ))
        }
        if !localModelPath.isEmpty {
            let localGGUF = URL(fileURLWithPath: localModelPath)
            if FileManager.default.fileExists(atPath: localGGUF.path) {
                modelLocations.append(.init(
                    modelID: "local-gguf",
                    displayName: "Local insights model",
                    url: localGGUF
                ))
            }
        }

        let currentMeetings = try await store.meetings()
        let deletedMeetings = try await store.recentlyDeleted()
        var recordings: [RecordingStorageLocation] = []
        for meeting in currentMeetings + deletedMeetings {
            let tracks = try await store.audioTracks(meetingID: meeting.id)
            guard let track = tracks.first else { continue }
            let expected = recoveryAudioDirectory(for: meeting.id)
            let directory = track.fileURL.path.hasPrefix(expected.path + "/")
                ? expected
                : track.fileURL.deletingLastPathComponent()
            recordings.append(.init(meetingID: meeting.id, title: meeting.title, url: directory))
        }

        return StorageScanRequest(
            models: modelLocations,
            recordings: recordings,
            databaseURLs: [applicationDataURL.appending(path: "hushnote.sqlite")],
            applicationDataURL: applicationDataURL
        )
    }

    func audioAvailable(meetingID: UUID) -> Bool {
        MeetingAudioExport.source(in: recoveryAudioDirectory(for: meetingID)) != nil
    }

    /// Makes a model the one meetings use, and gets it here if it is not.
    ///
    /// Choosing is what downloading means on this screen: the selection is
    /// recorded and persisted first, so a download that fails leaves a row the
    /// user can retry rather than a choice that silently did not take.
    func setDefaultModel(_ model: SpeechModel) async {
        state.draft.liveModel = model.id
        state.draft.finalModel = model.id
        SpeechModelDefaults.store(liveModelID: model.id, finalModelID: model.id, in: defaults)
        guard modelAvailability[model.id] != .ready else { return }
        await downloadModel(model)
    }

    /// The download itself, its progress reporting and its cancellation live in
    /// `ModelDownloadRunner`, which is testable without opening the database
    /// this class opens in its initialiser. What is left here is the part that
    /// only the coordinator can do: writing the row's state where the screen
    /// reads it, and keeping the loaded engine.
    private func runDownload(_ model: SpeechModel) async {
        let generation = downloadGeneration
        await ModelDownloadRunner(downloader: downloader).run(
            model: model,
            downloadBase: modelStoragePaths.whisperDownloadBase,
            install: { [weak self] folder in
                guard let self else { throw CancellationError() }
                try await self.installDownloadedModel(model, from: folder)
            },
            report: { [weak self] availability in
                Task { @MainActor [weak self] in
                    self?.applyDownloadState(availability, to: model.id, generation: generation)
                }
            }
        )
    }

    private func installDownloadedModel(_ model: SpeechModel, from folder: URL) async throws {
        let engine = speechEngine ?? WhisperKitTranscriptionEngine()
        try await engine.load(model: model, modelFolder: folder)
        speechEngine = engine
        loadedModel = model
    }

    /// Bumped whenever a download is cancelled, so a chunk callback still in
    /// flight cannot put a progress bar back on a row the user just cleared.
    @ObservationIgnored private var downloadGeneration = 0

    private func applyDownloadState(
        _ availability: ModelAvailability,
        to modelID: String,
        generation: Int
    ) {
        guard generation == downloadGeneration else { return }
        modelAvailability[modelID] = availability
        if case .failed(let reason) = availability {
            state.markFailed(.init(kind: .modelDownload, message: "Model download failed: \(reason)"))
        }
    }

    func export(meetingID: UUID, format: TranscriptExportFormat) {
        guard let meeting = state.meetings.first(where: { $0.id == meetingID }) else { return }
        let transcript = cachedSegments[meetingID] ?? []
        do {
            try MeetingExporter.export(
                meeting: meeting,
                transcript: transcript,
                insights: state.insights(for: meetingID),
                format: format
            )
        } catch {
            state.report(.export, error.localizedDescription)
        }
    }

    /// Copies the meeting's own recording out. The menu already decided this
    /// meeting should keep audio, but that decision is made from the loaded
    /// model and the file can be gone anyway -- deleted by a finalization that
    /// finished while this meeting sat on screen. Say so rather than opening a
    /// save panel that would produce nothing.
    func exportAudio(
        meetingID: UUID,
        format: MeetingAudioFileFormat = .m4a
    ) {
        guard let meeting = state.meetings.first(where: { $0.id == meetingID }) else { return }
        guard let source = MeetingAudioExport.source(in: recoveryAudioDirectory(for: meetingID)) else {
            state.report(.export, MeetingAudioExport.missingAudioMessage)
            return
        }
        guard let destination = MeetingExporter.audioDestination(meeting: meeting, format: format) else { return }
        audioExportTasks[meetingID]?.cancel()
        let generation = UUID()
        audioExportGenerations[meetingID] = generation
        let task = Task { [weak self] in
            guard let self else { return }
            guard self.audioExportGenerations[meetingID] == generation else { return }
            self.state.audioExports[meetingID] = .exporting(format: format, progress: 0)
            do {
                try await self.meetingAudioExporter.export(
                    source: source,
                    destination: destination,
                    format: format,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self,
                                  self.audioExportGenerations[meetingID] == generation else { return }
                            self.state.audioExports[meetingID] = .exporting(
                                format: format,
                                progress: progress
                            )
                        }
                    }
                )
                guard self.audioExportGenerations[meetingID] == generation else { return }
                self.state.audioExports[meetingID] = .succeeded(destination)
            } catch is CancellationError {
                guard self.audioExportGenerations[meetingID] == generation else { return }
                self.state.audioExports[meetingID] = .idle
            } catch {
                guard self.audioExportGenerations[meetingID] == generation else { return }
                self.state.audioExports[meetingID] = .failed(error.localizedDescription)
                self.state.report(.export, error.localizedDescription)
            }
            guard self.audioExportGenerations[meetingID] == generation else { return }
            self.audioExportTasks[meetingID] = nil
            self.audioExportGenerations[meetingID] = nil
        }
        audioExportTasks[meetingID] = task
    }

    func cancelAudioExport(meetingID: UUID) {
        audioExportTasks[meetingID]?.cancel()
    }

    /// Whether a key is already in the Keychain, so the field can say so.
    func hasStoredCredential(for provider: InsightProviderChoice) async -> Bool {
        guard let key = Self.credentialKey(for: provider) else { return false }
        // `try?` flattens the optional the store returns, so this is one test
        // for both "the Keychain refused" and "there is nothing stored".
        return (try? await credentials.credential(for: key)) != nil
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
        guard let provider = try? await selectedInsightProvider() else {
            return .failed("The provider could not be prepared. Check Settings.")
        }
        guard case .available = await provider.healthCheck() else {
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

    private func observeAudioEvents(
        _ pipeline: AudioPipeline,
        meetingID: UUID,
        generation: UUID
    ) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in pipeline.events {
                guard let self else { return }
                switch event {
                case .level(let level):
                    let value = min(1, max(0, Double(level.rms) * 8))
                    self.state.systemLevel = value
                case .chunk(let chunk):
                    self.recordingDidReceiveFirstBuffer(
                        meetingID: meetingID,
                        generation: generation
                    )
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

    /// The chunk is emitted only after its matching frames are in the CAF, so
    /// this is the first point where "Recording" is a durable statement.
    private func recordingDidReceiveFirstBuffer(meetingID: UUID, generation: UUID) {
        guard liveSessionGeneration == generation,
              state.recordingPhase == .preparing,
              state.activeMeetingID == meetingID else { return }
        state.markRecordingStarted(meetingID: meetingID)
        if state.liveTranscriptionEnabled {
            startLiveTranscription(meetingID: meetingID, generation: generation)
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
                    let pending = self.liveWrites.unwritten(in: snapshot)
                    guard !pending.isEmpty else { continue }
                    do {
                        try await self.store.upsertSegments(pending)
                        // Stopping resets the ledger while this write is in
                        // flight, and the final pass then replaces these rows
                        // under new identifiers. A late confirmation must not
                        // re-seed the ledger with a transcript that is gone.
                        guard self.liveSessionGeneration == generation else { return }
                        // Only a write the store accepted is recorded, so a
                        // failed transaction is retried by the next delta rather
                        // than dropped for the rest of the meeting.
                        self.liveWrites.confirm(pending)
                    } catch {
                        self.logger.error("""
                            Live transcript write failed for \(pending.count, privacy: .public) \
                            segments: \(error.localizedDescription, privacy: .public)
                            """)
                    }
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
        case .claudeCLI, .codexCLI, .opencodeCLI:
            guard let tool = state.selectedProvider.agentCLITool else {
                throw CoordinatorError.providerUnavailable("Choose a provider in Settings.")
            }
            return AgentCLIProvider(
                tool: tool,
                model: AgentCLIModelDefaults.model(for: tool, from: defaults)
            )
        }
    }

    /// The model this CLI is asked for, as it should appear in the field.
    /// Empty means nothing was chosen and the CLI's own default is used.
    func agentCLIModel(for tool: AgentCLITool) -> String {
        AgentCLIModelDefaults.model(for: tool, from: defaults) ?? ""
    }

    /// Remembers which model a CLI should run. Kept per tool, because the
    /// three do not share a namespace of model names.
    func setAgentCLIModel(_ raw: String, for tool: AgentCLITool) {
        AgentCLIModelDefaults.store(raw, for: tool, in: defaults)
    }

    /// The models this CLI says it takes, for Settings to offer alongside the
    /// field. An empty answer is ordinary -- codex names none, and a tool that
    /// is missing or signed out names none either -- and means the field is
    /// the whole control.
    func agentCLIModels(_ tool: AgentCLITool) async -> [String] {
        await AgentCLIProvider(tool: tool).availableModels()
    }

    /// Why a CLI provider cannot be used yet, or nil when it can.
    ///
    /// Asked in Settings rather than discovered halfway through a summary: the
    /// tool may not be installed, may be signed out, or may have been updated
    /// past the flags Hushnote uses to switch its tools off.
    func agentCLIUnavailability(_ tool: AgentCLITool) async -> String? {
        guard case .unavailable(let reason) = await AgentCLIProvider(tool: tool).healthCheck()
        else { return nil }
        return reason
    }

    private func transcriptSegments(for id: UUID) async throws -> [TranscriptSegment] {
        if let cached = cachedSegments[id], !cached.isEmpty { return cached }
        let result = try await store.segments(meetingID: id)
        cachedSegments[id] = result
        return result
    }

    private func refreshFolderState() async throws {
        let folders = try await store.meetingFolders()
        let counts = try await store.meetingFolderCounts(folderIDs: Set(folders.map(\.id)))
        state.folders = folders
        state.folderMeetingCounts = Dictionary(
            uniqueKeysWithValues: counts.map { ($0.folderID, $0.meetingCount) }
        )
        state.unfiledMeetingCount = try await store.unfiledMeetingCount()
    }

    private func replaceMeetingListItem(_ meeting: Meeting) {
        let item = Self.listItem(meeting)
        if let index = state.meetings.firstIndex(where: { $0.id == meeting.id }) {
            // Moving a meeting must not discard the loaded transcript excerpt.
            var replacement = item
            replacement.excerpt = state.meetings[index].excerpt
            state.meetings[index] = replacement
        }
        if let index = state.recentlyDeletedMeetings.firstIndex(where: { $0.id == meeting.id }) {
            var replacement = item
            replacement.excerpt = state.recentlyDeletedMeetings[index].excerpt
            state.recentlyDeletedMeetings[index] = replacement
        }
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
            status: meeting.status,
            retainsAudio: meeting.retainsAudio,
            folderID: meeting.folderID
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
            status: meeting.status,
            retainsAudio: meeting.retainsAudio,
            folderID: meeting.folderID
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

    private func applyInsights(_ insights: MeetingInsights, meetingID: UUID) {
        state.updateInsights(for: meetingID) { workspace in
            workspace.summary = insights.overview.text
            workspace.topics = insights.topics.map(\.text)
            workspace.decisions = insights.decisions.map(\.text)
            workspace.actions = insights.actionItems.map { action in
                [action.text, action.owner.map { "Owner: \($0)" }, action.dueDate.map { "Due: \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            workspace.openQuestions = insights.openQuestions.map(\.text)
            workspace.error = nil
        }
    }

    private func applySavedGeneratedInsights(
        _ saved: SavedGeneratedInsights,
        output: ValidatedMeetingInsights,
        meetingID: UUID
    ) {
        state.updateInsights(for: meetingID) {
            $0.summaryVersions.removeAll { $0.id == saved.summaryVersion.id }
            $0.summaryVersions.insert(saved.summaryVersion, at: 0)
        }
        if saved.didActivate {
            applyInsights(output.insights, meetingID: meetingID)
            state.updateInsights(for: meetingID) {
                $0.summary = saved.summaryVersion.text
                $0.summaryDraft = saved.summaryVersion.text
                $0.activeSummaryVersionID = saved.summaryVersion.id
                $0.candidateSummaryVersionID = nil
            }
        } else {
            state.updateInsights(for: meetingID) {
                $0.candidateSummaryVersionID = saved.summaryVersion.id
            }
        }
    }

    /// Where a meeting's takes live, whether they are being recovered or
    /// exported.
    private func recoveryAudioDirectory(for meetingID: UUID) -> URL {
        applicationDataURL
            .appending(path: "RecoveryAudio", directoryHint: .isDirectory)
            .appending(path: meetingID.uuidString, directoryHint: .isDirectory)
    }

    private func registerRecoveryAudio(for meetingID: UUID) async throws {
        let directory = recoveryAudioDirectory(for: meetingID)
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
