import Foundation
import Testing
@testable import Hushnote

/// The transcript pane rendered one row per ASR segment: a timestamp column, a
/// speaker column, and a fragment like "having a". Whisper emits a segment every
/// few seconds, so an hour of meeting became a thousand stubby rows and read
/// like a log file rather than like something a person wrote down.
///
/// Grouping is the whole design, and it is a pure function so it can be held to
/// its rules here rather than squinted at on screen.
@Suite("Transcript grouping")
struct TranscriptGroupingTests {
    // MARK: - Degenerate transcripts

    @Test("An empty transcript produces no paragraphs")
    func emptyTranscript() {
        #expect(TranscriptGrouping.paragraphs([]).isEmpty)
    }

    @Test("A single segment is a paragraph that names its speaker and its time")
    func singleSegment() throws {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 4, text: "We should ship on Friday.")
        ])

        let only = try #require(paragraphs.first)
        #expect(paragraphs.count == 1)
        #expect(only.text == "We should ship on Friday.")
        #expect(only.speakerLabel == "Ada")
        #expect(only.timestamp == 0)
        #expect(only.start == 0)
        #expect(only.end == 4)
    }

    /// A segment that is nothing but control tokens has no prose in it, and an
    /// empty paragraph is worse than no paragraph.
    @Test("A transcript of nothing but control tokens produces no paragraphs")
    func blankTranscript() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 1, text: "<|startoftranscript|><|en|>"),
            Self.line(ordinal: 1, speaker: "Ada", start: 1, end: 2, text: "   "),
        ])

        #expect(paragraphs.isEmpty)
    }

    // MARK: - What starts a new paragraph

    @Test("Consecutive segments from one speaker coalesce into one paragraph")
    func consecutiveSegmentsCoalesce() throws {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2.4, text: "So the thing is"),
            Self.line(ordinal: 1, speaker: "Ada", start: 2.4, end: 4.8, text: "having a"),
            Self.line(ordinal: 2, speaker: "Ada", start: 4.8, end: 7.2, text: "second pass helps."),
        ])

        let only = try #require(paragraphs.first)
        #expect(paragraphs.count == 1)
        #expect(only.text == "So the thing is having a second pass helps.")
        #expect(only.lines.count == 3)
        #expect(only.end == 7.2)
    }

    @Test("A speaker change starts a paragraph and names the new speaker")
    func speakerChangeBreaks() throws {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "Are we agreed?"),
            Self.line(ordinal: 1, speaker: "Grace", start: 2, end: 4, text: "Agreed."),
        ])

        #expect(paragraphs.count == 2)
        #expect(paragraphs.map(\.speakerLabel) == ["Ada", "Grace"])
        #expect(paragraphs.map(\.text) == ["Are we agreed?", "Agreed."])
        // A speaker change re-anchors the reader, so it carries a time too.
        #expect(paragraphs[1].timestamp == 2)
    }

    /// The label answers "who is talking now", so it compares against the
    /// paragraph above rather than against every speaker seen so far.
    @Test("A speaker returning is named again")
    func returningSpeakerIsNamedAgain() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "Are we agreed?"),
            Self.line(ordinal: 1, speaker: "Grace", start: 2, end: 4, text: "Agreed."),
            Self.line(ordinal: 2, speaker: "Ada", start: 4, end: 6, text: "Good."),
        ])

        #expect(paragraphs.map(\.speakerLabel) == ["Ada", "Grace", "Ada"])
    }

    @Test("A silence between segments starts a new paragraph")
    func silenceBreaks() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "Let me pull that up."),
            Self.line(ordinal: 1, speaker: "Ada", start: 8, end: 10, text: "Right, here it is."),
        ])

        #expect(paragraphs.map(\.text) == ["Let me pull that up.", "Right, here it is."])
        // Same speaker, so the name is not repeated.
        #expect(paragraphs[1].speakerLabel == nil)
    }

    @Test("A breath between segments does not start a new paragraph")
    func shortGapDoesNotBreak() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "Let me pull that up."),
            Self.line(ordinal: 1, speaker: "Ada", start: 3, end: 5, text: "Right, here it is."),
        ])

        #expect(paragraphs.count == 1)
    }

    /// A pause long enough to make the last timestamp stale re-anchors the
    /// reader in time, even though nobody else has spoken.
    @Test("A long pause re-anchors the timestamp; a short one does not")
    func longPauseCarriesATimestamp() {
        let brief = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "One moment."),
            Self.line(ordinal: 1, speaker: "Ada", start: 8, end: 10, text: "Here it is."),
        ])
        #expect(brief[1].timestamp == nil)

        let long = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "One moment."),
            Self.line(ordinal: 1, speaker: "Ada", start: 75, end: 77, text: "Here it is."),
        ])
        #expect(long[1].timestamp == 75)
    }

    // MARK: - Length

    /// An unbroken block is hard to read however well punctuated it is, so a
    /// paragraph past its comfortable length ends at the next sentence.
    @Test("A long run splits at a sentence, not mid-thought")
    func longRunSplitsAtASentence() throws {
        let sentence = "This is a sentence of some length that carries the point along."
        let lines = (0..<12).map { ordinal in
            Self.line(
                ordinal: ordinal,
                speaker: "Ada",
                start: Double(ordinal) * 4,
                end: Double(ordinal) * 4 + 4,
                text: sentence
            )
        }

        let paragraphs = TranscriptGrouping.paragraphs(lines)

        #expect(paragraphs.count > 1)
        for paragraph in paragraphs {
            #expect(paragraph.text.hasSuffix("."))
            #expect(paragraph.text.count <= TranscriptGrouping.Rules.default.hardLimit)
        }
        // A continuation of the same speaker in the same minute is pure prose:
        // no name, no time, nothing but the paragraph break itself.
        #expect(paragraphs[1].speakerLabel == nil)
        #expect(paragraphs[1].timestamp == nil)
        // Nothing is lost or duplicated by the split.
        #expect(paragraphs.flatMap(\.lines).map(\.segmentID) == lines.map(\.segmentID))
    }

    /// Speech with no sentence punctuation in it at all must still be broken up,
    /// and must still be gathered up: forty segments are a handful of
    /// paragraphs, not forty of them.
    @Test("An unpunctuated run is broken at the hard limit and nowhere sooner")
    func unpunctuatedRunIsBrokenAnyway() throws {
        let lines = (0..<40).map { ordinal in
            Self.line(
                ordinal: ordinal,
                speaker: "Ada",
                start: Double(ordinal) * 2,
                end: Double(ordinal) * 2 + 2,
                text: "and then we kept going and going"
            )
        }

        let paragraphs = TranscriptGrouping.paragraphs(lines)
        let rules = TranscriptGrouping.Rules.default

        #expect(paragraphs.count > 1)
        #expect(paragraphs.count <= 3)
        for paragraph in paragraphs {
            #expect(paragraph.text.count <= rules.hardLimit)
        }
        // Everything but the last paragraph is full: the split happened because
        // the block was too long to read, not for any other reason.
        for paragraph in paragraphs.dropLast() {
            #expect(paragraph.text.count > rules.softLimit)
        }
    }

    // MARK: - The five-minute marker

    /// Twelve minutes of one person talking. The reader still needs to be able
    /// to find where they are, and needs it about three times -- not once per
    /// paragraph and certainly not once per segment.
    ///
    /// The marker labels a paragraph; it does not cut one. Paragraphs are
    /// already bounded by length, so the first paragraph to open inside a new
    /// five-minute stretch is never far from the line itself, and the time shown
    /// is always a real segment start rather than a rounded one.
    @Test("A timestamp appears about once per five minutes, and not more often")
    func fiveMinuteMarkers() {
        let lines = (0..<144).map { ordinal in
            Self.line(
                ordinal: ordinal,
                speaker: "Ada",
                start: Double(ordinal) * 5,
                end: Double(ordinal) * 5 + 5,
                text: "and then we kept going and going"
            )
        }

        let paragraphs = TranscriptGrouping.paragraphs(lines)
        let stamped = paragraphs.compactMap(\.timestamp)

        #expect(stamped.count == 3)
        #expect(stamped.map { Int($0 / 300) } == [0, 1, 2])
        #expect(stamped[0] == 0)
        // The name is not repeated for twelve minutes of one voice.
        #expect(paragraphs.compactMap(\.speakerLabel) == ["Ada"])
        // The marker is worth having only because there is much more prose than
        // there are markers.
        #expect(paragraphs.count > stamped.count)
        // And it does lag the line it stands for -- by less than one paragraph.
        #expect(stamped[1] < 300 + TranscriptGrouping.Rules.default.markerInterval)
    }

    /// The clock never cuts a sentence in half: crossing the five-minute line
    /// mid-thought labels nothing and breaks nothing.
    @Test("A paragraph straddling a marker is left whole")
    func straddlingParagraphIsLeftWhole() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 296, end: 299, text: "Coming up on the hour"),
            Self.line(ordinal: 1, speaker: "Ada", start: 299, end: 302, text: "and past it now."),
            Self.line(ordinal: 2, speaker: "Ada", start: 302, end: 305, text: "Still the same thought."),
        ])

        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].timestamp == 296)
        #expect(paragraphs[0].text == "Coming up on the hour and past it now. Still the same thought.")
    }

    // MARK: - Speakers the pipeline could not name

    /// `AppCoordinator.lineItem` falls back to "Speaker" when diarization has no
    /// name, so an undiarized meeting is one speaker throughout: it is named
    /// once and then never again.
    @Test("Segments with no speaker name group as one voice")
    func unnamedSpeakerGroups() {
        let lines = (0..<4).map { ordinal in
            Self.line(
                ordinal: ordinal,
                speaker: "Speaker",
                start: Double(ordinal) * 3,
                end: Double(ordinal) * 3 + 3,
                text: "one more clause"
            )
        }

        let paragraphs = TranscriptGrouping.paragraphs(lines)

        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].speakerLabel == "Speaker")
        #expect(paragraphs[0].text == "one more clause one more clause one more clause one more clause")
    }

    // MARK: - Joining

    @Test("Joined segments are separated by exactly one space")
    func joinSpacing() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "  So the thing is  "),
            Self.line(ordinal: 1, speaker: "Ada", start: 2, end: 4, text: "\nhaving a\n"),
            Self.line(ordinal: 2, speaker: "Ada", start: 4, end: 6, text: "second pass."),
        ])

        #expect(paragraphs[0].text == "So the thing is having a second pass.")
    }

    /// Every guard upstream of the view can be out of date -- a meeting captured
    /// before `skipSpecialTokens` landed is read back from a database this
    /// launch may not have migrated -- so the tokens are stripped here too, and
    /// stripping must not disturb the joins around it.
    @Test("Control tokens are stripped after joining, without disturbing the spacing")
    func controlTokensAreStrippedFromTheJoin() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(
                ordinal: 0,
                speaker: "Ada",
                start: 0,
                end: 2,
                text: "<|startoftranscript|><|en|><|transcribe|><|0.00|> Oh, whoever is done.<|1.16|>"
            ),
            Self.line(ordinal: 1, speaker: "Ada", start: 2, end: 4, text: "<|1.00|> When it was the...<|2.00|>"),
            Self.line(ordinal: 2, speaker: "Ada", start: 4, end: 6, text: "<|4.24|> having a<|4.70|><|endoftext|>"),
        ])

        #expect(paragraphs[0].text == "Oh, whoever is done. When it was the... having a")
        #expect(paragraphs[0].text.contains("<|") == false)
    }

    /// A segment that cleans away to nothing must not leave its space behind.
    @Test("An empty segment does not leave a doubled space in the paragraph")
    func emptySegmentLeavesNoGap() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "We should ship"),
            Self.line(ordinal: 1, speaker: "Ada", start: 2, end: 3, text: "<|2.00|>"),
            Self.line(ordinal: 2, speaker: "Ada", start: 3, end: 5, text: "on Friday."),
        ])

        #expect(paragraphs[0].text == "We should ship on Friday.")
        #expect(paragraphs[0].text.contains("  ") == false)
        // The blank segment is not offered for correction either: there is
        // nothing on screen to point at.
        #expect(paragraphs[0].runs.count == 2)
    }

    // MARK: - What the view needs back

    /// Editing is still per segment: the paragraph carries the lines it was
    /// built from, with their segment identifiers intact, so a correction is
    /// written back to the one segment it belongs to rather than smeared across
    /// the paragraph.
    @Test("Every line survives grouping in exactly one paragraph")
    func linesSurviveGrouping() {
        let lines = Self.conversation()
        let paragraphs = TranscriptGrouping.paragraphs(lines)

        #expect(paragraphs.flatMap(\.lines).map(\.segmentID) == lines.map(\.segmentID))
        #expect(paragraphs.count > 1)
    }

    /// A paragraph is identified by the line that opens it, which is a segment
    /// identity minted by `TranscriptIdentifier` -- never a position. The row
    /// crash that `9615daf` fixed came from resolving a transcript entry by
    /// index while the array was being replaced underneath it.
    @Test("A paragraph is identified by the line that opens it")
    func paragraphIdentityComesFromItsFirstLine() {
        let lines = Self.conversation()
        let paragraphs = TranscriptGrouping.paragraphs(lines)

        for paragraph in paragraphs {
            #expect(paragraph.id == paragraph.lines.first?.id)
        }
    }

    /// The live pane re-groups on every delta. Appending a segment must leave
    /// every settled paragraph byte-identical, so SwiftUI rebuilds the last
    /// paragraph and nothing else.
    @Test("A segment arriving live only disturbs the paragraph it joins")
    func liveAppendDisturbsOnlyTheLastParagraph() {
        let settled = Self.conversation()
        let before = TranscriptGrouping.paragraphs(settled)

        let arrived = settled + [
            Self.line(
                ordinal: settled.count,
                speaker: settled[settled.count - 1].speaker,
                start: settled[settled.count - 1].end,
                end: settled[settled.count - 1].end + 2,
                text: "and one more clause.",
                isProvisional: true
            )
        ]
        let after = TranscriptGrouping.paragraphs(arrived)

        #expect(after.count == before.count)
        #expect(Array(after.dropLast()) == Array(before.dropLast()))
        #expect(after.last != before.last)
    }

    /// Live text is provisional and is drawn as such, so the paragraph keeps the
    /// distinction per segment rather than flattening it into one string.
    @Test("A paragraph keeps provisional text distinguishable inside it")
    func provisionalRunsStayMarked() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "We should ship"),
            Self.line(ordinal: 1, speaker: "Ada", start: 2, end: 4, text: "on Friday.", isProvisional: true),
        ])

        #expect(paragraphs[0].runs.map(\.isProvisional) == [false, true])
        #expect(paragraphs[0].isProvisional)
        #expect(TranscriptGrouping.paragraphs([Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 1, text: "Hi.")])[0].isProvisional == false)
    }

    /// The leakage warning belonged to a row; it now belongs to the paragraph
    /// that row was folded into, so it is still shown exactly once.
    @Test("A leaking segment marks the paragraph it sits in")
    func leakageRaisesToTheParagraph() {
        let paragraphs = TranscriptGrouping.paragraphs([
            Self.line(ordinal: 0, speaker: "Ada", start: 0, end: 2, text: "We should ship"),
            Self.line(ordinal: 1, speaker: "Ada", start: 2, end: 4, text: "on Friday.", possibleLeakage: true),
        ])

        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].possibleLeakage)
    }

    // MARK: - Fixtures

    private static let meetingID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    /// Two voices, a pause, and a run long enough to split.
    private static func conversation() -> [TranscriptLineItem] {
        var lines: [TranscriptLineItem] = []
        var clock = 0.0
        for (index, speaker) in ["Ada", "Grace", "Ada"].enumerated() {
            for _ in 0..<6 {
                lines.append(
                    line(
                        ordinal: lines.count,
                        speaker: speaker,
                        start: clock,
                        end: clock + 3,
                        text: "This is a sentence of some length that carries the point along."
                    )
                )
                clock += 3
            }
            clock += Double(index) * 10
        }
        return lines
    }

    private static func line(
        ordinal: Int,
        speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isProvisional: Bool = false,
        possibleLeakage: Bool = false
    ) -> TranscriptLineItem {
        let segmentID = TranscriptIdentifier.segment(
            meetingID: meetingID,
            source: .system,
            pass: .final,
            ordinal: ordinal
        )
        return TranscriptLineItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", ordinal))")!,
            segmentID: segmentID,
            speaker: speaker,
            start: start,
            end: end,
            text: text,
            isProvisional: isProvisional,
            possibleLeakage: possibleLeakage
        )
    }
}
