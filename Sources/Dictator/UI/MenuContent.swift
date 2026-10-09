import AppKit
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.controller.state.statusText)
        Text("Shortcut: \(model.shortcut.displayString)")
        if let error = model.controller.lastError {
            Text(error)
        }
        if model.controller.state == .recording || model.controller.state == .transcribing {
            Button("Cancel Dictation") { model.controller.cancel() }
        }
        Button(undoTitle) {
            // Let the menu close so the field you dictated into has keyboard focus again.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                model.controller.undoLastDictation()
            }
        }
        .disabled(!model.controller.canUndo)
        if let text = model.controller.undeliveredTranscript {
            Divider()
            Text("Not typed: “\(Self.preview(text))”")
            Button("Type It Again") {
                // Let the menu close so the field you were in has keyboard focus again.
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    model.controller.retryUndelivered()
                }
            }
            Button("Discard") { model.controller.discardUndelivered() }
        }
        Divider()
        if let update = model.availableUpdate {
            Button("Update Available: v\(update.version.description)…") { model.openUpdatePage() }
        }
        Button(model.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
            model.checkForUpdatesNow()
        }
        .disabled(model.isCheckingForUpdates)
        Button("What's New") { model.showWhatsNew() }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Dictator") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var undoTitle: String {
        if let shortcut = model.undoShortcut {
            "Undo Last Dictation (\(shortcut.displayString))"
        } else {
            "Undo Last Dictation"
        }
    }

    private static func preview(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(59)) + "…"
    }
}
