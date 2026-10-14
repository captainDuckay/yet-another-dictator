import Foundation
import Observation
import OSLog
import WhisperTranscription

/// Main-actor face of `ModelProvisioner` for the menu, Settings and the model picker (ADR 0006).
/// Downloads only the model the user chose, with progress, resume, retry and SHA-256 verification
/// against the manifest bundled in the signed app. Audio never leaves the Mac.
@MainActor
@Observable
final class ModelDownload {
    typealias Status = ModelProvisioner.Status

    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "model")

    /// The model this download is for; nil until the user picks one.
    private(set) var model: SpeechModel?
    private(set) var status: Status = .checking
    /// Bumped by every change, so changes the views show (installed/deleted) are observed.
    private(set) var revision = 0
    @ObservationIgnored private var provisioner: ModelProvisioner?
    @ObservationIgnored private let manifest: ModelManifest?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let transport: any ModelTransport
    @ObservationIgnored private let manifestError: String?

    init(manifest: ModelManifest?, root: URL, transport: any ModelTransport, manifestError: String? = nil) {
        self.manifest = manifest
        self.root = root
        self.transport = transport
        self.manifestError = manifestError
        if let manifestError { status = .failed(manifestError) }
    }

    /// The app's bundled manifest and its Application Support folder.
    static func bundled(transport: any ModelTransport) -> ModelDownload {
        do {
            return ModelDownload(manifest: try ModelManifest.bundled(), root: try ModelInstaller.defaultRoot(), transport: transport)
        } catch {
            return ModelDownload(
                manifest: nil, root: URL(filePath: "/nonexistent", directoryHint: .isDirectory), transport: transport,
                manifestError: "The app's model manifest is missing or invalid: \(error)"
            )
        }
    }

    private func installer(for model: SpeechModel) -> ModelInstaller? {
        manifest.map { ModelInstaller(manifest: $0, modelID: model.rawValue, root: root) }
    }

    /// Switches to `model`. Nothing is downloaded until `ensureInstalled()`.
    func select(_ model: SpeechModel) {
        guard model != self.model else { return }
        self.model = model
        guard let installer = installer(for: model) else { return }
        let id = model
        provisioner = ModelProvisioner(installer: installer, transport: transport) { [weak self] progress in
            Task { @MainActor in self?.progressed(progress, for: id) }
        }
        status = .checking
    }

    /// Where the selected model loads from. Only complete once `ensureInstalled()` returned true.
    var folder: URL {
        provisioner?.installer.folder ?? URL(filePath: "/nonexistent", directoryHint: .isDirectory)
    }

    func bytes(of model: SpeechModel) -> Int64 { manifest?.totalBytes(for: model.rawValue) ?? 0 }

    func isInstalled(_ model: SpeechModel) -> Bool {
        _ = revision
        return installer(for: model)?.isInstalled ?? false
    }

    var installedModels: Set<SpeechModel> { Set(SpeechModel.allCases.filter(isInstalled)) }

    /// Downloads whatever is missing of the selected model; true once it is complete and verified.
    /// Does nothing (and returns false) while no model is selected.
    func ensureInstalled() async -> Bool {
        guard let provisioner, let model else { return false }
        if !provisioner.installer.isInstalled {
            status = .downloading(.init(completedBytes: 0, totalBytes: provisioner.installer.totalBytes))
            Self.log.notice("model download started: \(model.rawValue, privacy: .public)")
        }
        let ok = await provisioner.ensureInstalled()
        // The user may have switched models while this one downloaded.
        guard model == self.model else { return false }
        status = await provisioner.status
        revision += 1
        if ok {
            Self.log.notice("model ready: \(model.rawValue, privacy: .public)")
        } else if case .failed(let reason) = status {
            Self.log.error("model download failed: \(reason, privacy: .public)")
        }
        return ok
    }

    /// Frees the disk space of a model that is not the selected one.
    func delete(_ model: SpeechModel) throws {
        guard model != self.model else { return }
        try installer(for: model)?.uninstall()
        revision += 1
        Self.log.notice("model deleted: \(model.rawValue, privacy: .public)")
    }

    /// Progress can arrive after the outcome, or for a model no longer selected; only a running
    /// download of the selected model shows it.
    private func progressed(_ progress: ModelInstaller.Progress, for model: SpeechModel) {
        guard model == self.model, case .downloading = status else { return }
        status = .downloading(progress)
    }

    var statusText: String? {
        if model == nil, manifestError == nil { return "No speech model chosen" }
        switch status {
        case .checking, .ready: return nil
        case .downloading(let progress):
            return "Downloading speech model… \(Self.megabytes(progress.completedBytes)) of \(Self.megabytes(progress.totalBytes)) MB"
        case .failed(let reason): return "Model download failed: \(reason)"
        }
    }

    static func megabytes(_ bytes: Int64) -> Int64 { bytes / 1_000_000 }

    /// "464 MB" / "1.6 GB".
    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
            : "\(megabytes(bytes)) MB"
    }
}
