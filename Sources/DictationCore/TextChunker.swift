/// Splits text into chunks small enough for one synthesized key event, never splitting a
/// grapheme cluster (so emoji and combined accents survive).
public enum TextChunker {
    /// CGEvent's unicode payload is limited to 20 UTF-16 code units.
    public static let maxUTF16PerEvent = 20

    public static func chunks(_ text: String, maxUTF16: Int = maxUTF16PerEvent) -> [String] {
        var result: [String] = []
        var current = ""
        var currentCount = 0
        for character in text {
            let count = character.utf16.count
            if currentCount + count > maxUTF16, !current.isEmpty {
                result.append(current)
                current = ""
                currentCount = 0
            }
            current.append(character)
            currentCount += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
