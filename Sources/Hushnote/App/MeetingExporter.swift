import AppKit
import Foundation

enum MeetingExportFormat: String {
    case markdown
    case srt
    case json

    var fileExtension: String { rawValue == "markdown" ? "md" : rawValue }
}

enum MeetingExporter {
    @MainActor
    static func export(
        meeting: MeetingListItem,
        transcript: [TranscriptSegment],
        insights: InsightWorkspaceState,
        format: MeetingExportFormat
    ) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(meeting.title) + "." + format.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let data: Data
        switch format {
        case .markdown:
            data = Data(markdown(meeting: meeting, transcript: transcript, insights: insights).utf8)
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

    private static func markdown(
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

    private static func sanitized(_ value: String) -> String {
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
