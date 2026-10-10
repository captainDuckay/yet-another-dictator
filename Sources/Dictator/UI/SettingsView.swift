import AppKit
import DictationCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var microphone = Permissions.microphone
    @State private var canType = Permissions.canPostEvents
    @State private var canListen = Permissions.canListenEvents
    @State private var requestedTyping = false
    @State private var requestedListening = false
    @State private var loginItem = LoginItem.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            ShortcutSection(model: model)

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem != .disabled },
                    set: { enabled in
                        loginItemError = LoginItem.set(enabled: enabled)
                        loginItem = LoginItem.status
                    }
                ))
                if loginItem == .needsApproval {
                    LabeledContent("Allow Dictator in Login Items to finish.") {
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                    }
                    .foregroundStyle(.secondary)
                }
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(.red)
                }
                Toggle(isOn: Binding(
                    get: { model.checksForUpdates },
                    set: { model.checksForUpdates = $0 }
                )) {
                    Text("Check for updates daily")
                    Text("Asks GitHub whether a newer version exists. Nothing is downloaded or installed, and dictation never uses the network.")
                }
                Toggle(isOn: Binding(
                    get: { model.keepsMicrophoneReady },
                    set: { model.keepsMicrophoneReady = $0 }
                )) {
                    Text("Keep microphone ready")
                    Text("Catches the first word even if you start speaking as you press the shortcut. macOS shows the microphone indicator while this is on. Audio is held in memory for under half a second and never saved.")
                }
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", granted: microphone == .granted) {
                    Task {
                        if microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
                        else { Permissions.openPrivacySettings("Privacy_Microphone") }
                        refresh()
                    }
                }
                PermissionRow(
                    title: "Input Monitoring (detect shortcut)",
                    granted: canListen,
                    actionTitle: requestedListening ? "Relaunch" : "Grant…"
                ) {
                    if requestedListening { return Permissions.relaunch() }
                    if !Permissions.requestListenEvents() { Permissions.openPrivacySettings("Privacy_ListenEvent") }
                    requestedListening = true
                    refresh()
                }
                PermissionRow(
                    title: "Accessibility (type into fields)",
                    granted: canType,
                    actionTitle: requestedTyping ? "Relaunch" : "Grant…"
                ) {
                    if requestedTyping { return Permissions.relaunch() }
                    if !Permissions.requestPostEvents() { Permissions.openPrivacySettings("Privacy_Accessibility") }
                    requestedTyping = true
                    refresh()
                }
                if (requestedListening && !canListen) || (requestedTyping && !canType) {
                    Text("After enabling Dictator in System Settings, relaunch to apply.")
                        .foregroundStyle(.secondary)
                }
                if !canListen || !canType {
                    // An older build's entry (e.g. the unsigned 0.1.0) can stay switched on in
                    // System Settings without applying to this build, and macOS won't ask again.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Already switched on in System Settings? macOS may be keeping the permission for an older copy of Dictator. Select Dictator in the list, remove it with −, then click Grant… here again.")
                            .foregroundStyle(.secondary)
                        HStack {
                            if !canListen {
                                Button("Open Input Monitoring…") { Permissions.openPrivacySettings("Privacy_ListenEvent") }
                            }
                            if !canType {
                                Button("Open Accessibility…") { Permissions.openPrivacySettings("Privacy_Accessibility") }
                            }
                        }
                    }
                }
            }

            Section("Model") {
                LabeledContent("Whisper Large v3 Turbo", value: model.controller.state.statusText)
                Picker("Language", selection: Binding(get: { model.language }, set: { model.language = $0 })) {
                    ForEach(DictationLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Runs entirely on this Mac. Audio never leaves the device and is not saved.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        // Show in the Dock and ⌘Tab while Settings is open so the window can be found again.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        // Poll: toggling a permission in System Settings posts no notification, and a menu bar
        // app does not reliably become active again when the user returns to this window.
        // (Accessibility and Input Monitoring may be cached per process until a relaunch.)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        microphone = Permissions.microphone
        canType = Permissions.canPostEvents
        canListen = Permissions.canListenEvents
        loginItem = LoginItem.status
        model.retryHotkeyIfNeeded()
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    var actionTitle = "Grant…"
    let grant: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(actionTitle, action: grant)
            }
        }
    }
}

/// Shows the shortcut on a keyboard. Click the button, then hold any keys and let go to record;
/// the keyboard lights up the keys as they are pressed.
private struct ShortcutSection: View {
    let model: AppModel
    @State private var monitor: Any?
    @State private var recorder = ChordRecorder()
    @State private var target = Target.dictate

    private enum Target { case dictate, undo }

    var body: some View {
        Section("Shortcut") {
            LabeledContent("Dictate") {
                Button(isRecording(.dictate) ? "Press keys… (click to cancel)" : model.shortcut.displayString) {
                    monitor == nil ? start(.dictate) : stop()
                }
                .monospaced()
            }
            LabeledContent("Undo last dictation") {
                HStack {
                    Button(isRecording(.undo) ? "Press keys… (click to cancel)" : model.undoShortcut?.displayString ?? "None") {
                        monitor == nil ? start(.undo) : stop()
                    }
                    .monospaced()
                    if model.undoShortcut != nil, monitor == nil {
                        Button("Clear") { model.clearUndoShortcut() }
                    }
                }
            }
            if let error = model.undoShortcutError {
                Text(error).foregroundStyle(.red)
            }
            KeyboardView(highlighted: monitor == nil ? model.shortcut.codes : recorder.held)
                .frame(maxWidth: .infinity)
            if let error = model.shortcutError {
                Text(error).foregroundStyle(.red)
            } else if monitor == nil, let note = passThroughNote {
                if note.isWarning {
                    Label(note.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text(note.text).foregroundStyle(.secondary)
                }
            }
            Text("Any key or combination works, including fn, Caps Lock and a single modifier like Right ⌥. Tap to start and stop. Hold to talk, release to finish.")
                .foregroundStyle(.secondary)
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stop()
        }
    }

    /// Only relevant when macOS gave us a listen-only tap, so the shortcut's keys can't be withheld.
    private var passThroughNote: (text: String, isWarning: Bool)? {
        guard model.hotkeyMode == .listenOnly else { return nil }
        let name = model.shortcut.displayString
        return switch model.shortcut.passThroughEffect {
        case .harmless: nil
        case .appShortcut:
            ("macOS only lets Dictator watch the keyboard, so \(name) also reaches the app you're in.", false)
        case .typing:
            ("macOS only lets Dictator watch the keyboard, so \(name) will also type or act in the app you're dictating into. Add ⌃ or ⌘, or use a single modifier like Right ⌥, fn or an F-key.", true)
        }
    }

    private func isRecording(_ which: Target) -> Bool {
        monitor != nil && target == which
    }

    private func start(_ which: Target) {
        target = which
        model.suspendHotkey()
        recorder = ChordRecorder()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard let keyEvent = KeyEvent(event) else { return event }
            if let codes = recorder.apply(keyEvent) {
                let keys = codes.map {
                    Shortcut.Key(code: $0, label: KeyLabels.label(forKeyCode: $0, typed: KeyboardLayout.character(for: $0)))
                }
                switch target {
                case .dictate: model.setShortcut(Shortcut(keys: keys))
                case .undo: model.setUndoShortcut(Shortcut(keys: keys))
                }
                stop(resume: false)
            }
            return nil
        }
    }

    private func stop(resume: Bool = true) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        recorder = ChordRecorder()
        if resume { model.resumeHotkey() }
    }
}

private extension KeyEvent {
    init?(_ event: NSEvent) {
        switch event.type {
        case .keyDown: self = .down(event.keyCode)
        case .keyUp: self = .up(event.keyCode)
        case .flagsChanged: self = .flagsChanged(event.keyCode, flags: UInt64(event.modifierFlags.rawValue))
        default: return nil
        }
    }
}
