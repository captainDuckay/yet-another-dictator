import CoreGraphics
import DictationCore
import Foundation

/// Types text into the focused field by synthesising Unicode key events.
///
/// Deliberately avoids the clipboard: pasting would expose every dictation to clipboard managers
/// and other apps reading the pasteboard, and would clobber the user's clipboard.
@MainActor
final class KeystrokeTextInserter: TextInserting {
    enum Failure: LocalizedError {
        case notPermitted, eventCreationFailed
        var errorDescription: String? {
            switch self {
            case .notPermitted: "Dictator needs Accessibility permission to type. Enable it in System Settings → Privacy & Security → Accessibility, then relaunch Dictator."
            case .eventCreationFailed: "Could not create keyboard events."
            }
        }
    }

    func insert(_ text: String) throws {
        guard Permissions.canPostEvents else {
            Permissions.requestPostEvents()
            throw Failure.notPermitted
        }
        // A private event source keeps physically held modifiers (e.g. from the hotkey) out of our events.
        let source = CGEventSource(stateID: .privateState)
        for chunk in TextChunker.chunks(text) {
            let utf16 = Array(chunk.utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    throw Failure.eventCreationFailed
                }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
