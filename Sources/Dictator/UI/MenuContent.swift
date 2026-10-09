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
        if model.controller.state == .recording {
            Button("Cancel Dictation") { model.controller.cancel() }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Dictator") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
