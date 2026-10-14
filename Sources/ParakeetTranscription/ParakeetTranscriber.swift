import DictationCore
@preconcurrency import FluidAudio
import Foundation

/// The only code that uses FluidAudio: NVIDIA Parakeet TDT 0.6B v2 (English) as Core ML models,
/// loaded from a folder the app downloaded and verified against its pinned manifest.
///
/// FluidAudio never downloads anything here (`AsrModels.loadLocal`). Parakeet reads long audio in
/// its own overlapping windows, so the Whisper 30-second splitter is not used.
public actor ParakeetTranscriber: Transcribing {
    /// Files that must exist in the model folder before FluidAudio is asked to load it.
    public static let requiredFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    public enum Failure: Error, CustomStringConvertible {
        case missingModelFiles([String])

        public var description: String {
            switch self {
            case .missingModelFiles(let files): "Model is incomplete, missing: \(files.joined(separator: ", "))"
            }
        }
    }

    private let modelFolder: URL
    private var manager: AsrManager?
    private var loading: Task<AsrManager, any Error>?
    /// The latest transcription. A new one waits for it, as in `WhisperKitTranscriber`.
    private var latest: Task<Void, Never>?

    public init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    public func prepare() async throws {
        if manager != nil { return }
        if let loading {
            manager = try await loading.value
            return
        }
        let missing = Self.requiredFiles.filter {
            !FileManager.default.fileExists(atPath: modelFolder.appending(path: $0).path(percentEncoded: false))
        }
        guard missing.isEmpty else { throw Failure.missingModelFiles(missing) }

        let folder = modelFolder
        let task = Task.detached(priority: .userInitiated) { () throws -> AsrManager in
            let models = try AsrModels.loadLocal(from: folder, version: .v2)
            let manager = AsrManager(config: .default, models: models)
            // Pay Core ML's one-off setup during "Loading model…", not on the first dictation.
            var state = TdtDecoderState.make()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            return manager
        }
        loading = task
        do {
            manager = try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    /// `language` is ignored: this model is English only.
    public func transcribe(_ samples: [Float], language: String?) async throws -> String {
        try await prepare()
        guard let manager else { return "" }
        let previous = latest
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            var state = TdtDecoderState.make()
            let result = try await manager.transcribe(samples, decoderState: &state)
            try Task.checkCancellation()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        latest = Task { _ = await work.result }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
