import Foundation

/// What a model identifier is allowed to be before it becomes an argument.
///
/// The string reaches the CLI as a discrete element of an argument vector, not
/// through a shell, so there is nothing here to quote or escape and no
/// injection to prevent. Two things can still go wrong:
///
/// - An empty or all-whitespace entry would be passed as `--model ""`, which no
///   CLI reads as "use your own default" -- so nothing typed has to mean no
///   `--model` flag at all rather than an empty one.
/// - A value beginning with a dash is a perfectly good argv element and a
///   perfectly bad model name: `--model --sandbox` leaves the CLI reading
///   `--sandbox` as the next option, silently changing the invocation Hushnote
///   built. Refusing it is not about safety from the string, it is about the
///   command line still meaning what it says.
///
/// Interior whitespace is refused for the same reason it can only be a mistake:
/// no model identifier any of the three tools accepts contains a space, and a
/// pasted `sonnet --tools ""` should be corrected rather than half-honoured.
public enum AgentCLIModelName {
    public enum Resolution: Equatable, Sendable {
        /// Nothing chosen. The CLI uses whatever the user configured in it.
        case unset
        case valid(String)
        case rejected(reason: String)
    }

    /// Dashes a person can actually end up with, including the ones a text
    /// editor or a web page substitutes for a hyphen.
    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"]

    public static func resolve(_ raw: String) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unset }

        if let first = trimmed.first, dashes.contains(first) {
            return .rejected(
                reason: "A model name cannot start with a dash — the CLI would read it as an option."
            )
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if trimmed.unicodeScalars.contains(where: separators.contains) {
            return .rejected(reason: "A model name is a single word, with no spaces in it.")
        }
        return .valid(trimmed)
    }

    /// The value to pass after `--model`, or nil when the flag should be left
    /// off entirely.
    public static func argument(_ raw: String) -> String? {
        guard case .valid(let model) = resolve(raw) else { return nil }
        return model
    }
}

/// A read-only command that makes a tool name the models it will accept, and
/// the shape of what it prints.
///
/// Discovery is a convenience, never a gate: a tool with no listing, one that
/// is not installed, one that is signed out and one that needs a network it
/// does not have all end in the same place -- an empty list and a text field
/// that still works.
public struct AgentCLIModelListing: Equatable, Sendable {
    /// How to read the output. Two tools, two formats, and no reason to expect
    /// a third to match either.
    public enum Shape: Equatable, Sendable {
        /// One `provider/model` identifier per line and nothing else, which is
        /// what `opencode models` prints. The qualifier is required, so a line
        /// of prose or an error cannot be mistaken for a model.
        case qualifiedIdentifierPerLine
        /// Names quoted inside one flag's own help text, which is the only
        /// place `claude` says what it takes: `--model` documents its aliases
        /// and an example full name and there is no `claude models`.
        case quotedInHelp(flag: String)
    }

    public let arguments: [String]
    public let shape: Shape

    public init(arguments: [String], shape: Shape) {
        self.arguments = arguments
        self.shape = shape
    }

    /// The identifiers the tool named, in the order it named them, each one
    /// already known to be passable as an argument.
    public func models(in output: String) -> [String] {
        let candidates: [String] = switch shape {
        case .qualifiedIdentifierPerLine: Self.qualifiedIdentifiers(in: output)
        case .quotedInHelp(let flag): Self.quotedIdentifiers(inBlockFor: flag, in: output)
        }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let model = AgentCLIModelName.argument(candidate),
                  seen.insert(model).inserted else { return nil }
            return model
        }
    }

    private static func qualifiedIdentifiers(in output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("/"), !trimmed.hasPrefix("/"), !trimmed.hasSuffix("/") else {
                return nil
            }
            return trimmed.allSatisfy(isIdentifierCharacter) ? trimmed : nil
        }
    }

    /// The lines documenting one option, from its own line up to the next one.
    ///
    /// An option starts at the left margin and its description is indented far
    /// past it, so "the next line that begins an option" is where this one
    /// ends. Bounding the search this way is what keeps the quoted JSON in a
    /// neighbouring flag's help out of the model list.
    private static func helpBlock(for flag: String, in output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { begins(line: $0, withFlag: flag) }) else {
            return nil
        }
        var block = [lines[start]]
        var index = lines.index(after: start)
        while index < lines.endIndex, !beginsAnOption(lines[index]) {
            block.append(lines[index])
            index = lines.index(after: index)
        }
        return block.joined(separator: "\n")
    }

    private static func begins(line: Substring, withFlag flag: String) -> Bool {
        guard beginsAnOption(line) else { return false }
        // `--model <model>` and `-m, --model <MODEL>` both introduce --model.
        for part in line.split(whereSeparator: { $0 == " " || $0 == "," }) where part == flag {
            return true
        }
        return false
    }

    private static func beginsAnOption(_ line: Substring) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 4 else { return false }
        return line.dropFirst(indent).first == "-"
    }

    /// Every `'quoted'` run of identifier characters in the block.
    ///
    /// Written as a scan rather than a pair-off because help text contains
    /// apostrophes: "a model's full name" would otherwise pair the apostrophe
    /// in `model's` with the opening quote of the example that follows and
    /// swallow it. Requiring the closing quote to arrive directly after
    /// identifier characters makes `'s full name (e.g. ` fail to match at all.
    private static func quotedIdentifiers(inBlockFor flag: String, in output: String) -> [String] {
        guard let block = helpBlock(for: flag, in: output) else { return [] }
        let characters = Array(block)
        var found: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "'" else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, isIdentifierCharacter(characters[end]) { end += 1 }
            if end > index + 1, end < characters.count, characters[end] == "'" {
                found.append(String(characters[(index + 1)..<end]))
                index = end + 1
            } else {
                index += 1
            }
        }
        return found
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "-" || character == "_" || character == "." || character == "/"
            || character == "+" || character == ":"
    }
}

/// What the model control can offer to pick from.
///
/// The list is an offer, not the set of legal answers: the field beside it
/// accepts anything, because only the CLI knows what it really takes and a
/// tool that lists nothing must still be usable.
public enum AgentCLIModelMenu {
    /// The discovered models, plus whatever is already chosen when the listing
    /// did not name it -- so a model typed by hand, or one belonging to a tool
    /// that lists nothing at all, stays reachable after being replaced.
    public static func options(discovered: [String], stored: String?) -> [String] {
        var seen = Set<String>()
        var options: [String] = []
        for candidate in discovered + [stored].compactMap({ $0 }) {
            guard let model = AgentCLIModelName.argument(candidate),
                  seen.insert(model).inserted else { continue }
            options.append(model)
        }
        return options
    }

    /// Whether there is anything to open a menu onto. When there is not, the
    /// control is the text field alone rather than an empty menu beside it.
    public static func showsMenu(discovered: [String], stored: String?) -> Bool {
        !options(discovered: discovered, stored: stored).isEmpty
    }
}
