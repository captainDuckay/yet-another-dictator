import Foundation
import Observation
import OSLog
import WhisperTranscription

/// Downloads the Whisper model on first launch (ADR 0004), automatically, with progress, resume,
/// retry and SHA-256 verification against the manifest bundled in the signed app. The download is
/// the only network use besides the optional update check; audio never leaves the Mac.
@MainActor
@Observable
final class ModelDownload {
    enum Status: Equatable {
        case checking
        case downloading(ModelInstaller.Progress)
        case failed(String)
        case ready
    }

    static let modelID = "openai_whisper-large-v3-v20240930_turbo"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "model")

    private(set) var status: Status = .checking
    @ObservationIgnored private let installer: ModelInstaller?
    @ObservationIgnored private var task: Task<Bool, Never>?

    init() {
        do {
            installer = ModelInstaller(
                manifest: try ModelManifest.bundled(), modelID: Self.modelID, root: try ModelInstaller.defaultRoot()
            )
        } catch {
            installer = nil
            status = .failed("The app's model manifest is missing or invalid: \(error)")
        }
    }

    /// Where WhisperKit loads from. Only complete once `ensureInstalled()` returned true.
    var folder: URL { installer?.folder ?? URL(filePath: "/nonexistent", directoryHint: .isDirectory) }

    var totalBytes: Int64 { installer?.totalBytes ?? 0 }

    /// Downloads whatever is missing; returns true once the model is complete and verified.
    func ensureInstalled() async -> Bool {
        if let task { return await task.value }
        guard let installer else { return false }
        if installer.isInstalled {
            status = .ready
            return true
        }
        // AppModel owns this object for the app's lifetime, so capturing self strongly is fine.
        let task = Task<Bool, Never> {
            self.status = .downloading(.init(completedBytes: 0, totalBytes: installer.totalBytes))
            Self.log.notice("model download started")
            do {
                try await installer.install(using: RangedTransport()) { progress in
                    Task { @MainActor in
                        if case .downloading = self.status { self.status = .downloading(progress) }
                    }
                }
                Self.log.notice("model download verified")
                self.status = .ready
                return true
            } catch {
                Self.log.error("model download failed: \(String(describing: error), privacy: .public)")
                self.status = .failed(Self.describe(error))
                return false
            }
        }
        self.task = task
        let ok = await task.value
        self.task = nil
        return ok
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost:
                return "No internet connection. Dictator retries when you choose Retry."
            default: break
            }
        }
        if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace {
            return "Not enough disk space (about 1.7 GB needed)."
        }
        return String(describing: error)
    }

    var statusText: String? {
        switch status {
        case .checking, .ready: nil
        case .downloading(let progress):
            "Downloading speech model… \(Self.megabytes(progress.completedBytes)) of \(Self.megabytes(progress.totalBytes)) MB"
        case .failed(let reason): "Model download failed: \(reason)"
        }
    }

    static func megabytes(_ bytes: Int64) -> Int64 { bytes / 1_000_000 }
}
