import Foundation

/// One identity-addressed match in text that still belongs to the live pass.
///
/// Live find deliberately never reaches into persistence: final transcript
/// search has its own database-backed route, while this feature answers the
/// much smaller question "what was just said while I was listening?"
struct LiveTranscriptMatch: Equatable, Sendable {
    let segmentID: String
}

/// Pure matching and navigation for find-within-live-transcript.
///
/// Results carry segment identities rather than array positions because the
/// streaming decoder replaces `AppViewState.transcript` wholesale as its
/// hypothesis changes.
enum LiveTranscriptFindPolicy {
    nonisolated static func matches(
        query: String,
        in lines: [TranscriptLineItem]
    ) -> [LiveTranscriptMatch] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return [] }

        return lines.compactMap { line in
            guard line.isProvisional else { return nil }
            let visibleText = WhisperSpecialToken.cleanedSegmentText(line.text)
            guard normalized(visibleText).contains(needle) else { return nil }
            return LiveTranscriptMatch(segmentID: line.segmentID)
        }
    }

    /// Keeps the selected identity when a streaming update replaces the
    /// result list; otherwise starts at the first match.
    nonisolated static func resolvedSelection(
        currentSegmentID: String?,
        in matches: [LiveTranscriptMatch]
    ) -> String? {
        guard !matches.isEmpty else { return nil }
        if let currentSegmentID,
           matches.contains(where: { $0.segmentID == currentSegmentID }) {
            return currentSegmentID
        }
        return matches[0].segmentID
    }

    nonisolated static func adjacentSelection(
        from currentSegmentID: String?,
        in matches: [LiveTranscriptMatch],
        direction: Direction
    ) -> String? {
        guard !matches.isEmpty else { return nil }
        guard let currentSegmentID,
              let index = matches.firstIndex(where: { $0.segmentID == currentSegmentID }) else {
            return direction == .next ? matches[0].segmentID : matches[matches.count - 1].segmentID
        }

        switch direction {
        case .next:
            return matches[(index + 1) % matches.count].segmentID
        case .previous:
            return matches[(index - 1 + matches.count) % matches.count].segmentID
        }
    }

    nonisolated static func positionText(
        selectedSegmentID: String?,
        in matches: [LiveTranscriptMatch]
    ) -> String {
        guard let selectedSegmentID,
              let index = matches.firstIndex(where: { $0.segmentID == selectedSegmentID }) else {
            return "No matches"
        }
        return "\(index + 1) of \(matches.count)"
    }

    enum Direction: Sendable {
        case previous
        case next
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
