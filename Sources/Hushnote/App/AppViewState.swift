import Foundation
import Observation

enum SidebarDestination: Hashable {
    case meetings
    case unfiled
    case folder(UUID)
    case shared
    case recentlyDeleted
    case models
    case storage
    case settings
    case meeting(UUID)
}

enum WorkspaceTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case notes = "Notes"
    case transcript = "Transcript"
    case summary = "Summary"
    case ask = "Ask"

    var id: Self { self }
}

/// Which workspace tabs a meeting offers in a given recording phase.
///
/// Summary and Ask are gated only on the transcript being non-empty, which it
/// is during live capture -- so exposing them mid-recording would let a summary
/// or a grounded answer be generated against provisional text. The final pass
/// mints entirely new segment identifiers, so every citation such an answer
/// captured would address a row that no longer exists. The screen already says
/// "Live text is provisional"; this is the same statement made structurally.
enum WorkspaceTabAvailability {
    /// The phase that governs *this* meeting's tabs.
    ///
    /// `state.recordingPhase` is global, but only one meeting owns the capture
    /// session. While meeting A records, meeting B is idle and its Summary and
    /// Ask tabs are perfectly meaningful -- reading the global phase would hide
    /// them for the duration of an unrelated recording. Same guard
    /// `MeetingWorkspaceRoute` uses to decide which workspace to show at all.
    nonisolated static func governingPhase(
        _ phase: RecordingPhase,
        activeMeetingID: UUID?,
        meetingID: UUID
    ) -> RecordingPhase {
        activeMeetingID == meetingID ? phase : .idle
    }

    nonisolated static func available(during phase: RecordingPhase) -> [WorkspaceTab] {
        phase.isBusy ? [.notes, .transcript] : WorkspaceTab.allCases
    }

    /// Resolves a persisted choice against what the phase actually offers.
    ///
    /// Deliberately read-only, like `AppViewState.resolvedSidebarDestination`:
    /// starting a recording on a meeting whose stored tab is Summary must not
    /// overwrite that preference, or the tab silently changes under the user
    /// for good the moment they press Stop.
    nonisolated static func resolved(
        _ stored: WorkspaceTab,
        during phase: RecordingPhase
    ) -> WorkspaceTab {
        let offered = available(during: phase)
        return offered.contains(stored) ? stored : .notes
    }
}

enum RecordingStartupStage: Equatable, Sendable {
    case idle
    case arming
    case waitingForFirstBuffer
    case ready

    var title: String {
        switch self {
        case .idle: "Ready"
        case .arming: "Arming audio…"
        case .waitingForFirstBuffer: "Waiting for audio…"
        case .ready: "Recording"
        }
    }
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
        stages.append(contentsOf: [.loadingFinalModel, .transcribing, .diarizing])
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
    var folderID: UUID?
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
    /// The durable version currently supplying `summary` and the structured
    /// insight lists below it.
    var activeSummaryVersionID: UUID?
    /// Newest first. History is loaded in pages so opening a well-used meeting
    /// never decodes every provider response it has ever produced.
    var summaryVersions: [SummaryVersion] = []
    var hasMoreSummaryVersions = false
    var isLoadingSummaryVersions = false
    /// A generated version that has not replaced the user's current summary.
    var candidateSummaryVersionID: UUID?
    var summaryDraft = ""
    var isEditingSummary = false
    var isSavingSummary = false
    var summarySaveConfirmation: Date?
    var topics: [String] = []
    var decisions: [String] = []
    var actions: [String] = []
    var openQuestions: [String] = []
    var question = ""
    var answer = ""
    /// The quotes behind the answer, each already proven word-for-word present
    /// in the transcript by `CitationValidator`. These used to be reduced to
    /// bare start times and the quotes thrown away -- which discarded the one
    /// thing that makes a grounded answer checkable.
    var answerCitations: [EvidenceCitation] = []
    /// Quotes the model offered that were *not* in the transcript, and were
    /// removed. Worth showing: it is the product's whole thesis, demonstrated.
    var rejectedCitations = 0
    var isGenerating = false
    var generationStage: InsightGenerationStage?
    var generationProgress = 0.0
    var generationStartedAt: Date?
    var error: String?

    var hasUnsavedSummaryChanges: Bool {
        isEditingSummary && summaryDraft != summary
    }

    var candidateSummaryVersion: SummaryVersion? {
        guard let candidateSummaryVersionID else { return nil }
        return summaryVersions.first { $0.id == candidateSummaryVersionID }
    }
}

enum AudioExportState: Equatable, Sendable {
    case idle
    case exporting(format: MeetingAudioFileFormat, progress: Double)
    case succeeded(URL)
    case failed(String)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

enum InsightGenerationStage: Equatable, Sendable {
    case checkingProvider
    case extracting(current: Int, total: Int)
    case synthesizing
    case validating
    case saving

    var title: String {
        switch self {
        case .checkingProvider: "Checking provider…"
        case .extracting(let current, let total): "Reading transcript \(current) of \(total)…"
        case .synthesizing: "Writing summary…"
        case .validating: "Checking citations…"
        case .saving: "Saving summary…"
        }
    }

    var progress: Double {
        switch self {
        case .checkingProvider: 0.05
        case .extracting(let current, let total):
            0.1 + 0.55 * Double(current) / Double(max(1, total))
        case .synthesizing: 0.72
        case .validating: 0.88
        case .saving: 0.96
        }
    }
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
    var displayName: String { rawValue }

    /// A coding-agent CLI runs on this Mac and then sends the transcript
    /// onward. "Local command" is not "local", and the disclosure has to say so.
    var isAgentCLI: Bool {
        self == .claudeCLI || self == .codexCLI || self == .opencodeCLI
    }

    var stableID: String {
        switch self {
        case .local: "local-gguf"
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .chatGPT: "chatgpt-codex-app-server"
        case .claudeCLI: "cli-claude"
        case .codexCLI: "cli-codex"
        case .opencodeCLI: "cli-opencode"
        }
    }

    init?(stableID: String) {
        switch stableID {
        case "local-gguf": self = .local
        case "openai": self = .openAI
        case "anthropic": self = .anthropic
        case "chatgpt-codex-app-server": self = .chatGPT
        case "cli-claude": self = .claudeCLI
        case "cli-codex": self = .codexCLI
        case "cli-opencode": self = .opencodeCLI
        default: return nil
        }
    }

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
    case meetingRename
    case meetingDelete
    case folderManagement
    case noteSave
    case shareSync
    case summarySave
    case speakerRename
    case transcriptEditSave
    case storage
    case insightGeneration
    case questionAnswering
    case export
    case recordingImport
    case finalization
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
        case .meetingRename: .appAlert(title: "The meeting name was not saved")
        case .meetingDelete: .appAlert(title: "The meeting could not be deleted")
        case .folderManagement: .appAlert(title: "The folder could not be updated")
        case .noteSave: .appAlert(title: "Your notes are not being saved")
        // An alert, not a quiet status line: a share that stopped publishing is
        // a link other people are still reading, showing content that no longer
        // matches what this Mac holds.
        case .shareSync: .appAlert(title: "A shared link could not be updated")
        case .summarySave: .appAlert(title: "Your summary was not saved")
        case .speakerRename: .appAlert(title: "The speaker name was not saved")
        case .transcriptEditSave: .appAlert(title: "Your transcript correction was not saved")
        case .storage: .appAlert(title: "Storage could not be updated")
        case .export: .appAlert(title: "The export did not finish")
        case .recordingImport: .appAlert(title: "The recording could not be imported")
        case .finalization: .appAlert(title: "Finalization could not be retried")
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
    var recentlyDeletedMeetings: [MeetingListItem] = []
    var folders: [MeetingFolder] = []
    /// Active-meeting counts, keyed by folder, for sidebar badges.
    var folderMeetingCounts: [UUID: Int] = [:]
    var unfiledMeetingCount = 0
    var searchResults: [MeetingSearchResult] = []
    /// Whether the transcript search behind the current query has settled.
    ///
    /// Without this, an empty result set during the 250ms debounce is
    /// indistinguishable from a query that genuinely matched nothing, and a
    /// fast typist gets "No matching meetings" flashing between keystrokes.
    var searchPhase: SearchPhase = .idle

    var transcript: [TranscriptLineItem] = []
    /// Sparse recording apparatus for the selected meeting. These boundaries
    /// are rendered beside the transcript and never become transcript prose.
    var recordingEvents: [RecordingEvent] = []
    /// Durable user emphasis, kept by meeting so loading another workspace
    /// cannot make markers appear to belong to the currently selected meeting.
    var recordingMarkers: [UUID: [RecordingMarker]] = [:]
    /// A request to bring one paragraph into view, raised by the transcript
    /// index. Carried as identity rather than as a position, for the same
    /// reason every other transcript address in this app is.
    var transcriptJumpRequest: TranscriptJumpRequest?
    private var meetingInsights: [UUID: InsightWorkspaceState] = [:]
    private var unscopedInsights = InsightWorkspaceState()
    var recordingPhase = RecordingPhase.idle
    /// Captured-media duration. It freezes during pause and sleep.
    var elapsed: TimeInterval = 0
    /// Wall time since this meeting timeline began. Unlike `elapsed`, this
    /// continues while the user intentionally pauses.
    var wallElapsed: TimeInterval = 0
    var systemLevel = 0.0
    /// Read only by `MicrophoneLevelMeter`; active workspace parents must not
    /// observe this buffer-rate value.
    var microphoneLevel = 0.0
    var searchText = ""
    var searchMatchedMeetingIDs: Set<UUID>?
    var selectedProvider = InsightProviderChoice.local
    var retainAudio = true
    var microphoneCaptureEnabled = true
    var selectedMicrophone: PreferredMicrophone?
    var availableMicrophones: [PreferredMicrophone] = []
    /// Low-frequency evidence for the meeting diagnostics surface. Moving
    /// levels stay in their independent properties above.
    var recordingDiagnostics = RecordingDiagnosticsSnapshot(
        sources: [
            RecordingSourceDiagnostics(
                source: .system,
                isExpected: false,
                isEnabled: false,
                lifecycle: .disabled,
                durableWriterAdvanced: false,
                lastAudibleAge: nil
            ),
            RecordingSourceDiagnostics(
                source: .microphone,
                isExpected: false,
                isEnabled: false,
                lifecycle: .disabled,
                durableWriterAdvanced: false,
                lastAudibleAge: nil
            ),
        ],
        liveText: .disabled,
        writer: .init(sampleRateHertz: nil)
    )
    /// Whether the meeting is transcribed while it happens. Off trades the live
    /// feed for not paying the Neural Engine twice; the final pass then
    /// produces the only transcript. See `LiveTranscriptionPolicy`.
    var liveTranscriptionEnabled = true
    var activeMeetingID: UUID?
    var meetingWorkspaceTabs: [UUID: WorkspaceTab] = [:]
    var recordingStartupStage = RecordingStartupStage.idle
    var question = ""
    var recordingNotice: String?
    var meetingNotes: [UUID: String] = [:]
    /// Every meeting this Mac has published, by meeting. There is no web
    /// dashboard, so this dictionary and the `Shared` route are the only place
    /// a link can be seen or withdrawn.
    var meetingShares: [UUID: MeetingShare] = [:]
    /// Meetings with a share request in flight -- creating, republishing,
    /// changing a password or revoking.
    var sharesInFlight: Set<UUID> = []
    /// The meeting whose share sheet is open, if any.
    var shareSheetMeetingID: UUID?
    /// Meetings whose notes have a keystroke that has not reached the database
    /// yet. The debounce and the write already existed in `AppCoordinator`;
    /// only the page had no way to see them, so it printed the standing
    /// promise "Saved automatically to this meeting" instead of the state.
    var notesSaving: Set<UUID> = []
    var finalizationStage: FinalizationStage?
    var finalizationDetail: String?
    /// Remaining work for background finalization, by meeting. This is kept
    /// separate from the global recording phase because another meeting can
    /// be actively capturing while older jobs wait in the queue.
    var finalizationETAs: [UUID: FinalizationETARange] = [:]
    /// Session-level durable jobs grouped by their meeting. This survives the
    /// brief Stop handoff, where `recordingPhase` intentionally returns to
    /// idle so another meeting can begin recording while this one finalizes.
    var finalizationJobsByMeeting: [UUID: [FinalizationJob]] = [:]
    var alert: AppAlert?
    var audioExports: [UUID: AudioExportState] = [:]
    var storageReport: StorageReport?
    var isScanningStorage = false
    var storageDeletingRecordingIDs: Set<UUID> = []

    func applyMicrophonePreferences(_ preferences: AppPreferences) {
        microphoneCaptureEnabled = preferences.microphoneCaptureEnabled
        selectedMicrophone = preferences.selectedMicrophone
    }

    private var displayedInsightMeetingID: UUID? {
        if case .meeting(let id) = selection { return id }
        return activeMeetingID
    }

    /// Compatibility accessor for views showing the selected meeting. Durable
    /// async work should use `updateInsights(for:)` so a late completion cannot
    /// write into whichever meeting happens to be selected at that moment.
    var insights: InsightWorkspaceState {
        get {
            guard let id = displayedInsightMeetingID else { return unscopedInsights }
            return meetingInsights[id, default: InsightWorkspaceState()]
        }
        set {
            guard let id = displayedInsightMeetingID else {
                unscopedInsights = newValue
                return
            }
            meetingInsights[id] = newValue
        }
    }

    func insights(for meetingID: UUID) -> InsightWorkspaceState {
        meetingInsights[meetingID, default: InsightWorkspaceState()]
    }

    func updateInsights(
        for meetingID: UUID,
        _ update: (inout InsightWorkspaceState) -> Void
    ) {
        var workspace = meetingInsights[meetingID, default: InsightWorkspaceState()]
        update(&workspace)
        meetingInsights[meetingID] = workspace
    }

    func replaceInsights(_ workspace: InsightWorkspaceState, for meetingID: UUID) {
        meetingInsights[meetingID] = workspace
    }

    /// Summary work is meeting-scoped and may continue after navigation. Quit
    /// protection therefore cannot look only at `insights`, which follows the
    /// currently displayed meeting.
    var hasInsightWork: Bool {
        unscopedInsights.isGenerating || meetingInsights.values.contains(where: \.isGenerating)
    }

    var hasUnsavedSummaryChanges: Bool {
        unscopedInsights.hasUnsavedSummaryChanges
            || meetingInsights.values.contains(where: \.hasUnsavedSummaryChanges)
    }

    var unsavedSummaryMeetingID: UUID? {
        if let displayedInsightMeetingID,
           meetingInsights[displayedInsightMeetingID]?.hasUnsavedSummaryChanges == true {
            return displayedInsightMeetingID
        }
        return meetingInsights.first(where: { $0.value.hasUnsavedSummaryChanges })?.key
    }

    func workspaceTab(for meetingID: UUID) -> WorkspaceTab {
        meetingWorkspaceTabs[meetingID] ?? .notes
    }

    func markers(for meetingID: UUID) -> [RecordingMarker] {
        recordingMarkers[meetingID, default: []]
    }

    func setWorkspaceTab(_ tab: WorkspaceTab, for meetingID: UUID) {
        meetingWorkspaceTabs[meetingID] = tab
    }

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
    func applySearchMatches(
        _ ids: Set<UUID>?,
        results: [MeetingSearchResult] = [],
        for query: String
    ) {
        // Load-bearing: a slow response for an abandoned query must not
        // overwrite the results of the one the user is actually looking at.
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        searchMatchedMeetingIDs = ids
        searchResults = results
        searchPhase = trimmed.isEmpty ? .idle : .done
    }

    var finalizationLabel: String {
        finalizationDetail ?? finalizationStage?.title ?? "Finalizing transcript…"
    }

    func finalizationPresentation(for meetingID: UUID) -> MeetingFinalizationPresentation? {
        MeetingFinalizationPresentationPolicy.presentation(
            jobs: finalizationJobsByMeeting[meetingID, default: []],
            eta: finalizationETAs[meetingID],
            isBlockedByLiveCapture: recordingPhase.isCapturing && activeMeetingID != meetingID
        )
    }

    func replaceFinalizationJobs(_ jobs: [FinalizationJob], for meetingID: UUID) {
        finalizationJobsByMeeting[meetingID] = jobs.sorted {
            if $0.queuedAt != $1.queuedAt { return $0.queuedAt < $1.queuedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func recordFinalizationJob(_ job: FinalizationJob, for meetingID: UUID) {
        var jobs = finalizationJobsByMeeting[meetingID, default: []]
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        replaceFinalizationJobs(jobs, for: meetingID)
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

    /// Meetings whose title answers the query, matched in memory.
    ///
    /// The list is fully resident, so title hits are instant while the FTS5
    /// pass over transcripts is still running behind the debounce.
    func meetingsMatchingTitle(_ query: String) -> [MeetingListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return meetings.filter { $0.title.localizedStandardContains(trimmed) }
    }

    var selectedFolderID: UUID? {
        if case .folder(let id) = selection { return id }
        return nil
    }

    /// A persisted meeting or folder can disappear between launches. Resolve
    /// it before SwiftUI renders the destination so a stale UUID never becomes
    /// an empty, unreachable workspace.
    nonisolated static func resolvedSidebarDestination(
        _ destination: SidebarDestination?,
        meetingIDs: Set<UUID>,
        folderIDs: Set<UUID>,
        hasShares: Bool = false
    ) -> SidebarDestination {
        switch destination {
        case .meeting(let id) where !meetingIDs.contains(id),
             .folder(let id) where !folderIDs.contains(id):
            .meetings
        // The sidebar only offers Shared once something is shared, so a
        // persisted `.shared` with nothing in it is a destination with no row
        // pointing at it: an empty page reachable only by having been there
        // last launch. Same reason a stale meeting or folder id resolves here.
        case .shared where !hasShares:
            .meetings
        case let destination?:
            destination
        case nil:
            .meetings
        }
    }

    var activeMeeting: MeetingListItem? {
        guard let activeMeetingID else { return nil }
        return meetings.first { $0.id == activeMeetingID }
    }

    func markRecordingStarted(
        meetingID: UUID,
        preservingExistingContent: Bool = false,
        timelineStartMilliseconds: Int64 = 0
    ) {
        activeMeetingID = meetingID
        recordingPhase = .recording
        elapsed = Double(max(0, timelineStartMilliseconds)) / 1_000
        wallElapsed = elapsed
        if !preservingExistingContent {
            transcript.removeAll()
            meetingInsights[meetingID] = InsightWorkspaceState()
        }
        recordingNotice = nil
        finalizationStage = nil
        finalizationDetail = nil
        recordingStartupStage = .ready
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
        recordingStartupStage = .idle
    }

    func markFailed(_ failure: RecordingFailure) {
        recordingPhase = .failed(failure)
        recordingNotice = nil
        finalizationDetail = nil
        recordingStartupStage = .idle
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
                if self.recordingPhase.isCapturing { self.wallElapsed += 1 }
                if self.recordingPhase == .recording { self.elapsed += 1 }
            }
        }
    }
}


/// One request to scroll the transcript to a paragraph.
///
/// `issued` is what makes asking twice for the same paragraph a second event:
/// without it the value would compare equal and `onChange` would not fire.
enum SearchPhase: Equatable, Sendable {
    /// No query.
    case idle
    /// A query is typed; the transcript search behind it has not answered yet.
    case pending
    case done
}

struct TranscriptJumpRequest: Equatable, Sendable {
    /// Either a paragraph to scroll to, raised by the transcript's own index...
    let paragraphID: UUID?
    /// ...or a segment, raised by search, which the pane resolves to whichever
    /// paragraph that segment was folded into.
    let segmentID: String?
    /// A deliberate return to the live edge. Kept distinct from a segment
    /// reveal so find navigation cannot accidentally re-enable auto-follow.
    let returnsToLatest: Bool
    let issued: Date

    init(
        paragraphID: UUID? = nil,
        segmentID: String? = nil,
        returnsToLatest: Bool = false,
        issued: Date = Date()
    ) {
        self.paragraphID = paragraphID
        self.segmentID = segmentID
        self.returnsToLatest = returnsToLatest
        self.issued = issued
    }
}
