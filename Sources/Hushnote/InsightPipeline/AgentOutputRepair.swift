import Foundation

/// Gets a JSON object out of whatever a model actually said.
///
/// Only two of the three CLIs can be held to a schema, and even those wrap the
/// answer in prose often enough to matter. The user must never be shown raw
/// model prose where a summary should be, so this either produces an object or
/// the caller fails cleanly.
public enum AgentOutputRepair {
    /// The first well-formed JSON object in `text`, unwrapping a code fence and
    /// surrounding chatter if that is what stands in the way.
    public static func jsonObject(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isObject(trimmed) { return trimmed }
        let unfenced = stripFence(trimmed)
        if isObject(unfenced) { return unfenced }
        guard let balanced = firstBalancedObject(in: unfenced), isObject(balanced) else {
            return nil
        }
        return balanced
    }

    /// What to append to a prompt when the first attempt came back unusable.
    /// One retry, then the run fails rather than nagging the model or the user.
    public static func correction(schemaName: String) -> String {
        """

        Your previous reply was not a JSON object matching \(schemaName). Reply with that object and nothing else: no prose before it, no code fence around it.
        """
    }

    private static func isObject(_ text: String) -> Bool {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return false }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else { return false }
        return true
    }

    private static func stripFence(_ text: String) -> String {
        guard let start = text.range(of: "```") else { return text }
        var body = String(text[start.upperBound...])
        if let newline = body.firstIndex(of: "\n"),
           !body[body.startIndex..<newline].contains("{") {
            body = String(body[body.index(after: newline)...])
        }
        if let end = body.range(of: "```") {
            body = String(body[body.startIndex..<end.lowerBound])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans for a brace-balanced object, ignoring braces inside strings so a
    /// quoted "}" in a transcript quotation does not truncate the result.
    private static func firstBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
