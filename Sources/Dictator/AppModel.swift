import AppKit
import DictationCore
import Observation
import OSLog
import WhisperTranscription

/// Composition root: builds the concrete adapters and wires them to the core controller.
@MainActor
@Observable
final class AppModel {
    let controller: DictationController
    /// Dictation and undo shortcuts (registration, storage, errors).
    let shortcuts: ShortcutSettings
    var shortcut: Shortcut { shortcuts.shortcut }
    var undoShortcut: Shortcut? { shortcuts.undoShortcut }
    var undoShortcutError: String? { shortcuts.undoShortcutError }
    var shortcutError: String? { shortcuts.shortcutError }
    var hotkeyMode: EventTapHotkey.Mode? { shortcuts.hotkeyMode }

    /// Keep the microphone running between dictations so the first syllable is never cut off.
    var keepsMicrophoneReady: Bool {
        didSet {
            defaults.set(keepsMicrophoneReady, forKey: Self.keepsMicrophoneReadyKey)
            recorder.setKeepsReady(keepsMicrophoneReady)
        }
    }

    @ObservationIgnored private let recorder: MicrophoneRecorder
    @ObservationIgnored private let hotkey: EventTapHotkey
    @ObservationIgnored private let whatsNew = WhatsNewWindow()
    @ObservationIgnored private let updateChecker = UpdateChecker()

    /// A newer release found by the update check, shown in the menu.
    private(set) var availableUpdate: AvailableUpdate?
    private(set) var isCheckingForUpdates = false
    /// Daily check for a newer release on GitHub. On by default; off means no network use at all.
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Self.checksForUpdatesKey) }
    }
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isMenuOpen = false
    private static let lastSeenVersionKey = "lastSeenVersion"
    private static let checksForUpdatesKey = "checkForUpdates"
    private static let lastUpdateCheckKey = "lastUpdateCheck"
    private static let notifiedUpdateKey = "notifiedUpdateVersion"
    private static let keepsMicrophoneReadyKey = "keepMicrophoneReady"
    private static let languageKey = "language"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "state")

    /// First-launch model download (ADR 0004).
    let modelDownload: ModelDownload

    init() {
        let modelDownload = ModelDownload(transport: RangedTransport())
        self.modelDownload = modelDownload
        let modelFolder = modelDownload.folder
        let recorder = MicrophoneRecorder()
        self.recorder = recorder
        let controller = DictationController(
            recorder: recorder,
            transcriber: WhisperKitTranscriber(modelFolder: modelFolder),
            inserter: KeystrokeTextInserter(),
            precedingText: FocusedTextReader()
        )
        self.controller = controller
        self.overlay = OverlayPanel(controller: controller)
        let hotkey = EventTapHotkey()
        self.hotkey = hotkey
        self.shortcuts = ShortcutSettings(hotkey: hotkey, defaults: .standard)
        self.checksForUpdates = defaults.object(forKey: Self.checksForUpdatesKey) as? Bool ?? true
        self.keepsMicrophoneReady = defaults.bool(forKey: Self.keepsMicrophoneReadyKey)
        controller.language = DictationLanguage(storedValue: defaults.string(forKey: Self.languageKey))

        let log = Self.log
        controller.onStateChange = { [overlay] state in
            // State only — transcripts and audio are never logged.
            log.notice("state: \(String(describing: state), privacy: .public)")
            overlay.update(for: state)
        }
        recorder.onCapacityReached = { controller.recordingReachedLimit() }
        recorder.onFailure = { message in
            log.error("microphone: \(message, privacy: .public)")
            controller.recordingFailed(message)
        }
        controller.onTiming = { timing in
            // Durations only; never text or audio.
            log.notice("dictation: \(timing.audioSeconds, format: .fixed(precision: 1), privacy: .public) s audio, release→typed \(timing.releaseToTypedSeconds, format: .fixed(precision: 2), privacy: .public) s, transcription \(timing.transcriptionSeconds, format: .fixed(precision: 2), privacy: .public) s")
        }
        controller.onError = { [overlay] message in overlay.flash(message) }
        hotkey.onPress = { controller.hotkeyPressed() }
        hotkey.onRelease = { controller.hotkeyReleased() }
        hotkey.onInterrupt = { controller.cancel() }
        // Smart spacing: know when the cursor may have moved since the last dictation.
        hotkey.onUndo = { Task { await controller.undoLastDictation() } }
        // Clicks and arrow keys inside our own menu don't move the text cursor.
        hotkey.onOtherInput = { [weak self] in
            if self?.isMenuOpen != true { controller.noteOtherInput() }
        }
        let center = NotificationCenter.default
        _ = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuOpen = true }
        }
        _ = center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuOpen = false }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { controller.noteOtherInput() }
        }

        if ProcessInfo.processInfo.environment["DICTATOR_SETTINGS_PREVIEW"] == "1" {
            // Visual check only: show Settings without a keyboard tap, microphone, or download.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } else {
            Task {
                // Another copy already running owns the keyboard tap; quit before installing ours.
                guard await SingleInstance.claim() else {
                    NSApp.terminate(nil)
                    return
                }
                start()
            }
        }
    }

    private func start() {
        showWhatsNewIfUpdated()
        Task { await runDailyUpdateChecks() }
        shortcuts.start()
        Task { await downloadAndLoadModel() }
        Task {
            if Permissions.microphone == .notDetermined {
                _ = await Permissions.requestMicrophone()
            }
            recorder.prepare()
            recorder.setKeepsReady(keepsMicrophoneReady)
        }
    }

    /// Downloads the model if needed (automatically, on first launch), then loads it.
    func downloadAndLoadModel() async {
        guard await modelDownload.ensureInstalled() else { return }
        await controller.loadModel()
    }

    /// "Check for Updates…": checks now and always says what it found.
    func checkForUpdatesNow() {
        Task { await checkForUpdates(userInitiated: true) }
    }

    func openUpdatePage() {
        guard let availableUpdate else { return }
        NSWorkspace.shared.open(availableUpdate.pageURL)
    }

    private func runDailyUpdateChecks() async {
        while !Task.isCancelled {
            let lastCheck = defaults.object(forKey: Self.lastUpdateCheckKey) as? Date
            if checksForUpdates, UpdateCheck.isDue(lastCheck: lastCheck, now: Date()) {
                await checkForUpdates(userInitiated: false)
            }
            try? await Task.sleep(for: .seconds(60 * 60))
        }
    }

    private func checkForUpdates(userInitiated: Bool) async {
        guard !isCheckingForUpdates, let current = WhatsNewWindow.currentVersion else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            let update = try await updateChecker.newestRelease(above: current)
            defaults.set(Date(), forKey: Self.lastUpdateCheckKey)
            availableUpdate = update
            if let update {
                let version = update.version.description
                // Automatic checks mention each new version once; the menu item stays until updated.
                if userInitiated || defaults.string(forKey: Self.notifiedUpdateKey) != version {
                    defaults.set(version, forKey: Self.notifiedUpdateKey)
                    overlay.flash("Dictator \(version) is available. Open the menu bar menu to get it.", isInfo: true)
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

    func showWhatsNew() {
        whatsNew.showCurrent()
    }

    /// Shows the release notes once, on the first launch after the version changed. A fresh
    /// install gets a short welcome with this version's notes instead.
    private func showWhatsNewIfUpdated() {
        guard let current = WhatsNewWindow.currentVersion else { return }
        let lastSeen = defaults.string(forKey: Self.lastSeenVersionKey)
        defaults.set(current.description, forKey: Self.lastSeenVersionKey)
        switch WhatsNew.decide(current: current, lastSeen: lastSeen, changelog: WhatsNewWindow.bundledChangelog()) {
        case .none:
            break
        case .welcome(let entries):
            whatsNew.show(.init(
                title: "Welcome to Dictator",
                intro: "Press your shortcut (\(shortcut.displayString)), speak, and the text is typed where your cursor is.",
                entries: entries
            ))
        case .updated(let entries):
            whatsNew.show(.init(title: "What's New in Dictator", intro: "Updated to \(current.description)", entries: entries))
        }
    }

    func setShortcut(_ new: Shortcut) { shortcuts.setShortcut(new) }
    func setUndoShortcut(_ new: Shortcut) { shortcuts.setUndoShortcut(new) }
    func clearUndoShortcut() { shortcuts.clearUndoShortcut() }

    var language: DictationLanguage {
        get { controller.language }
        set {
            controller.language = newValue
            defaults.set(newValue.rawValue, forKey: Self.languageKey)
        }
    }

    /// Unregisters the global shortcut while the user records a new one.
    func suspendHotkey() { shortcuts.suspendHotkey() }
    func resumeHotkey() { shortcuts.resumeHotkey() }
    /// Retries registration, e.g. after the user granted Input Monitoring.
    func retryHotkeyIfNeeded() { shortcuts.retryHotkeyIfNeeded() }
}
