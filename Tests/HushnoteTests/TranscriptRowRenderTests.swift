import Foundation
import Testing
@testable import Hushnote

/// The last line of defence for Whisper's control vocabulary.
///
/// `skipSpecialTokens` keeps the tokens out of the decode, the engines sanitize
/// what comes back, and a migration repairs what is already on disk -- and the
/// user still saw `<|startoftranscript|><|en|><|transcribe|>` in the transcript
/// pane, because a session captured before any of that landed is loaded from a
/// database the user has not migrated yet. The view is the one place that can
/// be certain, so it strips at the point of display.
///
/// The fixtures are the rows from the screenshot the user sent.
@Suite("Transcript row rendering")
struct TranscriptRowRenderTests {
    @Test("A row's opening segment loses the prompt tokens")
    func openingSegment() {
        #expect(
            TranscriptRowText.display(
                "<|startoftranscript|><|en|><|transcribe|><|0.00|> Oh, whoever is done.<|1.16|>"
            ) == "Oh, whoever is done."
        )
    }

    @Test("A row wrapped in bare timestamps loses them at both ends")
    func bareTimestamps() {
        #expect(
            TranscriptRowText.display("<|1.00|> When it was the...<|2.00|>")
                == "When it was the..."
        )
        #expect(
            TranscriptRowText.display("<|4.24|> having a<|4.70|>") == "having a"
        )
    }

    @Test("The closing row loses its end-of-text token")
    func endOfText() {
        #expect(
            TranscriptRowText.display(
                "... joining really except for ... we're having made<|6.72|><|endoftext|>"
            ) == "... joining really except for ... we're having made"
        )
    }

    /// A transcript that never had a token in it is handed to the view
    /// unchanged -- including its interior punctuation and spacing.
    @Test("Clean speech is rendered verbatim")
    func cleanSpeechIsUntouched() {
        #expect(
            TranscriptRowText.display("So -- and this is the point -- we ship Friday.")
                == "So -- and this is the point -- we ship Friday."
        )
    }

    /// `WhisperSpecialToken.isControlTokenBody` deliberately refuses anything
    /// that is not an unbroken run of token characters, and the view must not
    /// widen that: speech is allowed to contain angle brackets and pipes.
    @Test("Speech that looks like a token survives")
    func speechThatResemblesATokenSurvives() {
        #expect(TranscriptRowText.display("if x < y | z > 0 then bail") == "if x < y | z > 0 then bail")
        #expect(TranscriptRowText.display("he wrote a <| b |> c on the board")
            == "he wrote a <| b |> c on the board")
    }

    /// Stripping at the point of display is only safe because it can never be
    /// mistaken for the user's correction: a row seeded or re-seeded from the
    /// model is unfocused by construction, and an unfocused change is not a
    /// human edit, so nothing is queued to the database and `isUserEdited`
    /// stays clear.
    @Test("Sanitizing a row for display is not a human edit")
    func sanitizingIsNotAHumanEdit() throws {
        let stored = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Oh, whoever is done.<|1.16|>"
        let shown = TranscriptRowText.display(stored)
        #expect(shown != stored)
        #expect(
            TranscriptEditPolicy.isHumanEdit(isFocused: false, from: stored, to: shown) == false
        )
        // And the same string arriving as a re-seed while the row is focused is
        // refused outright, so a sanitized value can never replace what someone
        // is typing.
        #expect(
            TranscriptRowText.reseededDraft(incoming: stored, draft: "mid sentence", isFocused: true)
                == nil
        )
    }
}
