import Foundation
import Testing
@testable import Hushnote

@Suite("Transcript Markdown")
struct TranscriptMarkdownTests {
    private let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("The Markdown document is source material, with timestamps and speakers")
    func transcriptDocument() {
        let markdown = MeetingExporter.transcriptMarkdown(
            meeting: meeting,
            transcript: [
                segment(
                    id: "first",
                    startMilliseconds: 3_723_000,
                    text: "The launch date is Tuesday.",
                    speakerName: "Mara"
                ),
                segment(
                    id: "second",
                    startMilliseconds: 3_725_000,
                    text: "I will update the brief.",
                    speakerName: nil,
                    speakerID: "speaker-2"
                ),
                segment(
                    id: "third",
                    startMilliseconds: 3_726_000,
                    text: "Thank you.",
                    speakerName: nil,
                    speakerID: nil
                )
            ]
        )

        #expect(markdown.hasPrefix("# Roadmap review\n\n_"))
        #expect(markdown.contains(" · 1:02:03_\n\n## Transcript\n\n"))
        #expect(markdown.contains("**[1:02:03] Mara:** The launch date is Tuesday."))
        #expect(markdown.contains("**[1:02:05] speaker-2:** I will update the brief."))
        #expect(markdown.contains("**[1:02:06] Speaker:** Thank you."))
        #expect(markdown.hasSuffix("**[1:02:06] Speaker:** Thank you.\n"))
    }

    @Test("Transcript Markdown excludes mutable insight sections")
    func transcriptDocumentContainsNoInsights() {
        let markdown = MeetingExporter.transcriptMarkdown(meeting: meeting, transcript: [])

        #expect(markdown.contains("## Transcript"))
        #expect(!markdown.contains("## Summary"))
        #expect(!markdown.contains("## Decisions"))
        #expect(!markdown.contains("## Action items"))
        #expect(!markdown.contains("## Open questions"))
    }

    @Test("Clipboard copy writes the canonical document")
    @MainActor
    func clipboardCopy() {
        let clipboard = RecordingClipboard(result: true)
        let transcript = [segment(id: "first", startMilliseconds: 0, text: "Hello", speakerName: "You")]

        let didCopy = TranscriptMarkdownClipboard.copy(
            meeting: meeting,
            transcript: transcript,
            clipboard: clipboard
        )

        #expect(didCopy)
        #expect(clipboard.string == MeetingExporter.transcriptMarkdown(meeting: meeting, transcript: transcript))
    }

    @Test("Copy feedback only confirms successful clipboard writes")
    func copyFeedback() {
        #expect(TranscriptMarkdownCopyFeedbackPolicy.isEnabled(transcript: []) == false)
        #expect(TranscriptMarkdownCopyFeedbackPolicy.isEnabled(transcript: [segment(id: "one")]))
        #expect(TranscriptMarkdownCopyFeedbackPolicy.state(didCopy: false) == .idle)
        #expect(TranscriptMarkdownCopyFeedbackPolicy.state(didCopy: true) == .copied)
        #expect(TranscriptMarkdownCopyFeedbackPolicy.title(for: .idle) == "Copy transcript as Markdown")
        #expect(TranscriptMarkdownCopyFeedbackPolicy.title(for: .copied) == "Copied as Markdown")
        #expect(
            TranscriptMarkdownCopyFeedbackPolicy.accessibilityLabel(for: .copied)
                == "Meeting transcript copied as Markdown"
        )
    }

    private var meeting: MeetingListItem {
        MeetingListItem(
            id: meetingID,
            title: "Roadmap review",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 3_723,
            template: .general,
            excerpt: ""
        )
    }

    private func segment(
        id: String,
        startMilliseconds: Int64 = 0,
        text: String = "Hello",
        speakerName: String? = nil,
        speakerID: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: meetingID,
            source: .system,
            startMilliseconds: startMilliseconds,
            endMilliseconds: startMilliseconds + 1_000,
            text: text,
            speakerID: speakerID,
            speakerName: speakerName
        )
    }
}

@MainActor
private final class RecordingClipboard: TranscriptClipboardWriting {
    let result: Bool
    private(set) var string: String?

    init(result: Bool) {
        self.result = result
    }

    func write(_ string: String) -> Bool {
        self.string = string
        return result
    }
}
