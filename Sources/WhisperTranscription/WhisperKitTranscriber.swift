import DictationCore
import Foundation
@preconcurrency import WhisperKit

/// Offline transcription using the WhisperKit Large v3 Turbo model bundled inside the app.
///
/// Network access is never requested: `download` is disabled and the tokenizer is read from the
/// model folder. The app also ships sandboxed without a network entitlement, so any unexpected
/// fetch fails instead of leaking.
public actor WhisperKitTranscriber: Transcribing {
    /// Files that must exist in the model folder before WhisperKit is allowed to load. A missing
    /// tokenizer would otherwise make WhisperKit fall back to downloading from Hugging Face.
    public static let requiredFiles = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
    ]

    public enum Failure: Error, CustomStringConvertible {
        case missingModelFiles([String])
        case notLoaded

        public var description: String {
            switch self {
            case .missingModelFiles(let files): "Bundled model is incomplete, missing: \(files.joined(separator: ", "))"
            case .notLoaded: "Model is not loaded"
            }
        }
    }

    /// WhisperKit isn't Sendable. It is only ever used from this actor, and the controller never
    /// runs two transcriptions at once, so handing it across the load task boundary is safe.
    private final class Engine: @unchecked Sendable {
        let whisper: WhisperKit
        init(_ whisper: WhisperKit) { self.whisper = whisper }
    }

    private let modelFolder: URL
    private var engine: Engine?
    private var loading: Task<Engine, any Error>?

    public init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    /// `<App>.app/Contents/Resources/Model`
    public static func bundledModelFolder(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appending(path: "Model", directoryHint: .isDirectory)
    }

    public func prepare() async throws {
        if engine != nil { return }
        if let loading {
            engine = try await loading.value
            return
        }

        let missing = Self.requiredFiles.filter {
            !FileManager.default.fileExists(atPath: modelFolder.appending(path: $0).path(percentEncoded: false))
        }
        guard missing.isEmpty else { throw Failure.missingModelFiles(missing) }

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path(percentEncoded: false),
            tokenizerFolder: modelFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let task = Task { Engine(try await WhisperKit(config)) }
        loading = task
        do {
            engine = try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await prepare()
        guard let engine else { throw Failure.notLoaded }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await engine.whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
