import AppKit
import DictationCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var microphone = Permissions.microphone
    @State private var canType = Permissions.canPostEvents
    @State private var requestedTyping = false

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Dictate") {
                    ShortcutRecorder(model: model)
                }
                if let error = model.shortcutError {
                    Text(error).foregroundStyle(.red)
                }
                Text("Tap to start and stop. Hold to talk, release to finish.")
                    .foregroundStyle(.secondary)
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
                    title: "Accessibility (type into fields)",
                    granted: canType,
                    actionTitle: requestedTyping ? "Relaunch" : "Grant…"
                ) {
                    if requestedTyping { return Permissions.relaunch() }
                    if !Permissions.requestPostEvents() { Permissions.openPrivacySettings("Privacy_Accessibility") }
                    requestedTyping = true
                    refresh()
                }
                if requestedTyping && !canType {
                    Text("After enabling Dictator in System Settings, relaunch to apply.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                LabeledContent("Whisper Large v3 Turbo", value: model.controller.state.statusText)
                Text("Runs entirely on this Mac. Audio never leaves the device and is not saved.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        // Poll: toggling a permission in System Settings posts no notification, and a menu bar
        // app does not reliably become active again when the user returns to this window.
        // (Accessibility is cached per process, so only the microphone updates live.)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private func refresh() {
        microphone = Permissions.microphone
        canType = Permissions.canPostEvents
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

/// Click, then press the new key combination. Esc cancels.
private struct ShortcutRecorder: View {
    let model: AppModel
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? model.shortcut.displayString : "Press shortcut…") {
            monitor == nil ? start() : stop()
        }
        .monospaced()
        .onDisappear { stop() }
    }

    private func start() {
        model.suspendHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = Shortcut.Modifiers(event.modifierFlags)
            if event.keyCode == 0x35, modifiers.isEmpty {
                stop()
                return nil
            }
            let keyCode = UInt32(event.keyCode)
            model.setShortcut(Shortcut(
                keyCode: keyCode,
                modifiers: modifiers,
                keyLabel: KeyLabels.label(forKeyCode: keyCode, typed: event.charactersIgnoringModifiers)
            ))
            stop(resume: false)
            return nil
        }
    }

    private func stop(resume: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if resume { model.resumeHotkey() }
    }
}

private extension Shortcut.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}
