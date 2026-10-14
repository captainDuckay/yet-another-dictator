import AppKit
import AppUpdate
import DictationCore
import OSLog

/// Daily check, and installing the release the user picks. Downloading happens only after Install.
@MainActor
@Observable
final class UpdateController {
    private(set) var available: OfferedUpdate?
    private(set) var isChecking = false
    private(set) var phase: UpdatePhase = .idle

    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Self.checksKey) }
    }

    @ObservationIgnored private let checker = UpdateChecker()
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private var lastPercent = -1
    private static let checksKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedKey = "notifiedUpdateVersion"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "update")

    init(overlay: OverlayPanel, defaults: UserDefaults = .standard, installer: UpdateInstaller = UpdateInstaller()) {
        self.installer = installer
        self.overlay = overlay
        self.defaults = defaults
        checksForUpdates = defaults.object(forKey: Self.checksKey) as? Bool ?? true
    }

    func start() {
        Task { await runDaily() }
        Task { await removePreviousCopy() }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.pageURL)
    }

    func install() {
        guard let available, available.canInstall, phase.allowsCheck else { return }
        if AppLocation.isTranslocated(path: Bundle.main.bundleURL.resolvingSymlinksInPath().path) {
            fail(.translocated)
            return
        }
        // Set before the task starts so a second Install or a check is refused right away.
        lastPercent = -1
        apply(.downloading(0))
        let update = available
        let report: @Sendable (UpdatePhase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.apply(phase) }
        }
        let installer = installer
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await installer.install(update, progress: report)
                }.value
                relaunch()
            } catch let error as UpdateInstallError {
                fail(error)
            } catch {
                fail(.download)
            }
        }
    }

    private func apply(_ phase: UpdatePhase) {
        switch phase {
        case .downloading(let fraction):
            let percent = Int((min(1, max(0, fraction)) * 100).rounded())
            guard percent > lastPercent else { return }
            lastPercent = percent
            self.phase = .downloading(Double(percent) / 100)
            overlay.present("Downloading update… \(percent)%")
        case .checking:
            self.phase = phase
            overlay.present("Checking update…")
        case .installing:
            self.phase = phase
            overlay.present("Installing update…")
        case .idle, .failed:
            self.phase = phase
        }
    }

    private func fail(_ error: UpdateInstallError) {
        phase = .failed(error.message)
        overlay.present(nil)
        overlay.flash(error.message)
        Self.log.error("\(error.message, privacy: .public)")
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        SingleInstance.markRelaunch()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if error != nil {
                    self.overlay.present("Update installed. Quit Dictator and open it again.")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func removePreviousCopy() async {
        if let message = await UpdateClient.removePreviousCopy() {
            Self.log.error("\(message, privacy: .public)")
        }
    }

    private func runDaily() async {
        while !Task.isCancelled {
            let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
            if checksForUpdates, UpdateCheck.isDue(lastCheck: lastCheck, now: Date()) {
                await check(userInitiated: false)
            }
            try? await Task.sleep(for: .seconds(60 * 60))
        }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking, phase.allowsCheck, let current = WhatsNewWindow.currentVersion else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let update = try await checker.newestRelease(above: current)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            available = update
            if phase.allowsCheck, case .failed = phase { phase = .idle }
            if let update {
                let version = update.version.description
                if userInitiated || defaults.string(forKey: Self.notifiedKey) != version {
                    defaults.set(version, forKey: Self.notifiedKey)
                    let verb = update.canInstall ? "install it" : "get it"
                    overlay.flash("Dictator \(version) is available. Open the menu bar menu to \(verb).", isInfo: true)
                }
            } else if userInitiated {
                overlay.flash("Dictator \(current.description) is up to date.", isInfo: true)
            }
            Self.log.notice("update check: \(update?.version.description ?? "none", privacy: .public)")
        } catch {
            Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { overlay.flash("Couldn't check for updates: \(error.localizedDescription)") }
        }
    }
}
