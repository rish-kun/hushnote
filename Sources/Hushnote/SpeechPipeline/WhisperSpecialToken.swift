import Foundation

/// Whisper's control vocabulary is rendered as `<|…|>` when it survives into
/// decoded text: `<|startoftranscript|>`, the language and task tags, and a
/// timestamp token such as `<|6.88|>` on either side of every segment.
///
/// `DecodingOptions.skipSpecialTokens` is what keeps them out in the first
/// place, and both WhisperKit entry points here set it. This is the second
/// line: the option is a library default away from flipping back, a future
/// model can introduce a control token WhisperKit does not classify as
/// special, and the text is persisted, exported and fed to the summarizer, so
/// a single leak is permanent and visible everywhere.
enum WhisperSpecialToken {
    /// Removes `<|…|>` control tokens, leaving everything else exactly as it
    /// was. Whitespace is only touched where a token used to sit: removing
    /// `<|6.88|>` from `"a <|6.88|> b"` must not leave a double space behind.
    static func stripped(from text: String) -> String {
        // The overwhelmingly common case once `skipSpecialTokens` is set.
        guard text.contains("<|") else { return text }

        var output = ""
        var remainder = Substring(text)

        while let open = remainder.range(of: "<|") {
            guard
                let close = remainder.range(
                    of: "|>",
                    range: open.upperBound..<remainder.endIndex
                )
            else { break }

            guard isControlTokenBody(remainder[open.upperBound..<close.lowerBound]) else {
                // Not a control token. Consume only the `<|` so a real token
                // that sits inside this span is still found on the next pass.
                output += remainder[remainder.startIndex..<open.upperBound]
                remainder = remainder[open.upperBound...]
                continue
            }

            output += remainder[remainder.startIndex..<open.lowerBound]
            remainder = remainder[close.upperBound...]
            // The token was surrounded by spaces on both sides; keep one.
            if output.last.map(isInlineSpace) == true,
                remainder.first.map(isInlineSpace) == true
            {
                remainder = remainder.dropFirst()
            }
        }

        output += remainder
        return output
    }

    /// Segment text is presented as a paragraph, so it is stripped and trimmed.
    static func cleanedSegmentText(_ text: String) -> String {
        stripped(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Word text keeps its leading space: Whisper encodes word boundaries there
    /// and consumers rejoin words by concatenation.
    static func cleanedWordText(_ text: String) -> String {
        stripped(from: text)
    }

    /// A control token's body is a single unbroken run of the characters
    /// Whisper actually uses — `startoftranscript`, `en`, `zh-Hant`,
    /// `transcribe`, `6.88`. Requiring that shape is what keeps legitimate
    /// speech containing `<` and `|` intact: `"a <| b |> c"` has spaces in the
    /// body and survives untouched, as does `"if x < y | z > 0"`.
    private static func isControlTokenBody(_ body: Substring) -> Bool {
        guard !body.isEmpty, body.count <= 32 else { return false }
        return body.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || "._-".contains(character))
        }
    }

    private static func isInlineSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }
}
