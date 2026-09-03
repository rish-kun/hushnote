import AppKit
import Foundation
import UniformTypeIdentifiers

/// The formats a transcript is serialized into. The meeting's audio is not one
/// of them: it is a file that already exists and is copied, not a document
/// this type builds.
enum TranscriptExportFormat: String {
    case markdown
    case srt
    case json

    var fileExtension: String { rawValue == "markdown" ? "md" : rawValue }
}

/// Whether the recording itself can be handed over, and which file that is.
///
/// Audio is deleted the moment a meeting finalizes unless the user asked to
/// keep it, so for most meetings there is nothing to export.
enum MeetingAudioExport {
    /// Decided from the loaded meeting, not from the disk: this answers on
    /// every render of the export menu, and a meeting directory must not be
    /// listed that often. The model can still be stale — audio deleted under a
    /// meeting already on screen — so the export path checks disk for real.
    ///
    /// Deletion only happens after a *successful* finalization. A meeting that
    /// never got there still holds its recording, and that recording is the
    /// only copy of the meeting.
    nonisolated static func isAvailable(retainsAudio: Bool, status: MeetingStatus) -> Bool {
        switch status {
        case .recording, .finalizing, .interrupted, .failed: return true
        case .idle, .ready: return retainsAudio
        }
    }

    /// The take worth exporting. A meeting directory can hold several — each
    /// capture retry allocates its own — and the one holding the most audio is
    /// the meeting. Pre-take `system.caf` recordings are still found.
    nonisolated static func source(in directory: URL, fileManager: FileManager = .default) -> URL? {
        AudioPipeline.longestTake(in: directory, fileManager: fileManager)
    }

    /// The extension comes off the file itself. A `.caf` offered as `.m4a` is a
    /// file no player will open.
    nonisolated static func filename(title: String, source: URL) -> String {
        MeetingExporter.sanitized(title) + "." + source.pathExtension
    }

    /// A disabled item with no explanation is a dead end, so the item says why
    /// it cannot be pressed. Keeping it in place for every meeting is what
    /// makes the feature discoverable at all.
    nonisolated static func menuTitle(isAvailable: Bool) -> String {
        isAvailable ? "Audio (.caf)" : "Audio (not kept for this meeting)"
    }

    /// Said when the model offered the option but the disk disagrees.
    static let missingAudioMessage =
        "This meeting's audio is no longer on disk. It is removed after finalization unless Settings keeps it."
}

enum MeetingExporter {
    @MainActor
    static func audioDestination(
        meeting: MeetingListItem,
        format: MeetingAudioFileFormat
    ) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(meeting.title) + "." + format.fileExtension
        panel.canCreateDirectories = true
        panel.allowedContentTypes = switch format {
        case .m4a: [.mpeg4Audio]
        case .originalCAF: [UTType(filenameExtension: "caf") ?? .audio]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func export(
        meeting: MeetingListItem,
        transcript: [TranscriptSegment],
        insights: InsightWorkspaceState,
        format: TranscriptExportFormat
    ) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(meeting.title) + "." + format.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let data: Data
        switch format {
        case .markdown:
            data = Data(meetingMarkdown(meeting: meeting, transcript: transcript, insights: insights).utf8)
        case .srt:
            data = Data(srt(transcript: transcript).utf8)
        case .json:
            let payload = ExportPayload(meeting: meeting, transcript: transcript, insights: insights)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(payload)
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Hands over the recording itself.
    ///
    /// A meeting's audio runs to hundreds of megabytes, so it is never read
    /// into memory the way the text formats are — the file is copied.
    @MainActor
    static func exportAudio(meeting: MeetingListItem, source: URL) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingAudioExport.filename(title: meeting.title, source: source)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try copyAudio(from: source, to: destination)
    }

    /// `copyItem` refuses a destination that exists, and the save panel has
    /// already asked the user about replacing that file by the time we get
    /// here, so the answer they gave is honoured.
    static func copyAudio(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// The portable transcript representation. Clipboard copy and the Markdown
    /// export deliberately call this same formatter: a pasted transcript must
    /// not silently differ from the file a person can save from the adjacent
    /// menu item.
    ///
    /// It is intentionally transcript-only. Summaries and action lists are
    /// mutable interpretations of the conversation, whereas this document is
    /// the timestamped, speaker-attributed source material.
    static func transcriptMarkdown(
        meeting: MeetingListItem,
        transcript: [TranscriptSegment]
    ) -> String {
        var lines = ["# \(meeting.title)", ""]
        lines.append("_\(meeting.startedAt.formatted(date: .long, time: .shortened)) · \(DurationText.clock(meeting.duration))_")
        lines += ["", "## Transcript", ""]
        for segment in transcript {
            let speaker = segment.speakerName ?? segment.speakerID ?? "Speaker"
            lines.append("**[\(DurationText.clock(Double(segment.startMilliseconds) / 1_000))] \(speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The saved Markdown export remains a full meeting document. Clipboard
    /// copy deliberately uses `transcriptMarkdown` above, because it promises
    /// source material rather than mutable summary interpretation.
    private static func meetingMarkdown(
        meeting: MeetingListItem,
        transcript: [TranscriptSegment],
        insights: InsightWorkspaceState
    ) -> String {
        var lines = ["# \(meeting.title)", ""]
        lines.append("_\(meeting.startedAt.formatted(date: .long, time: .shortened)) · \(DurationText.clock(meeting.duration))_")
        if !insights.summary.isEmpty {
            lines += ["", "## Summary", "", insights.summary]
        }
        appendList(&lines, title: "Decisions", values: insights.decisions)
        appendList(&lines, title: "Action items", values: insights.actions)
        appendList(&lines, title: "Open questions", values: insights.openQuestions)
        lines += ["", "## Transcript", ""]
        for segment in transcript {
            let speaker = segment.speakerName ?? segment.speakerID ?? "Speaker"
            lines.append("**[\(DurationText.clock(Double(segment.startMilliseconds) / 1_000))] \(speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendList(_ lines: inout [String], title: String, values: [String]) {
        guard !values.isEmpty else { return }
        lines += ["", "## \(title)", ""]
        lines += values.map { "- \($0)" }
    }

    private static func srt(transcript: [TranscriptSegment]) -> String {
        transcript.enumerated().map { index, segment in
            let speaker = segment.speakerName ?? segment.speakerID ?? "Speaker"
            return """
            \(index + 1)
            \(srtTime(segment.startMilliseconds)) --> \(srtTime(segment.endMilliseconds))
            \(speaker): \(segment.text)
            """
        }.joined(separator: "\n\n")
    }

    private static func srtTime(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        let hours = value / 3_600_000
        let minutes = (value / 60_000) % 60
        let seconds = (value / 1_000) % 60
        let millis = value % 1_000
        return String(format: "%02lld:%02lld:%02lld,%03lld", hours, minutes, seconds, millis)
    }

    static func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ExportPayload: Encodable {
    struct MeetingPayload: Encodable {
        let id: UUID
        let title: String
        let startedAt: Date
        let durationSeconds: TimeInterval
        let template: String
    }

    struct InsightPayload: Encodable {
        let summary: String
        let topics: [String]
        let decisions: [String]
        let actions: [String]
        let openQuestions: [String]
    }

    let meeting: MeetingPayload
    let transcript: [TranscriptSegment]
    let insights: InsightPayload

    init(meeting: MeetingListItem, transcript: [TranscriptSegment], insights: InsightWorkspaceState) {
        self.meeting = MeetingPayload(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            durationSeconds: meeting.duration,
            template: meeting.template.rawValue
        )
        self.transcript = transcript
        self.insights = InsightPayload(
            summary: insights.summary,
            topics: insights.topics,
            decisions: insights.decisions,
            actions: insights.actions,
            openQuestions: insights.openQuestions
        )
    }
}
