import Foundation

/// One segment's worth of prose inside a paragraph.
///
/// The paragraph is one block of text on screen, but it is drawn from these so
/// that live text arriving mid-paragraph can still be shown as provisional
/// without splitting the paragraph in two.
struct TranscriptProseRun: Identifiable, Equatable, Sendable {
    /// The identity of the line this run came from.
    let id: UUID
    /// Cleaned, trimmed segment text. Never empty.
    let text: String
    let isProvisional: Bool
}

/// A run of consecutive transcript lines that reads as one paragraph.
///
/// `lines` is kept beside `runs` because correcting the transcript is still a
/// per-segment act: the paragraph is what the reader sees, the segment is what
/// gets written back. See `TranscriptView`.
struct TranscriptParagraph: Identifiable, Equatable {
    /// The identity of the line that opens the paragraph — never a position.
    /// The row crash `9615daf` fixed came from addressing a transcript entry by
    /// index while the array underneath it was being replaced.
    let id: UUID
    let speaker: String
    /// The speaker's name, or `nil` when the paragraph above was the same voice
    /// and the name would only be repetition.
    let speakerLabel: String?
    /// The time to show above the paragraph, or `nil` when the reader has not
    /// lost their place since the last one.
    let timestamp: TimeInterval?
    let start: TimeInterval
    let end: TimeInterval
    let runs: [TranscriptProseRun]
    let lines: [TranscriptLineItem]

    /// The paragraph as one string: the reading text, the accessibility label,
    /// and what the grouping rules measure themselves against.
    var text: String { runs.map(\.text).joined(separator: " ") }
    var isProvisional: Bool { runs.contains(where: \.isProvisional) }
    var possibleLeakage: Bool { lines.contains(where: \.possibleLeakage) }
}

/// Turns a list of ASR segments into paragraphs a person would read.
///
/// Whisper emits a segment every few seconds, and the pane used to render one
/// row per segment: a timestamp column, a speaker column, and a fragment like
/// "having a". An hour of meeting was a thousand of those, and it read like a
/// log file. Consecutive segments therefore coalesce, and a paragraph begins
/// only where something changed that a reader would notice.
///
/// This is deliberately a pure function with no view in it. It is the whole
/// design, so it is the part that is tested.
enum TranscriptGrouping {
    /// The thresholds, gathered so they can be read as a set and varied in
    /// tests. Every one of them is a claim about reading, not about audio.
    struct Rules: Sendable {
        /// A silence long enough to be a beat rather than a breath. Below this,
        /// a pause is just how someone talks and must not fragment the prose.
        var paragraphGap: TimeInterval
        /// A silence long enough that the last time shown has gone stale, so
        /// the paragraph after it is worth re-anchoring even though the same
        /// person is still speaking.
        var timeShiftGap: TimeInterval
        /// How often the reader should be able to find a time to steer by.
        var markerInterval: TimeInterval
        /// The length past which a paragraph is looking for a way to end. It
        /// only ends at a sentence, so the real paragraphs run somewhat longer.
        var softLimit: Int
        /// The length past which an unbroken block is unreadable whatever the
        /// punctuation is doing. Speech without a full stop in it — which is
        /// most conversational speech — is broken here.
        var hardLimit: Int

        static let `default` = Rules(
            paragraphGap: 5,
            timeShiftGap: 45,
            markerInterval: 300,
            softLimit: 420,
            hardLimit: 900
        )
    }

    /// - Parameter lines: the transcript in order.
    /// - Returns: the paragraphs to draw, in order. Segments that clean away to
    ///   nothing — a row that was only Whisper control tokens — are dropped
    ///   rather than becoming an empty paragraph or a doubled space inside one.
    nonisolated static func paragraphs(
        _ lines: [TranscriptLineItem],
        rules: Rules = .default
    ) -> [TranscriptParagraph] {
        var drafts: [Draft] = []

        for line in lines {
            // The last line of defence against Whisper's control vocabulary,
            // applied before anything is measured or joined so that the length
            // rules count prose and the joins keep single spaces.
            let text = WhisperSpecialToken.cleanedSegmentText(line.text)
            guard !text.isEmpty else { continue }

            if var draft = drafts.last, !breaks(draft, line: line, text: text, rules: rules) {
                draft.append(line, text: text)
                drafts[drafts.count - 1] = draft
            } else {
                let gap = drafts.last.map { line.start - $0.end } ?? .infinity
                drafts.append(Draft(line: line, text: text, openingGap: gap))
            }
        }

        return drafts.enumerated().map { index, draft in
            let previous = index > 0 ? drafts[index - 1] : nil
            // Naming answers "who is speaking now", so it compares against the
            // paragraph above rather than against everyone seen so far.
            let label = draft.speaker == previous?.speaker ? nil : draft.speaker
            let stamped = label != nil
                || marker(draft.start, rules) != previous.map { marker($0.start, rules) }
                || draft.openingGap >= rules.timeShiftGap

            return TranscriptParagraph(
                id: draft.lines[0].id,
                speaker: draft.speaker,
                speakerLabel: label,
                timestamp: stamped ? draft.start : nil,
                start: draft.start,
                end: draft.end,
                runs: draft.runs,
                lines: draft.lines
            )
        }
    }

    /// Whether `line` starts a new paragraph rather than continuing `draft`.
    ///
    /// The five-minute marker is not in here on purpose. Cutting at the clock
    /// would break a sentence in half at an arbitrary moment; because a
    /// paragraph is already bounded by `hardLimit`, the first paragraph to open
    /// inside a new five-minute stretch is never far behind the line it stands
    /// for, and the time it shows is a real segment start rather than a rounded
    /// one. The marker labels a paragraph; it does not make one.
    private nonisolated static func breaks(
        _ draft: Draft,
        line: TranscriptLineItem,
        text: String,
        rules: Rules
    ) -> Bool {
        if line.speaker != draft.speaker { return true }
        if line.start - draft.end >= rules.paragraphGap { return true }
        if draft.length + 1 + text.count > rules.hardLimit { return true }
        // Past the comfortable length, the paragraph ends at the first sentence
        // that offers itself — so a break lands between thoughts rather than
        // inside one.
        return draft.length >= rules.softLimit && draft.endsSentence
    }

    private nonisolated static func marker(_ seconds: TimeInterval, _ rules: Rules) -> Int {
        guard rules.markerInterval > 0 else { return 0 }
        return Int(seconds / rules.markerInterval)
    }

    /// Whether text ends somewhere a paragraph could stop. Closing quotes and
    /// brackets sit outside the full stop and do not disqualify it.
    nonisolated static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, "\"')]}»”’".contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return ".!?…".contains(last)
    }

    /// A paragraph under construction. It carries its own running length and
    /// sentence state so the rules never re-join the text to ask about it.
    private struct Draft {
        var lines: [TranscriptLineItem]
        var runs: [TranscriptProseRun]
        var speaker: String
        var start: TimeInterval
        var end: TimeInterval
        var length: Int
        var endsSentence: Bool
        /// The silence this paragraph opened after, used to decide whether it
        /// needs a time of its own.
        var openingGap: TimeInterval

        init(line: TranscriptLineItem, text: String, openingGap: TimeInterval) {
            lines = [line]
            runs = [TranscriptProseRun(id: line.id, text: text, isProvisional: line.isProvisional)]
            speaker = line.speaker
            start = line.start
            end = line.end
            length = text.count
            endsSentence = TranscriptGrouping.endsSentence(text)
            self.openingGap = openingGap
        }

        mutating func append(_ line: TranscriptLineItem, text: String) {
            lines.append(line)
            runs.append(TranscriptProseRun(id: line.id, text: text, isProvisional: line.isProvisional))
            end = max(end, line.end)
            length += 1 + text.count
            endsSentence = TranscriptGrouping.endsSentence(text)
        }
    }
}

extension TranscriptParagraph {
    /// Whether anything but prose belongs above this paragraph.
    ///
    /// The header is apparatus, and apparatus that repeats stops being read.
    /// A paragraph that merely continues the same voice in the same stretch of
    /// the recording draws nothing at all: the break itself is the signal.
    var showsHeader: Bool {
        speakerLabel != nil || timestamp != nil || possibleLeakage
    }
}

/// Which paragraph, if any, is currently open for correction.
///
/// Editing a transcript is per segment, and a paragraph is opened to reveal the
/// segments inside it. The identity held while that is open is a paragraph's --
/// which is a segment identity, minted by `TranscriptIdentifier` -- so it stops
/// answering to anything the moment the transcript is replaced. Resolving it
/// against the paragraphs actually on screen is what keeps an editor from
/// outliving the text it was opened over; the row crash `9615daf` fixed was the
/// same mistake made with an array index.
enum TranscriptEditingFocus {
    nonisolated static func surviving(
        _ editing: UUID?,
        isEditable: Bool,
        in paragraphs: [TranscriptParagraph]
    ) -> UUID? {
        guard isEditable, let editing else { return nil }
        return paragraphs.contains(where: { $0.id == editing }) ? editing : nil
    }
}
