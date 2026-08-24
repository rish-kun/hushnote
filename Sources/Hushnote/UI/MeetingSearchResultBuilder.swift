import Foundation

/// One meeting that answered the query, and the moments inside it that did.
struct MeetingSearchResult: Identifiable, Equatable, Sendable {
    var id: UUID { meeting.id }
    let meeting: MeetingListItem
    /// Empty when the meeting matched on its title alone.
    let moments: [MeetingSearchMoment]
    /// Matches beyond the ones shown, for the "more in this meeting" line.
    let additionalMomentCount: Int
}

/// A single matched line of transcript: what was said, by whom, and when.
struct MeetingSearchMoment: Identifiable, Equatable, Sendable {
    /// The transcript segment's own identity, which is what the transcript pane
    /// resolves back to a paragraph. Never a position.
    let id: String
    let start: TimeInterval
    let speaker: String?
    let text: String
}

/// Turns ranked segment matches into the rows the palette draws.
///
/// A flat list of moments drowns in one talkative meeting; a flat list of
/// meetings loses the moment the user is actually looking for. So a row is a
/// meeting carrying the best few moments inside it.
///
/// Pure, because `AppCoordinator` cannot be constructed in a test: its
/// initializer requires the real database.
enum MeetingSearchResultBuilder {
    static let momentsPerMeeting = 2
    static let meetingLimit = 12

    /// - Parameters:
    ///   - segmentMatches: already bm25-ordered, exactly as `searchSegments`
    ///     returns them. First appearance decides a meeting's rank.
    ///   - meetings: the resident meeting list, for titles and metadata. A
    ///     match whose meeting is not in it -- deleted, or filtered out -- is
    ///     dropped rather than rendered as a row pointing nowhere.
    nonisolated static func results(
        segmentMatches: [TranscriptSegment],
        meetings: [MeetingListItem],
        titleMatches: [MeetingListItem] = [],
        momentsPerMeeting: Int = MeetingSearchResultBuilder.momentsPerMeeting,
        limit: Int = MeetingSearchResultBuilder.meetingLimit
    ) -> [MeetingSearchResult] {
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var order: [UUID] = []
        var collected: [UUID: [MeetingSearchMoment]] = [:]
        var totals: [UUID: Int] = [:]

        for segment in segmentMatches {
            guard byID[segment.meetingID] != nil else { continue }
            // The same three-layer rule as everywhere else: this text is about
            // to be rendered, so it is cleaned before it is measured or shown.
            let text = WhisperSpecialToken.cleanedSegmentText(segment.text)
            guard !text.isEmpty else { continue }

            if collected[segment.meetingID] == nil {
                order.append(segment.meetingID)
                collected[segment.meetingID] = []
            }
            totals[segment.meetingID, default: 0] += 1

            guard collected[segment.meetingID]!.count < momentsPerMeeting else { continue }
            collected[segment.meetingID]?.append(
                MeetingSearchMoment(
                    id: segment.id,
                    start: TimeInterval(segment.startMilliseconds) / 1_000,
                    speaker: segment.speakerName,
                    text: text
                )
            )
        }

        var results = order.compactMap { id -> MeetingSearchResult? in
            guard let meeting = byID[id], let moments = collected[id], !moments.isEmpty else {
                return nil
            }
            return MeetingSearchResult(
                meeting: meeting,
                moments: moments,
                additionalMomentCount: max(0, (totals[id] ?? 0) - moments.count)
            )
        }

        // A meeting whose title matched but whose transcript did not is still a
        // real answer -- and often the one the user meant. It ranks after the
        // spoken matches, because a phrase actually said in a meeting is the
        // stronger signal.
        let alreadyListed = Set(results.map(\.id))
        for meeting in titleMatches where !alreadyListed.contains(meeting.id) {
            results.append(
                MeetingSearchResult(meeting: meeting, moments: [], additionalMomentCount: 0)
            )
        }

        return Array(results.prefix(limit))
    }
}
