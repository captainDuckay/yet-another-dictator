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

    @ObservationIgnored private let hotkey = EventTapHotkey()
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isSuspended = false
    private static let shortcutKey = "shortcut"
    private static let log = Logger(subsystem: "com.captainduckay.dictator", category: "state")

    init() {
        let modelFolder = WhisperKitTranscriber.bundledModelFolder()
            ?? URL(filePath: "/nonexistent", directoryHint: .isDirectory)
        let controller = DictationController(
            recorder: MicrophoneRecorder(),
            transcriber: WhisperKitTranscriber(modelFolder: modelFolder),
            inserter: KeystrokeTextInserter()
        )
        self.controller = controller
        self.overlay = OverlayPanel(controller: controller)
        self.shortcut = Self.loadShortcut(from: defaults)

        let log = Self.log
        controller.onStateChange = { [overlay] state in
            // State only — transcripts and audio are never logged.
            log.notice("state: \(String(describing: state), privacy: .public)")
            overlay.update(for: state)
        }
        hotkey.onPress = { controller.hotkeyPressed() }
        hotkey.onRelease = { controller.hotkeyReleased() }
        hotkey.onInterrupt = { controller.cancel() }
        resumeHotkey()

        Task { await controller.loadModel() }
        if Permissions.microphone == .notDetermined {
            Task { _ = await Permissions.requestMicrophone() }
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
        if !hotkey.isRegistered, !isSuspended { resumeHotkey() }
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
