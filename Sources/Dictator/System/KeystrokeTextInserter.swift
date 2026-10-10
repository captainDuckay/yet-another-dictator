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

    func preflight() throws {
        guard Permissions.canPostEvents else {
            Permissions.requestPostEvents()
            throw Failure.notPermitted
        }
    }

    /// Chunks posted between yields: often enough that the main thread (menu, Cancel, the
    /// shortcut) stays responsive while a long dictation is typed.
    private static let chunksPerYield = 8

    func deleteBackward(_ count: Int) async throws {
        try preflight()
        let source = CGEventSource(stateID: .privateState)
        let delete: CGKeyCode = 0x33 // kVK_Delete (Backspace)
        for index in 0..<count {
            try await pause(before: index)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: keyDown) else {
                    throw Failure.eventCreationFailed
                }
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }
    }

    func insert(_ text: String) async throws {
        try preflight()
        // A private event source keeps physically held modifiers (e.g. from the hotkey) out of our events.
        let source = CGEventSource(stateID: .privateState)
        for (index, chunk) in TextChunker.chunks(text).enumerated() {
            try await pause(before: index)
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

    /// Stops between chunks if the task was cancelled (Cancel Dictation), and every few chunks
    /// lets other main-actor work run.
    private func pause(before index: Int) async throws {
        if Task.isCancelled { throw CancellationError() }
        if index > 0, index.isMultiple(of: Self.chunksPerYield) {
            await Task.yield()
            if Task.isCancelled { throw CancellationError() }
        }
    }
}
