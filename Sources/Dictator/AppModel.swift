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

    @ObservationIgnored private let hotkey = CarbonHotkey()
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let shortcutKey = "shortcut"

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

        let log = Logger(subsystem: "com.captainduckay.dictator", category: "state")
        controller.onStateChange = { [overlay] state in
            // State only — transcripts and audio are never logged.
            log.notice("state: \(String(describing: state), privacy: .public)")
            overlay.update(for: state)
        }
        hotkey.onPress = { controller.hotkeyPressed() }
        hotkey.onRelease = { controller.hotkeyReleased() }
        resumeHotkey()

        Task { await controller.loadModel() }
        if Permissions.microphone == .notDetermined {
            Task { _ = await Permissions.requestMicrophone() }
        }
    }

    func setShortcut(_ new: Shortcut) {
        do {
            try new.validate()
            try hotkey.register(new)
            shortcut = new
            shortcutError = nil
            defaults.set(try JSONEncoder().encode(new), forKey: Self.shortcutKey)
        } catch Shortcut.ValidationError.needsCommandOrControl {
            shortcutError = "Include ⌘ or ⌃ in the shortcut."
            resumeHotkey()
        } catch {
            shortcutError = String(describing: error)
            resumeHotkey()
        }
    }

    /// Unregisters the global shortcut while the user records a new one.
    func suspendHotkey() { hotkey.unregister() }

    func resumeHotkey() {
        do {
            try hotkey.register(shortcut)
        } catch {
            shortcutError = String(describing: error)
        }
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
