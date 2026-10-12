import Foundation
import Observation
import OSLog
import WhisperTranscription

/// Main-actor face of `ModelProvisioner` for the menu and Settings (ADR 0004). The download runs
/// automatically on first launch, with progress, resume, retry and SHA-256 verification against
/// the manifest bundled in the signed app. Audio never leaves the Mac.
@MainActor
@Observable
final class ModelDownload {
    typealias Status = ModelProvisioner.Status

    static let modelID = "openai_whisper-large-v3-v20240930_turbo"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "model")

    private(set) var status: Status = .checking
    @ObservationIgnored private var provisioner: ModelProvisioner?

    init(transport: any ModelTransport) {
        do {
            let installer = ModelInstaller(
                manifest: try ModelManifest.bundled(), modelID: Self.modelID, root: try ModelInstaller.defaultRoot()
            )
            provisioner = ModelProvisioner(installer: installer, transport: transport) { [weak self] progress in
                Task { @MainActor in self?.progressed(progress) }
            }
        } catch {
            status = .failed("The app's model manifest is missing or invalid: \(error)")
        }
    }

    /// Where WhisperKit loads from. Only complete once `ensureInstalled()` returned true.
    var folder: URL { provisioner?.installer.folder ?? URL(filePath: "/nonexistent", directoryHint: .isDirectory) }

    var totalBytes: Int64 { provisioner?.installer.totalBytes ?? 0 }

    /// Downloads whatever is missing; returns true once the model is complete and verified.
    func ensureInstalled() async -> Bool {
        guard let provisioner else { return false }
        if !provisioner.installer.isInstalled {
            status = .downloading(.init(completedBytes: 0, totalBytes: provisioner.installer.totalBytes))
            Self.log.notice("model download started")
        }
        let ok = await provisioner.ensureInstalled()
        status = await provisioner.status
        if ok {
            Self.log.notice("model ready")
        } else if case .failed(let reason) = status {
            Self.log.error("model download failed: \(reason, privacy: .public)")
        }
        return ok
    }

    /// Progress can arrive after the outcome; only a running download shows it.
    private func progressed(_ progress: ModelInstaller.Progress) {
        if case .downloading = status { status = .downloading(progress) }
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
