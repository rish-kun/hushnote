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

struct MeetingListItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var template: MeetingTemplate
    var excerpt: String
    var isRecoverable: Bool = false
    var status: MeetingStatus = .idle
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

    var id: Self { self }
    var isLocal: Bool { self == .local }
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
