import Foundation
import Observation

/// The speech models Dictator can download, best first. Nothing is downloaded until the user picks
/// one (ADR 0006). Each case's raw value is its model-id in `model-manifest.txt`.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the ranking shown in the picker: best first.
    case parakeetV2 = "parakeet-tdt-0.6b-v2"
    case whisperLargeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"

    var id: String { rawValue }

    /// Best first.
    static var ranked: [SpeechModel] { allCases }

    var displayName: String {
        switch self {
        case .parakeetV2: "NVIDIA Parakeet TDT 0.6B v2"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        }
    }

    var accuracyNote: String {
        switch self {
        case .parakeetV2: "Most accurate for English (6.1% average word error rate on the Open ASR Leaderboard)."
        case .whisperLargeV3Turbo: "Accurate (7.8% average word error rate in English). Also understands Dansk."
        }
    }

    var speedNote: String {
        switch self {
        case .parakeetV2: "Fastest: well under a second per minute of speech on Apple silicon."
        case .whisperLargeV3Turbo: "Fast, but several times slower than Parakeet."
        }
    }

    var isEnglishOnly: Bool { self == .parakeetV2 }

    var languageNote: String { isEnglishOnly ? "English only" : "Automatic, Dansk or English" }

    /// Whose model it is, for the picker.
    var source: String {
        switch self {
        case .parakeetV2: "NVIDIA, CC-BY-4.0"
        case .whisperLargeV3Turbo: "OpenAI, MIT"
        }
    }
}

/// The user's model choice, stored in UserDefaults. Unset until they pick one.
@MainActor
@Observable
final class ModelChoice {
    static let key = "speechModel"

    private(set) var selected: SpeechModel?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.key).flatMap(SpeechModel.init(rawValue:))
    }

    /// The first-launch picker is shown only while this is true.
    var needsChoice: Bool { selected == nil }

    func choose(_ model: SpeechModel) {
        selected = model
        defaults.set(model.rawValue, forKey: Self.key)
    }
}

/// What to do about the model at launch. Pure, so the "never download on its own" rule is tested.
enum ModelStartup: Equatable {
    /// Nothing is chosen: show the picker and download nothing.
    case showPicker
    /// Load (downloading only if missing) the model the user chose earlier.
    case load(SpeechModel)

    /// `installed` lists models whose verified files are already on disk. A copy that downloaded
    /// Whisper before the picker existed keeps using it without being asked again.
    static func decide(choice: SpeechModel?, installed: Set<SpeechModel>) -> ModelStartup {
        if let choice { return .load(choice) }
        if let existing = SpeechModel.ranked.first(where: installed.contains) { return .load(existing) }
        return .showPicker
    }
}
