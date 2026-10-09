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
    private(set) var shortcut: Shortcut
    private(set) var shortcutError: String?
    /// How the shortcut is being watched; nil until the hotkey was registered once.
    private(set) var hotkeyMode: EventTapHotkey.Mode?

    /// Keep the microphone running between dictations so the first syllable is never cut off.
    var keepsMicrophoneReady: Bool {
        didSet {
            defaults.set(keepsMicrophoneReady, forKey: Self.keepsMicrophoneReadyKey)
            recorder.setKeepsReady(keepsMicrophoneReady)
        }
    }

    @ObservationIgnored private let recorder: MicrophoneRecorder
    @ObservationIgnored private let hotkey = EventTapHotkey()
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
    @ObservationIgnored private var isSuspended = false
    /// False until this copy is confirmed to be the only one running.
    @ObservationIgnored private var isStarted = false
    private static let shortcutKey = "shortcut"
    private static let lastSeenVersionKey = "lastSeenVersion"
    private static let checksForUpdatesKey = "checkForUpdates"
    private static let lastUpdateCheckKey = "lastUpdateCheck"
    private static let notifiedUpdateKey = "notifiedUpdateVersion"
    private static let keepsMicrophoneReadyKey = "keepMicrophoneReady"
    private static let languageKey = "language"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "state")

    init() {
        let modelFolder = WhisperKitTranscriber.bundledModelFolder()
            ?? URL(filePath: "/nonexistent", directoryHint: .isDirectory)
        let recorder = MicrophoneRecorder()
        self.recorder = recorder
        let controller = DictationController(
            recorder: recorder,
            transcriber: WhisperKitTranscriber(modelFolder: modelFolder),
            inserter: KeystrokeTextInserter()
        )
        self.controller = controller
        self.overlay = OverlayPanel(controller: controller)
        self.shortcut = Self.loadShortcut(from: defaults)
        self.checksForUpdates = defaults.object(forKey: Self.checksForUpdatesKey) as? Bool ?? true
        self.keepsMicrophoneReady = defaults.bool(forKey: Self.keepsMicrophoneReadyKey)
        controller.language = DictationLanguage(storedValue: defaults.string(forKey: Self.languageKey))

        let log = Self.log
        controller.onStateChange = { [overlay] state in
            // State only — transcripts and audio are never logged.
            log.notice("state: \(String(describing: state), privacy: .public)")
            overlay.update(for: state)
        }
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

        Task {
            // Another copy already running owns the keyboard tap; quit before installing ours.
            guard await SingleInstance.claim() else {
                NSApp.terminate(nil)
                return
            }
            start()
        }
    }

    private func start() {
        isStarted = true
        showWhatsNewIfUpdated()
        Task { await runDailyUpdateChecks() }
        resumeHotkey()
        Task { await controller.loadModel() }
        Task {
            if Permissions.microphone == .notDetermined {
                _ = await Permissions.requestMicrophone()
            }
            recorder.prepare()
            recorder.setKeepsReady(keepsMicrophoneReady)
        }
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

    func setShortcut(_ new: Shortcut) {
        isSuspended = false
        do {
            try new.validate()
            try hotkey.register(new)
            noteHotkeyMode()
            shortcut = new
            shortcutError = nil
            defaults.set(try JSONEncoder().encode(new), forKey: Self.shortcutKey)
        } catch Shortcut.ValidationError.empty {
            shortcutError = "Press at least one key."
            resumeHotkey()
        } catch {
            shortcutError = String(describing: error)
            resumeHotkey()
        }
    }

    var language: DictationLanguage {
        get { controller.language }
        set {
            controller.language = newValue
            defaults.set(newValue.rawValue, forKey: Self.languageKey)
        }
    }

    /// Unregisters the global shortcut while the user records a new one.
    func suspendHotkey() {
        isSuspended = true
        hotkey.unregister()
    }

    func resumeHotkey() {
        isSuspended = false
        do {
            try hotkey.register(shortcut)
            noteHotkeyMode()
            shortcutError = nil
        } catch {
            shortcutError = String(describing: error)
        }
    }

    private func noteHotkeyMode() {
        guard hotkeyMode != hotkey.mode else { return }
        hotkeyMode = hotkey.mode
        let mode = hotkey.mode.map { "\($0)" } ?? "none"
        Self.log.notice("hotkey tap: \(mode, privacy: .public)")
    }

    /// Retries registration, e.g. after the user granted Input Monitoring.
    func retryHotkeyIfNeeded() {
        if isStarted, !hotkey.isRegistered, !isSuspended { resumeHotkey() }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> Shortcut {
        guard
            let data = defaults.data(forKey: shortcutKey),
            let stored = try? JSONDecoder().decode(Shortcut.self, from: data),
            (try? stored.validate()) != nil
        else { return .default }
        return stored
    }
}
