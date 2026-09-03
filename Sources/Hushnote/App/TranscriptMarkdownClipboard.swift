import AppKit
import Foundation

/// The small seam between an otherwise deterministic transcript document and
/// the system pasteboard. Tests can supply an in-memory writer instead of
/// changing the person's real clipboard.
@MainActor
protocol TranscriptClipboardWriting {
    @discardableResult
    func write(_ string: String) -> Bool
}

@MainActor
struct SystemTranscriptClipboardWriter: TranscriptClipboardWriting {
    @discardableResult
    func write(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}

/// Copies the exact transcript-only Markdown document used by file export.
/// Keeping pasteboard work here prevents the workspace from growing an AppKit
/// dependency just to expose a document action.
enum TranscriptMarkdownClipboard {
    @MainActor
    @discardableResult
    static func copy(
        meeting: MeetingListItem,
        transcript: [TranscriptSegment]
    ) -> Bool {
        copy(
            meeting: meeting,
            transcript: transcript,
            clipboard: SystemTranscriptClipboardWriter()
        )
    }

    @MainActor
    @discardableResult
    static func copy<Clipboard: TranscriptClipboardWriting>(
        meeting: MeetingListItem,
        transcript: [TranscriptSegment],
        clipboard: Clipboard
    ) -> Bool {
        clipboard.write(MeetingExporter.transcriptMarkdown(meeting: meeting, transcript: transcript))
    }
}

/// Presentation-only state for the workspace menu. The caller owns the short
/// delay before returning to `.idle`, which keeps time and SwiftUI state out of
/// this pure decision seam.
enum TranscriptMarkdownCopyFeedback: Equatable {
    case idle
    case copied
}

enum TranscriptMarkdownCopyFeedbackPolicy {
    static let confirmationDuration: Duration = .seconds(1.5)

    nonisolated static func isEnabled<Element>(transcript: [Element]) -> Bool {
        !transcript.isEmpty
    }

    nonisolated static func state(didCopy: Bool) -> TranscriptMarkdownCopyFeedback {
        didCopy ? .copied : .idle
    }

    nonisolated static func title(for feedback: TranscriptMarkdownCopyFeedback) -> String {
        switch feedback {
        case .idle: "Copy transcript as Markdown"
        case .copied: "Copied as Markdown"
        }
    }

    nonisolated static func accessibilityLabel(for feedback: TranscriptMarkdownCopyFeedback) -> String {
        switch feedback {
        case .idle: "Copy meeting transcript as Markdown"
        case .copied: "Meeting transcript copied as Markdown"
        }
    }
}
