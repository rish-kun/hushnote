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
    /// Whether this paragraph opens a new five-minute stretch.
    ///
    /// Deliberately not `timestamp != nil`: a time is also re-anchored on every
    /// change of voice, and keying chapters on that gives a two-person
    /// conversation one chapter per turn -- an index with an entry for every
    /// reply indexes nothing.
    let opensChapter: Bool

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
            let opensChapter =
                marker(draft.start, rules) != previous.map { marker($0.start, rules) }
            let stamped = label != nil
                || opensChapter
                || draft.openingGap >= rules.timeShiftGap

            return TranscriptParagraph(
                id: draft.lines[0].id,
                speaker: draft.speaker,
                speakerLabel: label,
                timestamp: stamped ? draft.start : nil,
                start: draft.start,
                end: draft.end,
                runs: draft.runs,
                lines: draft.lines,
                opensChapter: opensChapter
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
    /// A name above the paragraph, because the voice changed.
    ///
    /// Apparatus that repeats stops being read, so a paragraph continuing the
    /// same voice draws no name at all.
    var showsSpeakerName: Bool { speakerLabel != nil }

    /// A rule and a chapter time above the paragraph, because a new stretch of
    /// the recording has begun. This is the beat the index points at, and it is
    /// rare -- roughly six times in a thirty-minute meeting.
    var opensSection: Bool { opensChapter }
}

/// A stretch of the meeting between two time markers: what the index points at.
///
/// Derived from paragraphs rather than from raw segments, so the sanitised text
/// is the only text it ever sees. There is no new path here from Whisper's
/// output to a rendered string.
struct TranscriptChapter: Identifiable, Equatable {
    /// The identity of the paragraph that opens the chapter -- never a
    /// position, for the same reason `TranscriptParagraph.id` is not one.
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    /// Distinct speakers heard in this stretch, in first-heard order.
    let speakers: [String]
    /// The opening words, already cleaned and already truncated.
    let opening: String
    let paragraphIDs: [UUID]
}

extension TranscriptGrouping {
    /// How much of a chapter's first paragraph the index shows.
    static let chapterOpeningLimit = 64

    /// The chapters of a transcript, in order.
    ///
    /// - Parameter includesOpenChapter: pass `false` while recording. The
    ///   chapter still accruing text would otherwise rewrite its own opening
    ///   words and speaker list on every buffer, reflowing an index the reader
    ///   is trying to steer by. Closed chapters never change, because grouping
    ///   only ever extends the last paragraph.
    nonisolated static func chapters(
        _ paragraphs: [TranscriptParagraph],
        includesOpenChapter: Bool = true
    ) -> [TranscriptChapter] {
        var chapters: [TranscriptChapter] = []
        var currentParagraphs: [TranscriptParagraph] = []

        func close() {
            guard let first = currentParagraphs.first else { return }
            var speakers: [String] = []
            for paragraph in currentParagraphs where !speakers.contains(paragraph.speaker) {
                speakers.append(paragraph.speaker)
            }
            chapters.append(
                TranscriptChapter(
                    id: first.id,
                    start: first.start,
                    end: currentParagraphs.map(\.end).max() ?? first.end,
                    speakers: speakers,
                    opening: opening(of: first.text),
                    paragraphIDs: currentParagraphs.map(\.id)
                )
            )
            currentParagraphs = []
        }

        for paragraph in paragraphs {
            // A chapter opens exactly where the reading flow already draws a
            // rule, so the index and the page agree about where the beats are.
            if paragraph.opensSection { close() }
            currentParagraphs.append(paragraph)
        }
        close()

        if !includesOpenChapter, !chapters.isEmpty {
            chapters.removeLast()
        }
        return chapters
    }

    /// Truncates on a word boundary, so the index never cuts mid-word.
    nonisolated static func opening(
        of text: String,
        limit: Int = TranscriptGrouping.chapterOpeningLimit
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let clipped = trimmed.prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " ") else {
            return String(clipped) + "\u{2026}"
        }
        return clipped[clipped.startIndex..<lastSpace]
            .trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

extension TranscriptGrouping {
    /// The paragraph a given transcript segment was folded into.
    ///
    /// A paragraph's identity is its *opening* line's, so a segment in the
    /// middle of one has to be searched for across `lines`. Addressed by
    /// identity, never by index. Returns nil when the transcript does not hold
    /// that segment -- it may not have loaded yet, or the segment may have
    /// cleaned away to nothing and been dropped.
    nonisolated static func paragraphID(
        containingSegmentID segmentID: String,
        in paragraphs: [TranscriptParagraph]
    ) -> UUID? {
        paragraphs.first { $0.lines.contains { $0.segmentID == segmentID } }?.id
    }
}

/// Which chapter the reader is in, from the headers currently on screen.
///
/// `LazyVStack` only renders what is visible, so the map is small and sparse --
/// the answer has to come from the headers that reported, not from a scan of
/// every chapter.
enum TranscriptChapterVisibility {
    /// - Parameters:
    ///   - headerOffsets: each reporting header's offset from the top of the
    ///     scroll viewport. Negative means it has scrolled past the top.
    ///   - order: every chapter id, in document order.
    /// - Returns: the last header to have passed the top edge, or the first one
    ///   still below it when none has.
    nonisolated static func current(
        headerOffsets: [UUID: CGFloat],
        order: [UUID],
        tolerance: CGFloat = 8
    ) -> UUID? {
        guard !order.isEmpty else { return nil }

        var passed: UUID?
        var firstReporting: UUID?

        for id in order {
            guard let offset = headerOffsets[id] else { continue }
            if firstReporting == nil { firstReporting = id }
            if offset <= tolerance { passed = id }
        }
        return passed ?? firstReporting
    }
}

/// Where the reading column, its apparatus margin, and the index sit.
///
/// The workspace's reading spread, shared by the transcript and the notes page
/// so that switching between those tabs never moves the text sideways. Ask
/// composes the same measure and rail gap by hand.
///
/// Container-aware rather than tier-aware: the margin appears as soon as there
/// is room for it, which happens partway through the regular tier rather than
/// at one of `AdaptiveLayoutPolicy`'s boundaries.
struct TranscriptLayout: Equatable, Sendable {
    var gutter: CGFloat
    /// Zero when the container cannot host an apparatus column.
    var marginWidth: CGFloat
    var marginGap: CGFloat
    var measure: CGFloat
    var showsIndexRail: Bool
    var railWidth: CGFloat
    var railGap: CGFloat

    static let margin: CGFloat = 64
    static let marginGap: CGFloat = 24
    static let rail: CGFloat = 232
    /// Matches the gap `AskMeetingView` puts between its column and its rail,
    /// because the two are the same spread seen on two tabs.
    static let railGap: CGFloat = 44

    var hasMargin: Bool { marginWidth > 0 }

    /// The reading column plus whatever apparatus hangs beside it.
    var columnWidth: CGFloat {
        hasMargin ? marginWidth + marginGap + measure : measure
    }

    /// How wide the reading pane may grow, or `nil` for "take what is left".
    ///
    /// Finite exactly when an index sits beside the prose. Letting the reader
    /// expand while the index was pinned to the trailing edge put roughly 470
    /// points of nothing between a paragraph and the entry that indexes it,
    /// and stranded the reader's own scroll indicator in the middle of the
    /// page. The surplus belongs outside the spread, as page margin.
    var readerWidth: CGFloat? {
        showsIndexRail ? gutter + columnWidth + railGap : nil
    }

    nonisolated static func resolve(availableWidth: CGFloat) -> Self {
        let policy = AdaptiveLayoutPolicy.tier(for: availableWidth)
        let gutter = policy.gutter
        let measure = AdaptiveLayoutPolicy.readingMeasure

        let marginCost = margin + marginGap
        let content = availableWidth - 2 * gutter
        let fitsMargin = content >= marginCost + measure
        let fitsRail = policy.showsRightRail
            && content >= marginCost + measure + railGap + rail

        return TranscriptLayout(
            gutter: gutter,
            marginWidth: fitsMargin ? margin : 0,
            marginGap: marginGap,
            // At compact the measure is a ceiling, not a width: the column
            // fills a narrow window rather than leaving a ragged right edge.
            measure: policy == .compact ? .infinity : measure,
            showsIndexRail: fitsRail,
            railWidth: rail,
            railGap: railGap
        )
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
