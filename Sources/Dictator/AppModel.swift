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
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isSuspended = false
    /// False until this copy is confirmed to be the only one running.
    @ObservationIgnored private var isStarted = false
    private static let shortcutKey = "shortcut"
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
        // Smart spacing: know when the cursor may have moved since the last dictation.
        hotkey.onOtherInput = { controller.noteOtherInput() }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { controller.noteOtherInput() }
        }
        controller.textBeforeCursor = { FocusedText.textBeforeCursor() }

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
