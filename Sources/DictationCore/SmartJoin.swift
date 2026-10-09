/// Fits a dictation to the text it is typed after: adds the separating space, and capitalizes
/// or lowercases the first word depending on whether a new sentence starts there.
public enum SmartJoin {
    /// - Parameters:
    ///   - text: The cleaned transcript.
    ///   - preceding: The text just before the insertion point (only its end matters), or nil when
    ///     unknown. Unknown leaves the transcript as Whisper wrote it.
    public static func adjust(_ text: String, after preceding: String?) -> String {
        guard let preceding, let first = text.first, !first.isWhitespace else { return text }
        let sentenceStart = startsSentence(after: preceding)

        var result = text
        if sentenceStart {
            result = capitalizingFirstLetter(result)
        } else if let lowered = loweringFirstWord(result) {
            result = lowered
        }
        if needsSpace(after: preceding, before: first) {
            result = " " + result
        }
        return result
    }

    /// True when the insertion point is at the start of a sentence: the field is empty, the line is
    /// new, or the previous sentence ended (possibly followed by a closing quote or bracket).
    static func startsSentence(after preceding: String) -> Bool {
        var tail = preceding[...]
        while let last = tail.last, last.isWhitespace, !last.isNewline { tail.removeLast() }
        while let last = tail.last, closers.contains(last) { tail.removeLast() }
        guard let last = tail.last else { return true }
        return last.isNewline || terminators.contains(last)
    }

    private static func needsSpace(after preceding: String, before next: Character) -> Bool {
        guard let previous = preceding.last else { return false }
        if previous.isWhitespace || openers.contains(previous) { return false }
        // A straight quote opens when it follows a space or starts the text, and closes otherwise.
        if previous == "\"" || previous == "'" {
            let before = preceding.dropLast().last
            if before == nil || before!.isWhitespace || openers.contains(before!) { return false }
        }
        if attachesToPrevious.contains(next) { return false }
        return true
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Lowercases a sentence-style capital in the middle of a sentence ("Hello, How" → "Hello, how").
    /// Leaves words that look intentionally capitalized: "I", acronyms ("NASA", "TV"), and words with
    /// capitals inside ("iPhone", "McDonald"). Proper nouns can't be told apart and get lowercased.
    private static func loweringFirstWord(_ text: String) -> String? {
        let word = text.prefix { $0.isLetter }
        guard word.count > 1, let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy(\.isLowercase)
        else { return nil }
        return first.lowercased() + text.dropFirst()
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "»", "”", "’"]
    private static let openers: Set<Character> = ["(", "[", "{", "«", "“", "‘", "/"]
    private static let attachesToPrevious: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "%", "»", "”", "’"]
}

/// What the last dictation typed, as long as the user hasn't typed, clicked or switched apps since.
/// Used as the text before the cursor when the focused field can't be read, and for undo.
public struct DictationHistory: Sendable {
    public private(set) var lastInserted: String?

    public init() {}

    public mutating func didInsert(_ text: String) {
        lastInserted = text
    }

    /// The user typed, clicked or switched apps: the cursor may be anywhere now.
    public mutating func otherInput() {
        lastInserted = nil
    }

    /// The number of characters (as the user sees them) to delete to undo the last dictation,
    /// or nil when it can't be undone safely. Clears the history.
    public mutating func takeUndo() -> Int? {
        defer { lastInserted = nil }
        guard let lastInserted, !lastInserted.isEmpty else { return nil }
        return lastInserted.count
    }
}
