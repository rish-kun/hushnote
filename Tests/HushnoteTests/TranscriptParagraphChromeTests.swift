import Foundation
import Testing
@testable import Hushnote

/// The transcript reads as prose, so everything that is not prose has to earn
/// its place: a name only when the voice changes, a time only when the reader
/// could have lost their place, and nothing at all the rest of the time.
///
/// Correcting the transcript is still per segment. A paragraph is opened for
/// correction by identity, and that identity has to survive -- or fail to
/// survive -- a transcript being replaced underneath it, which is exactly what
/// the final pass does.
@Suite("Transcript paragraph chrome")
struct TranscriptParagraphChromeTests {
    // MARK: - Apparatus

    @Test("A paragraph that opens a new voice names it")
    func openingParagraphNamesItsVoice() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "Are we agreed?"),
            Self.line(ordinal: 1, speaker: "Grace", start: 2, end: 4, text: "Agreed."),
        ])

        #expect(paragraphs.filter(\.showsSpeakerName).count == 2)
    }

    /// The case the whole redesign is for: a paragraph that merely continues the
    /// same person in the same minute is prose and nothing else.
    @Test("A continuing paragraph draws no apparatus at all")
    func continuingParagraphDrawsNothing() throws {
        let sentence = "This is a sentence of some length that carries the point along."
        let paragraphs = TranscriptGrouping.paragraphs(
            (0..<12).map { ordinal in
                Self.line(
                    ordinal: ordinal,
                    speaker: "Ada",
                    start: Double(ordinal) * 4,
                    end: Double(ordinal) * 4 + 4,
                    text: sentence
                )
            }
        )

        let continuation = try #require(paragraphs.dropFirst().first)
        #expect(continuation.speakerLabel == nil)
        #expect(continuation.timestamp == nil)
        #expect(continuation.showsSpeakerName == false)
        #expect(continuation.opensSection == false)
    }

    /// A leaking segment used to warn on its own row, and then to force a whole
    /// header onto a paragraph that had nothing else to say. The warning now
    /// lives in the apparatus margin, so it no longer drags a speaker name and
    /// a rule along with it -- but it must still be reported.
    @Test("A leak warning is carried without forcing a header")
    func leakWarningIsCarriedInTheMargin() throws {
        let sentence = "This is a sentence of some length that carries the point along."
        var lines = (0..<12).map { ordinal in
            Self.line(
                ordinal: ordinal,
                speaker: "Ada",
                start: Double(ordinal) * 4,
                end: Double(ordinal) * 4 + 4,
                text: sentence
            )
        }
        lines[10].possibleLeakage = true

        let paragraphs = TranscriptGrouping.paragraphs(lines)
        let continuation = try #require(paragraphs.dropFirst().first)

        #expect(continuation.speakerLabel == nil)
        #expect(continuation.timestamp == nil)
        #expect(continuation.possibleLeakage)
        #expect(continuation.showsSpeakerName == false)
        #expect(continuation.opensSection == false)
    }

    // MARK: - Which paragraph is open for correction

    @Test("A paragraph opened for correction stays open")
    func openParagraphStaysOpen() throws {
        let paragraphs = TranscriptGrouping.paragraphs(Self.twoVoices())
        let target = try #require(paragraphs.last?.id)

        #expect(
            TranscriptEditingFocus.surviving(target, isEditable: true, in: paragraphs) == target
        )
    }

    /// The final pass replaces every segment identifier, so a paragraph the user
    /// had opened for correction is not in the new transcript at all. The editor
    /// has to close rather than hold an identity nothing answers to -- the same
    /// mistake, in a different currency, as reading a transcript by index.
    @Test("A replacement closes an editor whose paragraph no longer exists")
    func replacementClosesTheEditor() throws {
        let before = TranscriptGrouping.paragraphs(Self.twoVoices())
        let after = TranscriptGrouping.paragraphs(Self.twoVoices(pass: .final))
        let target = try #require(before.last?.id)

        #expect(Set(before.map(\.id)).isDisjoint(with: Set(after.map(\.id))))
        #expect(TranscriptEditingFocus.surviving(target, isEditable: true, in: after) == nil)
    }

    /// Recording again makes the transcript the model's rather than the user's:
    /// `TranscriptEditPolicy.allowsEditing` goes false, and an editor left open
    /// from before must not survive it.
    @Test("A transcript that may not be edited has nothing open")
    func uneditableTranscriptClosesTheEditor() throws {
        let paragraphs = TranscriptGrouping.paragraphs(Self.twoVoices())
        let target = try #require(paragraphs.last?.id)

        #expect(TranscriptEditingFocus.surviving(target, isEditable: false, in: paragraphs) == nil)
        #expect(TranscriptEditingFocus.surviving(nil, isEditable: true, in: paragraphs) == nil)
    }

    // MARK: - Fixtures

    private static let meetingID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    private static func twoVoices(pass: TranscriptIdentifier.Pass = .live) -> [TranscriptLineItem] {
        [
            line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "Are we agreed?", pass: pass),
            line(ordinal: 1, speaker: "Grace", start: 2, end: 4, text: "Agreed.", pass: pass),
        ]
    }

    private static func line(
        ordinal: Int,
        speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        pass: TranscriptIdentifier.Pass = .final
    ) -> TranscriptLineItem {
        let identity = pass == .live ? "1" : "2"
        return TranscriptLineItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(identity)\(String(format: "%011d", ordinal))")!,
            segmentID: TranscriptIdentifier.segment(
                meetingID: meetingID,
                source: .system,
                pass: pass,
                ordinal: ordinal
            ),
            speaker: speaker,
            start: start,
            end: end,
            text: text,
            isProvisional: pass == .live
        )
    }
}
