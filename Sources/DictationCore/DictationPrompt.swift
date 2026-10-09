/// A short, well-punctuated "previous text" given to Whisper as its initial prompt.
///
/// Whisper continues the style of the text it is conditioned on. Without a prompt it often leaves
/// a short dictation without its final full stop or question mark, because a single short clip
/// gives it no evidence that output should be written as complete sentences. A few complete,
/// punctuated sentences fix that.
///
/// The prompt is bilingual (Danish and English) and only sets the style. The spoken language is
/// detected from the audio alone (from the start-of-transcript token, before the prompt is used), so
/// the prompt does not steer which language is transcribed.
public enum DictationPrompt {
    public static let text = "Hej, hvordan går det? Det går godt, tak. Hello, how are you? I'm fine, thanks."

    /// Whisper sometimes repeats its prompt when the audio holds no speech. Returns true when the
    /// transcript is such an echo: a run of at least half the prompt's words, word for word. A short
    /// phrase that merely also appears in the prompt ("Tak.", "Hello, how are you?") is kept.
    public static func isEcho(_ transcript: String) -> Bool {
        let spoken = words(in: transcript)
        let prompt = words(in: text)
        guard spoken.count * 2 >= prompt.count, spoken.count <= prompt.count else { return false }
        return (0...(prompt.count - spoken.count)).contains { start in
            prompt[start..<(start + spoken.count)].elementsEqual(spoken)
        }
    }

    private static func words(in text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
