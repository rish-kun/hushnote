import Foundation
import Testing
@testable import Hushnote

/// The transcript's index. Chapters open exactly where the reading flow draws a
/// rule, so the index and the page cannot disagree about where the beats are.
@Suite("Transcript chapters")
struct TranscriptChapterTests {
    @Test("An empty transcript has no chapters")
    func empty() {
        #expect(TranscriptGrouping.chapters([]).isEmpty)
    }

    @Test("Chapters open where a paragraph opens a section")
    func chaptersFollowSections() {
        let paragraphs = TranscriptGrouping.paragraphs(Self.longMeeting())
        let chapters = TranscriptGrouping.chapters(paragraphs)
        let openings = paragraphs.filter(\.opensSection).map(\.id)

        #expect(chapters.count == openings.count)
        #expect(chapters.map(\.id) == openings)
        // Every paragraph is filed under exactly one chapter.
        #expect(chapters.flatMap(\.paragraphIDs).count == paragraphs.count)
    }

    /// The bug this keying exists to prevent: every change of voice re-anchors
    /// the displayed time, so keying chapters on the timestamp gave a
    /// conversation one chapter per reply.
    @Test("A back-and-forth inside one stretch stays one chapter")
    func speakers() throws {
        let chapters = TranscriptGrouping.chapters(
            TranscriptGrouping.paragraphs([
                Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 4, text: "Shall we begin?"),
                Self.line(ordinal: 1, speaker: "Grace", start: 30, end: 34, text: "Yes, let us."),
                Self.line(ordinal: 2, speaker: "Ada", start: 60, end: 64, text: "Good."),
            ])
        )

        #expect(chapters.count == 1)
        let first = try #require(chapters.first)
        #expect(first.speakers == ["Ada", "Grace"])
        #expect(first.paragraphIDs.count == 3)
    }

    /// And the other half of the same claim: a real beat still opens one.
    @Test("Crossing a marker opens a chapter")
    func markerOpensChapter() {
        let chapters = TranscriptGrouping.chapters(
            TranscriptGrouping.paragraphs([
                Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 4, text: "Before the break."),
                Self.line(ordinal: 1, speaker: "Ada", start: 620, end: 624, text: "After it."),
            ])
        )
        #expect(chapters.count == 2)
    }

    /// While recording, the chapter still accruing text would rewrite its own
    /// opening words on every buffer and reflow the index under the reader.
    @Test("The open chapter is withheld while recording")
    func withholdsOpenChapter() {
        let paragraphs = TranscriptGrouping.paragraphs(Self.longMeeting())
        let closed = TranscriptGrouping.chapters(paragraphs, includesOpenChapter: false)
        let all = TranscriptGrouping.chapters(paragraphs)

        #expect(closed.count == all.count - 1)
        #expect(closed.map(\.id) == all.dropLast().map(\.id))
    }

    @Test("Withholding never underflows a single-chapter transcript")
    func singleChapter() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 4, text: "One thought only."),
        ])
        #expect(TranscriptGrouping.chapters(paragraphs, includesOpenChapter: false).isEmpty)
    }

    // MARK: - Openings

    @Test("A short opening is left alone")
    func shortOpening() {
        #expect(TranscriptGrouping.opening(of: "Short enough.") == "Short enough.")
    }

    /// Truncating mid-word makes the index look broken rather than brief.
    @Test("A long opening is cut on a word boundary")
    func longOpening() {
        let text = String(repeating: "alpha ", count: 40)
        let opening = TranscriptGrouping.opening(of: text)

        #expect(opening.hasSuffix("\u{2026}"))
        #expect(opening.count <= TranscriptGrouping.chapterOpeningLimit + 1)
        #expect(opening.dropLast().hasSuffix("alpha"))
    }

    @Test("A single unbroken word still terminates")
    func unbrokenOpening() {
        let opening = TranscriptGrouping.opening(of: String(repeating: "x", count: 200))
        #expect(opening.hasSuffix("\u{2026}"))
        #expect(opening.count == TranscriptGrouping.chapterOpeningLimit + 1)
    }

    // MARK: - Fixtures

    /// Long enough to cross several marker intervals, so more than one chapter
    /// actually opens.
    private static func longMeeting() -> [TranscriptLineItem] {
        (0..<24).map { ordinal in
            line(
                ordinal: ordinal,
                speaker: ordinal.isMultiple(of: 3) ? "Grace" : "Ada",
                start: Double(ordinal) * 120,
                end: Double(ordinal) * 120 + 8,
                text: "A sentence with enough of a shape to read as one paragraph."
            )
        }
    }

    private static func line(
        ordinal: Int,
        speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) -> TranscriptLineItem {
        TranscriptLineItem(
            id: UUID(),
            segmentID: "segment-\(ordinal)",
            speaker: speaker,
            start: start,
            end: end,
            text: text,
            isProvisional: false
        )
    }
}

/// Which chapter the reader is in, answered from the headers `LazyVStack`
/// actually rendered rather than from a scan of every chapter.
@Suite("Transcript chapter visibility")
struct TranscriptChapterVisibilityTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private var order: [UUID] { [a, b, c] }

    @Test("Nothing reported yields nothing")
    func empty() {
        #expect(TranscriptChapterVisibility.current(headerOffsets: [:], order: order) == nil)
        #expect(TranscriptChapterVisibility.current(headerOffsets: [a: 0], order: []) == nil)
    }

    @Test("The last header past the top edge is the one you are reading")
    func lastPassed() {
        let offsets: [UUID: CGFloat] = [a: -400, b: -120, c: 300]
        #expect(TranscriptChapterVisibility.current(headerOffsets: offsets, order: order) == b)
    }

    /// At the very top of the transcript nothing has scrolled past yet, and the
    /// index must still point somewhere.
    @Test("With nothing past the edge, the first visible header wins")
    func nonePassed() {
        let offsets: [UUID: CGFloat] = [b: 200, c: 600]
        #expect(TranscriptChapterVisibility.current(headerOffsets: offsets, order: order) == b)
    }

    /// The map is sparse: only rendered headers report at all.
    @Test("Unrendered chapters are simply absent")
    func sparse() {
        let offsets: [UUID: CGFloat] = [c: -40]
        #expect(TranscriptChapterVisibility.current(headerOffsets: offsets, order: order) == c)
    }

    /// A header resting a hair below the edge still counts as reached, or the
    /// index flickers between two chapters as the scroll settles.
    @Test("A header within tolerance counts as reached")
    func tolerance() {
        #expect(TranscriptChapterVisibility.current(headerOffsets: [a: 8], order: order) == a)
        #expect(TranscriptChapterVisibility.current(headerOffsets: [a: 9], order: order) == a)
        #expect(
            TranscriptChapterVisibility.current(headerOffsets: [a: 9, b: 200], order: order) == a
        )
    }
}
