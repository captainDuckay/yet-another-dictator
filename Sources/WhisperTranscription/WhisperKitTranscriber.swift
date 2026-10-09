import DictationCore
import Foundation
import Synchronization
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

    /// WhisperKit isn't Sendable. Transcriptions are serialised (see `transcribe`), so it is never
    /// used by two at once, which makes handing it across task boundaries safe.
    private final class Engine: @unchecked Sendable {
        let whisper: WhisperKit
        init(_ whisper: WhisperKit) { self.whisper = whisper }
    }

    /// Output that compresses better than this (as WhisperKit measures it) is too repetitive to be
    /// real speech. Same value as WhisperKit's and OpenAI's default.
    static let compressionRatioThreshold: Float = 2.4

    private let modelFolder: URL
    private var engine: Engine?
    private var loading: Task<Engine, any Error>?
    /// The latest transcription. A new one waits for it: the controller may abandon a transcription
    /// (cancel/timeout) and start another before the old one has wound down.
    private var latest: Task<Void, Never>?

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

        let previous = latest
        let stop = StopFlag()
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await Self.run(engine, samples, stop: stop)
        }
        latest = Task { _ = await work.result }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            stop.set()
            work.cancel()
        }
    }

    /// Set when the caller gives up; WhisperKit checks it after every decoded token.
    private final class StopFlag: Sendable {
        private let stopped = Mutex(false)
        func set() { stopped.withLock { $0 = true } }
        var isSet: Bool { stopped.withLock { $0 } }
    }

    private static func run(_ engine: Engine, _ samples: [Float], stop: StopFlag) async throws -> String {
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Whisper's standard quality checks, spelled out so they're deliberate. A window that
            // fails one is decoded again at a higher temperature. noSpeechThreshold has no effect
            // in WhisperKit 1.1.1 (no-speech probability is not computed); silence is instead
            // rejected before transcription by `SpeechActivity`.
            compressionRatioThreshold: Self.compressionRatioThreshold,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6
        )
        let results = try await engine.whisper.transcribe(
            audioArray: samples,
            decodeOptions: options,
            // Returning false ends decoding early; nil means carry on.
            callback: { _ in stop.isSet ? false : nil }
        )
        try Task.checkCancellation()
        // A segment still this repetitive after every fallback is a hallucination loop
        // ("tak tak tak …"), not dictation.
        return results
            .flatMap(\.segments)
            .filter { $0.compressionRatio <= Self.compressionRatioThreshold }
            .map(\.text)
            .joined(separator: " ")
    }
}
