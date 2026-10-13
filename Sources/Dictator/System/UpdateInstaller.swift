import AppUpdate
import Foundation

enum UpdatePhase: Equatable, Sendable {
    case idle
    case downloading(Double)
    case checking
    case installing
    case failed(String)

    var allowsCheck: Bool {
        switch self {
        case .idle, .failed: true
        default: false
        }
    }
}

/// Downloads one offered release, checks its checksum and signature, then asks the updater to
/// replace this app. Nothing is written over the running app until those checks pass.
enum UpdateInstaller {
    static func install(_ update: OfferedUpdate, progress: @escaping @Sendable (UpdatePhase) -> Void) async throws {
        guard let zipURL = update.zipURL, let checksumURL = update.checksumURL else { throw UpdateInstallError.archive }
        let work = FileManager.default.temporaryDirectory.appending(path: "dictator-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var keepsWork = false
        defer { if !keepsWork { try? FileManager.default.removeItem(at: work) } }

        progress(.downloading(0))
        let checksumFile = work.appending(path: "checksum.txt")
        do {
            try await UpdateDownloader.download(checksumURL, to: checksumFile, limit: ArchiveLimits.maxChecksumBytes, progress: { _ in })
        } catch {
            throw UpdateInstallError.download
        }
        guard let checksumText = try? String(contentsOf: checksumFile, encoding: .utf8) else { throw UpdateInstallError.checksum }

        let zip = work.appending(path: zipURL.lastPathComponent)
        do {
            try await UpdateDownloader.download(zipURL, to: zip, limit: ArchiveLimits.maxArchiveBytes) { fraction in
                progress(.downloading(fraction))
            }
        } catch {
            throw UpdateInstallError.download
        }
        guard ArchiveIntegrity.matches(file: zip, checksumText: checksumText, fileName: zip.lastPathComponent) else {
            throw UpdateInstallError.checksum
        }

        progress(.checking)
        let app = try ArchiveExtractor.extractApp(from: zip, into: work.appending(path: "unzipped", directoryHint: .isDirectory))
        let trust = SignedApp.trust(at: app)
        guard let destination = currentIdentity() else { throw UpdateInstallError.rejected("The update's version couldn't be read.") }
        if let refusal = InstallPolicy.signatureRefusal(trust) ?? InstallPolicy.versionRefusal(replacing: destination, with: trust.identity) {
            throw UpdateInstallError.rejected(refusal)
        }

        progress(.installing)
        switch await UpdateClient.install(stagedApp: app) {
        case .replied(nil):
            return
        case .replied(let message?):
            throw UpdateInstallError.rejected(message)
        case .timedOut:
            if AppIdentity.read(from: Bundle.main.bundleURL).version == update.version { return }
            // The updater may still be reading the staged app. The system clears temp files later.
            keepsWork = true
            throw UpdateInstallError.rejected("The update didn't finish. If Dictator was replaced, quit it and open it again.")
        }
    }

    private static func currentIdentity() -> AppIdentity? {
        let identity = AppIdentity.read(from: Bundle.main.bundleURL)
        guard identity.bundleIdentifier != nil, identity.version != nil else { return nil }
        return identity
    }
}
