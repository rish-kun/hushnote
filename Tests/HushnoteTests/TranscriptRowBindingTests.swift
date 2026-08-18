import Foundation
import Testing
@testable import Hushnote

/// The transcript editor used to hand every `TextField` a per-element binding
/// out of `ForEach($state.transcript)`. Those bindings resolve by *position* in
/// the backing array, and `AppCoordinator` replaces `state.transcript` wholesale
/// when the final pass lands -- with freshly minted `-final-` identifiers and
/// usually fewer segments than the live pass produced. A field that was focused
/// when the replacement arrived made AppKit fire `controlTextDidEndEditing`,
/// SwiftUI read back through the stale position, and `Array._checkSubscript`
/// trapped: `EXC_BREAKPOINT` inside `Binding.readValue()`.
///
/// A trap cannot be caught, so the crash itself is not reproducible in-process.
/// What is testable is the seam that removes it: a row that owns its draft by
/// identity and never consults the array it came from.
@Suite("Transcript row binding")
struct TranscriptRowBindingTests {
    // MARK: - The shape of the replacement that crashed

    /// Every precondition the crash needed, taken from the two identifier
    /// passes `TranscriptIdentifier` mints and the segment counts they produce.
    @Test("The final pass replaces every row identity and shortens the transcript")
    func finalPassInvalidatesEveryRowPosition() {
        let live = Self.liveTranscript()
        let final = Self.finalTranscript()

        #expect(Set(live.map(\.id)).isDisjoint(with: Set(final.map(\.id))))
        #expect(final.count < live.count)
        // The row the user was typing in sat at a position the replacement no
        // longer has: an index-derived binding reads out of range here.
        #expect(Self.focusedPosition >= final.count)
    }

    // MARK: - Re-seeding an existing row

    @Test("An unfocused row adopts the model's new text")
    func unfocusedRowAdoptsIncomingText() {
        #expect(
            TranscriptRowText.reseededDraft(
                incoming: "we should ship on Friday",
                draft: "we should ship on",
                isFocused: false
            ) == "we should ship on Friday"
        )
    }

    /// Re-seeding under the insertion point would move the user's cursor to the
    /// end of a string they did not write. Focus decides ownership of the row,
    /// exactly as it decides ownership of a change in `TranscriptEditPolicy`.
    @Test("A focused row keeps what the user is typing")
    func focusedRowKeepsTheUsersDraft() {
        #expect(
            TranscriptRowText.reseededDraft(
                incoming: "we should ship on Friday",
                draft: "we should ship on Thurs",
                isFocused: true
            ) == nil
        )
    }

    /// A re-seed that changes nothing must not write to `@State` at all: the
    /// assignment would invalidate the row on every transcript revision.
    @Test("An unchanged line does not re-seed the row")
    func unchangedLineDoesNotReseed() {
        #expect(
            TranscriptRowText.reseededDraft(
                incoming: "we should ship on Friday",
                draft: "we should ship on Friday",
                isFocused: false
            ) == nil
        )
    }

    /// The regression `TranscriptEditPolicy.isHumanEdit` exists to prevent: a
    /// re-seed is the model writing, and must never be recorded as the user's
    /// correction. Re-seeding only ever happens while the row is unfocused, and
    /// an unfocused change is not a human edit.
    @Test("Re-seeding a row is never a human edit")
    func reseedIsNeverAHumanEdit() throws {
        let draft = "Oh, whoever is done."
        let incoming = "When it was the..."
        let reseeded = try #require(
            TranscriptRowText.reseededDraft(incoming: incoming, draft: draft, isFocused: false)
        )
        #expect(reseeded == "When it was the...")
        #expect(
            TranscriptEditPolicy.isHumanEdit(isFocused: false, from: draft, to: reseeded) == false
        )
    }

    // MARK: - Fixtures

    /// The row the crash report's `controlTextDidEndEditing` was ending.
    private static let focusedPosition = 3

    private static func liveTranscript() -> [TranscriptLineItem] {
        (0..<5).map { ordinal in
            line(pass: .live, ordinal: ordinal, text: "live line \(ordinal)", isProvisional: true)
        }
    }

    private static func finalTranscript() -> [TranscriptLineItem] {
        [
            "Oh, whoever is done.",
            "When it was the...",
        ].enumerated().map { ordinal, text in
            line(pass: .final, ordinal: ordinal, text: text, isProvisional: false)
        }
    }

    private static let meetingID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    /// `AppCoordinator.lineItem` derives the row identity from the segment
    /// identifier, so a row's identity changes exactly when its segment
    /// identifier does -- which the live and final passes guarantee it will.
    private static func line(
        pass: TranscriptIdentifier.Pass,
        ordinal: Int,
        text: String,
        isProvisional: Bool
    ) -> TranscriptLineItem {
        let segmentID = TranscriptIdentifier.segment(
            meetingID: meetingID,
            source: .system,
            pass: pass,
            ordinal: ordinal
        )
        let suffix = String(format: "%011d", ordinal)
        let identity = pass == .live ? "1" : "2"
        return TranscriptLineItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(identity)\(suffix)")!,
            segmentID: segmentID,
            speaker: "Speaker",
            start: 0,
            end: 1,
            text: text,
            isProvisional: isProvisional
        )
    }
}
