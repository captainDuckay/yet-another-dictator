import DictationCore
@preconcurrency import FluidAudio
import Foundation
import ModelSession

/// The only code that uses FluidAudio: NVIDIA Parakeet TDT 0.6B v2 (English) as Core ML models,
/// loaded from a folder the app downloaded and verified against its pinned manifest.
///
/// FluidAudio never downloads anything here (`AsrModels.loadLocal`). Parakeet reads long audio in
/// its own overlapping windows, so the Whisper 30-second splitter is not used.
extension ModelSession {
    static let parakeetRequiredFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    /// The Parakeet model as a session. `ModelSession` (ADR 0008) owns loading and ordering.
    public static func parakeet(modelFolder: URL) -> ModelSession {
        ModelSession(modelFolder: modelFolder, requiredFiles: parakeetRequiredFiles) { folder in
            let models = try AsrModels.loadLocal(from: folder, version: .v2)
            let manager = AsrManager(config: .default, models: models)
            // Pay Core ML's one-off setup during "Loading model…", not on the first dictation.
            var state = TdtDecoderState.make()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            return LoadedParakeet(manager)
        }
    }
}

/// A loaded Parakeet model.
final class LoadedParakeet: LoadedSpeechModel, @unchecked Sendable {
    private let manager: AsrManager

    init(_ manager: AsrManager) { self.manager = manager }

    /// `language` is ignored: this model is English only.
    func transcribe(_ samples: [Float], language: String?, stop: StopSignal) async throws -> String {
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state)
        if stop.isSet { throw CancellationError() }
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
