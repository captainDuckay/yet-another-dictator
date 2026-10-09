/// The language Whisper should transcribe. Automatic detection is unreliable for short clips
/// (Danish is easily mistaken for Norwegian or English), so a fixed language can be chosen.
public enum DictationLanguage: String, CaseIterable, Codable, Sendable {
    case automatic
    case danish
    case english

    /// Whisper's language code, or nil to detect it from the audio.
    public var whisperCode: String? {
        switch self {
        case .automatic: nil
        case .danish: "da"
        case .english: "en"
        }
    }

    /// Shown in Settings, each language in its own language.
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .danish: "Dansk"
        case .english: "English"
        }
    }

    /// Reads a stored value, falling back to automatic for anything unknown.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .automatic
    }
}
