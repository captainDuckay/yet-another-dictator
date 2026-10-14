import AppKit
import DictationCore
import Observation
import OSLog
import ParakeetTranscription
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

    /// Which input device dictation records from.
    let microphone: MicrophoneSettings
    @ObservationIgnored private let recorder: MicrophoneRecorder
    @ObservationIgnored private let hotkey: EventTapHotkey
    @ObservationIgnored private let whatsNew = WhatsNewWindow()
    /// Daily check, and installing a release when the user asks.
    let updates: UpdateController
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isMenuOpen = false
    private static let lastSeenVersionKey = "lastSeenVersion"
    private static let keepsMicrophoneReadyKey = "keepMicrophoneReady"
    private static let languageKey = "language"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "state")

    /// Downloads only the model the user chose (ADR 0006).
    let modelDownload: ModelDownload
    /// Which speech model the user chose; unset until they pick one.
    let modelChoice: ModelChoice
    @ObservationIgnored private let engine: ActiveTranscriber
    @ObservationIgnored private let modelPicker = ModelPickerWindow()

    init() {
        self.modelDownload = ModelDownload.bundled(transport: RangedTransport())
        self.modelChoice = ModelChoice(defaults: .standard)
        let engine = ActiveTranscriber()
        self.engine = engine
        let recorder = MicrophoneRecorder()
        self.recorder = recorder
        let microphone = MicrophoneSettings(source: AudioInputDeviceMonitor(), defaults: .standard)
        self.microphone = microphone
        recorder.setPreferredDevice(uid: microphone.choice?.uid)
        microphone.onChoiceChange = { uid in recorder.setPreferredDevice(uid: uid) }
        microphone.onDevicesChange = { recorder.inputDevicesChanged() }
        microphone.start()
        let controller = DictationController(
            recorder: recorder,
            transcriber: engine,
            inserter: KeystrokeTextInserter(),
            precedingText: FocusedTextReader()
        )
        self.controller = controller
        let overlay = OverlayPanel(controller: controller)
        self.overlay = overlay
        self.updates = UpdateController(overlay: overlay)
        let hotkey = EventTapHotkey()
        self.hotkey = hotkey
        self.shortcuts = ShortcutSettings(hotkey: hotkey, defaults: .standard)
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
        updates.start()
        shortcuts.start()
        startModel()
        Task {
            if Permissions.microphone == .notDetermined {
                _ = await Permissions.requestMicrophone()
            }
            recorder.prepare()
            recorder.setKeepsReady(keepsMicrophoneReady)
        }
    }

    /// Nothing is downloaded until a model is chosen. With no choice yet, the picker is shown.
    private func startModel() {
        switch ModelStartup.decide(choice: modelChoice.selected, installed: modelDownload.installedModels) {
        case .showPicker:
            Task { await controller.loadModel() } // Shows "choose a model" until one is picked.
            showModelPicker()
        case .load(let model):
            if modelChoice.selected == nil { modelChoice.choose(model) }
            Task { await downloadAndLoadModel() }
        }
    }

    func showModelPicker() {
        modelPicker.show(download: modelDownload) { [weak self] model in
            self?.chooseModel(model)
        }
    }

    /// Persists the choice, then downloads (if needed) and loads only that model.
    func chooseModel(_ model: SpeechModel) {
        modelChoice.choose(model)
        Task { await downloadAndLoadModel() }
    }

    /// Downloads the chosen model if it is missing, then loads it.
    func downloadAndLoadModel() async {
        guard let model = modelChoice.selected else { return }
        modelDownload.select(model)
        guard await modelDownload.ensureInstalled(), modelChoice.selected == model else { return }
        let folder = modelDownload.folder
        let transcriber: any Transcribing = switch model {
        case .parakeetV2: ParakeetTranscriber(modelFolder: folder)
        case .whisperLargeV3Turbo: WhisperKitTranscriber(modelFolder: folder)
        }
        await engine.use(transcriber)
        await controller.loadModel()
    }

    /// Frees the space of a model that isn't in use.
    func deleteModel(_ model: SpeechModel) {
        do {
            try modelDownload.delete(model)
        } catch {
            Self.log.error("deleting model failed: \(String(describing: error), privacy: .public)")
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
