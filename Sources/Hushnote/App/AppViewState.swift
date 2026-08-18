import Foundation
import Observation

enum SidebarDestination: Hashable {
    case meetings
    case models
    case settings
    case meeting(UUID)
}

enum MeetingTemplate: String, CaseIterable, Codable, Sendable, Identifiable {
    case general = "General"
    case oneOnOne = "1:1"
    case standup = "Standup"
    case interview = "Interview"
    case clientCall = "Client call"

    var id: Self { self }
}

/// What kind of thing went wrong, so the failure banner can offer a remedy that
/// exists. Almost nothing that calls `markFailed` is a recording problem.
enum RecordingFailureKind: Equatable, Sendable {
    /// System Audio Recording was refused. The only failure a Privacy pane fixes.
    case audioPermission
    /// Capture stopped for a meeting that can be started again.
    case capture
    /// The audio is on disk; the pass over it stopped.
    case finalization
    case modelDownload
    case credentialStorage
    case providerConnection
    case database
    /// A message with no claim attached about what caused it.
    case unknown

    /// Distinguishes the one capture failure a user can act on from the rest.
    nonisolated static func classifyCapture(_ error: Error) -> RecordingFailureKind {
        if let audio = error as? AudioPipelineError, audio == .permissionDenied {
            return .audioPermission
        }
        return .capture
    }
}

/// A remedy the failure banner can actually deliver.
///
/// Retrying carries the meeting it applies to, so "Try Again" with nothing to
/// retry is unrepresentable. The old banner passed a sidebar-derived optional
/// straight into `startMeeting`, where nil means "record a brand-new meeting".
enum FailureRemedy: Equatable, Sendable {
    case openPrivacySettings
    case retryRecording(UUID)
    case retryFinalization(UUID)
    case openModels
    case openSettings
}

/// A failure worth interrupting the window for, with enough structure to be
/// answered.
///
/// `ExpressibleByStringLiteral` is not only for source compatibility: a bare
/// message genuinely carries no claim about its cause, and is treated as
/// `.unknown` — offering no remedy rather than a misleading one.
struct RecordingFailure: Equatable, Sendable, ExpressibleByStringLiteral {
    var kind: RecordingFailureKind
    var message: String
    var meetingID: UUID?

    init(kind: RecordingFailureKind = .unknown, message: String, meetingID: UUID? = nil) {
        self.kind = kind
        self.message = message
        self.meetingID = meetingID
    }

    init(stringLiteral value: String) {
        self.init(message: value)
    }

    var remedies: [FailureRemedy] {
        switch kind {
        case .audioPermission:
            [.openPrivacySettings] + (meetingID.map { [.retryRecording($0)] } ?? [])
        case .capture:
            meetingID.map { [.retryRecording($0)] } ?? []
        case .finalization:
            meetingID.map { [.retryFinalization($0)] } ?? []
        case .modelDownload:
            [.openModels]
        case .credentialStorage, .providerConnection:
            [.openSettings]
        case .database, .unknown:
            []
        }
    }
}

enum RecordingPhase: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case finalizing(Double)
    case failed(RecordingFailure)

    var isCapturing: Bool {
        self == .recording || self == .paused
    }

    var isBusy: Bool {
        if case .preparing = self { return true }
        if case .finalizing = self { return true }
        return isCapturing
    }
}

/// A user-facing checkpoint in the post-recording pipeline. This lives beside
/// `RecordingPhase` so existing views that switch over `.finalizing(Double)`
/// remain source-compatible while still being able to show useful progress.
enum FinalizationStage: String, Equatable, Sendable {
    case savingAudio
    case stoppingLiveTranscription
    case loadingFinalModel
    case transcribing
    case diarizing
    case generatingInsights

    var title: String {
        switch self {
        case .savingAudio: "Saving audio…"
        case .stoppingLiveTranscription: "Stopping live transcription…"
        case .loadingFinalModel: "Loading final model…"
        case .transcribing: "Transcribing recording…"
        case .diarizing: "Identifying speakers…"
        case .generatingInsights: "Generating summary…"
        }
    }
}

struct MeetingDraft: Equatable {
    var title = ""
    var template = MeetingTemplate.general
    var liveModel = "large-v3-turbo"
    var finalModel = "large-v3"
    var language = "Automatic · multilingual"
    var agenda = ""
    var attendees = ""
    var vocabulary = ""
    var summaryInstructions = ""
}

/// Whether a meeting is transcribed while it happens, and what follows from
/// the answer.
///
/// Running a live pass means a second Whisper model resident on the same Neural
/// Engine the final pass will use, and a small model's guesses on screen while
/// people are still talking. Turning it off is not a single `if`: a progress
/// bar that reports "Stopping live transcription…" for work that never started
/// is a lie, and the live transcript is also the only thing standing under a
/// final pass that fails.
enum LiveTranscriptionPolicy {
    /// What the transcript pane says while it holds nothing.
    ///
    /// With the live pass off, "Listening for the conversation…" is a lie:
    /// nothing is listening for a transcript, and the text arrives in one pass
    /// when the meeting is finalized. The off copy deliberately implies no work
    /// in flight -- a spinner over work that is not happening is worse than no
    /// spinner at all -- so it carries its own symbol rather than the waveform,
    /// which reads as sound being taken in.
    struct EmptyTranscriptCopy: Equatable {
        let symbol: String
        let title: String
        let detail: String
    }

    nonisolated static func emptyTranscript(isEnabled: Bool) -> EmptyTranscriptCopy {
        isEnabled
            ? EmptyTranscriptCopy(
                symbol: "waveform",
                title: "Listening for the conversation…",
                detail: "The source tracks are already being written to disk."
            )
            : EmptyTranscriptCopy(
                symbol: "waveform.slash",
                title: "Live transcription is off",
                detail: "The audio is being written to disk. The transcript is produced in one pass after you press Stop."
            )
    }

    /// The stages a finalization actually goes through, in order.
    nonisolated static func stages(isEnabled: Bool) -> [FinalizationStage] {
        var stages: [FinalizationStage] = [.savingAudio]
        if isEnabled { stages.append(.stoppingLiveTranscription) }
        stages.append(contentsOf: [.loadingFinalModel, .transcribing, .diarizing, .generatingInsights])
        return stages
    }

    /// The stage reached once the audio file is closed. There is no live
    /// session to tear down when none was started.
    nonisolated static func stageAfterSavingAudio(isEnabled: Bool) -> FinalizationStage {
        isEnabled ? .stoppingLiveTranscription : .loadingFinalModel
    }

    /// What to do when the final pass fails.
    ///
    /// A live transcript in hand beats losing the meeting. With none -- because
    /// the live pass was off, or ran and produced nothing -- there is nothing
    /// to keep, and the failure has to surface so the user can retry
    /// finalization against audio that is still on disk.
    nonisolated static func fallback(liveSegmentCount: Int) -> FinalPassFallback {
        liveSegmentCount > 0 ? .keepLiveTranscript : .surfaceFailure
    }
}

enum FinalPassFallback: Equatable, Sendable {
    case keepLiveTranscript
    case surfaceFailure
}

/// Where the chosen speech models live between launches.
///
/// There was nowhere: `MeetingDraft` was rebuilt from its own literals on every
/// launch, so a model chosen on the models screen was forgotten the moment the
/// app quit. `UserDefaults` is what the app already keeps this class of
/// preference in — see `FloatingRecordingPanelController` — and the store is
/// injected for the same reason it is there, so a test never touches the real
/// domain.
enum SpeechModelDefaults {
    static let liveKey = "speechModel.live"
    static let finalKey = "speechModel.final"
    static let liveTranscriptionKey = "speechModel.liveTranscription"

    /// On for a machine that has never been asked, because that is what the app
    /// already does. `UserDefaults.bool(forKey:)` answers false for a key that
    /// was never written, which would turn the live pass off for everyone who
    /// has not touched the setting -- so absence is read as the default rather
    /// than as a choice.
    nonisolated static func liveTranscriptionEnabled(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: liveTranscriptionKey) as? Bool ?? true
    }

    nonisolated static func store(liveTranscriptionEnabled: Bool, in defaults: UserDefaults) {
        defaults.set(liveTranscriptionEnabled, forKey: liveTranscriptionKey)
    }

    /// Only catalog identifiers are adopted. `SpeechModelResolver` falls through
    /// to Large v3 for a name it does not recognise, so a stored identifier the
    /// catalog has since dropped would quietly become a different, much larger
    /// model rather than the choice the user actually last made.
    nonisolated static func apply(to draft: inout MeetingDraft, from defaults: UserDefaults) {
        if let live = defaults.string(forKey: liveKey), SpeechModelCatalog.model(id: live) != nil {
            draft.liveModel = live
        }
        if let final = defaults.string(forKey: finalKey), SpeechModelCatalog.model(id: final) != nil {
            draft.finalModel = final
        }
    }

    nonisolated static func store(
        liveModelID: String,
        finalModelID: String,
        in defaults: UserDefaults
    ) {
        defaults.set(liveModelID, forKey: liveKey)
        defaults.set(finalModelID, forKey: finalKey)
    }
}

/// Which model each coding-agent CLI is asked to run, between launches.
///
/// One key per tool, because the tools do not share a namespace: a Codex model
/// name means nothing to opencode, and carrying the last choice across a
/// provider switch would send a meeting to a model that does not exist. Stored
/// beside the speech-model choices and read the same way, through an injected
/// `UserDefaults` so a test never touches the real domain.
///
/// Absence is the default state and means "whatever the CLI itself is
/// configured to use". Hushnote does not name a model of its own: doing so
/// would quietly override the user's own configuration on every summary.
enum AgentCLIModelDefaults {
    static let keyPrefix = "agentCLI.model."

    static func key(for tool: AgentCLITool) -> String { keyPrefix + tool.rawValue }

    /// Validated on the way out as well as in. The value ends up in an
    /// argument vector, and the defaults domain is a file a person can edit.
    nonisolated static func model(for tool: AgentCLITool, from defaults: UserDefaults) -> String? {
        guard let stored = defaults.string(forKey: key(for: tool)) else { return nil }
        return AgentCLIModelName.argument(stored)
    }

    /// Storing something unusable clears the key rather than keeping it, so a
    /// cleared field and a refused one both land on the CLI's own default.
    nonisolated static func store(_ raw: String, for tool: AgentCLITool, in defaults: UserDefaults) {
        guard let model = AgentCLIModelName.argument(raw) else {
            defaults.removeObject(forKey: key(for: tool))
            return
        }
        defaults.set(model, forKey: key(for: tool))
    }
}

struct MeetingListItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var template: MeetingTemplate
    var excerpt: String
    var isRecoverable: Bool = false
    var status: MeetingStatus = .idle
    /// Whether this meeting was recorded with "Keep audio after finalization"
    /// on. Carried on the item so the export menu can decide what to offer
    /// without listing a directory on every render. See `MeetingAudioExport`.
    var retainsAudio: Bool = false
}

struct TranscriptLineItem: Identifiable, Equatable {
    let id: UUID
    let segmentID: String
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var isProvisional: Bool
    var isUserEdited: Bool = false
    var possibleLeakage: Bool = false
}

struct InsightWorkspaceState: Equatable {
    var summary = ""
    var topics: [String] = []
    var decisions: [String] = []
    var actions: [String] = []
    var openQuestions: [String] = []
    var answer = ""
    var answerTimestamps: [TimeInterval] = []
    var isGenerating = false
    var error: String?
}

enum InsightProviderChoice: String, CaseIterable, Identifiable {
    case local = "Local GGUF"
    case openAI = "OpenAI API"
    case anthropic = "Anthropic API"
    case chatGPT = "ChatGPT via Codex"
    case claudeCLI = "Claude Code CLI"
    case codexCLI = "Codex CLI"
    case opencodeCLI = "opencode CLI"

    var id: Self { self }
    var isLocal: Bool { self == .local }

    /// The coding-agent CLI this choice drives, for the choices that are one.
    /// These reuse a sign-in the user already has, so they need no API key.
    var agentCLITool: AgentCLITool? {
        switch self {
        case .claudeCLI: .claude
        case .codexCLI: .codex
        case .opencodeCLI: .opencode
        case .local, .openAI, .anthropic, .chatGPT: nil
        }
    }
}

/// A failure the app has to own, because the person who caused it is not
/// necessarily looking at the view that raised it.
struct AppAlert: Equatable {
    var title: String
    var message: String
}

/// The operations that can fail in front of the user.
enum FailureKind: Equatable {
    case meetingLoad
    case noteSave
    case transcriptEditSave
    case insightGeneration
    case questionAnswering
    case export
}

/// Where a failure has to appear to be seen at all.
enum FailureRoute: Equatable {
    /// The workspace that asked for it, where the result would have appeared.
    case insightWorkspace
    /// The app, surfaced once in `AppShellView`. Saving and exporting happen
    /// behind the user's attention: a silent save failure leaves them typing
    /// into an editor that no longer persists, and a silent export failure just
    /// never produces a file.
    case appAlert(title: String)

    nonisolated static func route(for kind: FailureKind) -> FailureRoute {
        switch kind {
        case .meetingLoad: .appAlert(title: "This meeting could not be opened")
        case .noteSave: .appAlert(title: "Your notes are not being saved")
        case .transcriptEditSave: .appAlert(title: "Your transcript correction was not saved")
        case .export: .appAlert(title: "The export did not finish")
        case .insightGeneration, .questionAnswering: .insightWorkspace
        }
    }
}

/// Whether a reload of a meeting may replace the notes buffer on screen.
///
/// A note is edited into memory and written to the database on a debounce, so
/// between the keystroke and the write the buffer is newer than the row. A
/// reload during that window must not read the row back over it.
enum NoteReloadPolicy {
    nonisolated static func shouldAdopt(
        stored: String,
        current: String?,
        hasPendingSave: Bool
    ) -> Bool {
        // An unsaved edit always outranks the row it has not reached yet.
        guard !hasPendingSave else { return false }
        // Nothing loaded yet is different from a note deliberately emptied.
        guard let current else { return true }
        return stored != current
    }
}

@MainActor
@Observable
final class AppViewState {
    var selection: SidebarDestination? = .meetings
    var draft = MeetingDraft()
    var meetings: [MeetingListItem] = []
    var transcript: [TranscriptLineItem] = []
    var insights = InsightWorkspaceState()
    var recordingPhase = RecordingPhase.idle
    var elapsed: TimeInterval = 0
    var systemLevel = 0.0
    var searchText = ""
    var searchMatchedMeetingIDs: Set<UUID>?
    var selectedProvider = InsightProviderChoice.local
    var retainAudio = false
    /// Whether the meeting is transcribed while it happens. Off trades the live
    /// feed for not paying the Neural Engine twice; the final pass then
    /// produces the only transcript. See `LiveTranscriptionPolicy`.
    var liveTranscriptionEnabled = true
    var activeMeetingID: UUID?
    var selectedWorkspaceTab = "Notes"
    var question = ""
    var recordingNotice: String?
    var meetingNotes: [UUID: String] = [:]
    var finalizationStage: FinalizationStage?
    var finalizationDetail: String?
    var alert: AppAlert?

    /// Sends a failure to the channel it belongs to. The two channels are
    /// independent: a failed export must not replace a summary the user still
    /// has, and a failed regenerate must not raise a modal.
    func report(_ kind: FailureKind, _ message: String) {
        switch FailureRoute.route(for: kind) {
        case .insightWorkspace:
            insights.error = message
        case .appAlert(let title):
            alert = AppAlert(title: title, message: message)
        }
    }

    func dismissAlert() {
        alert = nil
    }

    /// Accepts a search result only if it answers what is currently typed.
    ///
    /// Debouncing cancels the previous query, but cancellation is not
    /// instantaneous: a query already in flight can still return, and without
    /// this the last one to finish wins regardless of what it was asking.
    func applySearchMatches(_ ids: Set<UUID>?, for query: String) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        searchMatchedMeetingIDs = ids
    }

    var finalizationLabel: String {
        finalizationDetail ?? finalizationStage?.title ?? "Finalizing transcript…"
    }

    @ObservationIgnored private var elapsedTask: Task<Void, Never>?

    var filteredMeetings: [MeetingListItem] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return meetings }
        return meetings.filter {
            $0.title.localizedStandardContains(searchText)
                || $0.excerpt.localizedStandardContains(searchText)
                || searchMatchedMeetingIDs?.contains($0.id) == true
        }
    }

    var activeMeeting: MeetingListItem? {
        guard let activeMeetingID else { return nil }
        return meetings.first { $0.id == activeMeetingID }
    }

    func markRecordingStarted(meetingID: UUID) {
        activeMeetingID = meetingID
        recordingPhase = .recording
        elapsed = 0
        transcript.removeAll()
        insights = InsightWorkspaceState()
        recordingNotice = nil
        finalizationStage = nil
        finalizationDetail = nil
        startElapsedTimer()
    }

    func markPaused(_ paused: Bool) {
        recordingPhase = paused ? .paused : .recording
    }

    func markFinalizing(
        stage: FinalizationStage = .savingAudio,
        progress: Double = 0,
        detail: String? = nil
    ) {
        recordingPhase = .finalizing(min(1, max(0, progress)))
        finalizationStage = stage
        finalizationDetail = detail
        elapsedTask?.cancel()
    }

    func updateFinalization(
        stage: FinalizationStage,
        progress: Double,
        detail: String? = nil
    ) {
        guard case .finalizing = recordingPhase else { return }
        recordingPhase = .finalizing(min(1, max(0, progress)))
        finalizationStage = stage
        finalizationDetail = detail
    }

    func markFinished() {
        recordingPhase = .idle
        elapsedTask?.cancel()
        if let activeMeetingID {
            selection = .meeting(activeMeetingID)
        }
        self.activeMeetingID = nil
        finalizationStage = nil
        finalizationDetail = nil
    }

    func markFailed(_ failure: RecordingFailure) {
        recordingPhase = .failed(failure)
        recordingNotice = nil
        finalizationDetail = nil
        elapsedTask?.cancel()
    }

    /// Clears the failure banner. Only ever a failure: a live recording is never
    /// something the user meant to dismiss.
    func dismissFailure() {
        guard case .failed = recordingPhase else { return }
        recordingPhase = .idle
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.recordingPhase == .recording {
                    self.elapsed += 1
                }
            }
        }
    }
}
