import Carbon.HIToolbox
import DictationCore

/// System-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Chosen over `NSEvent` global monitors / CGEvent taps because it needs no Input Monitoring
/// permission and never sees any keystroke other than the registered shortcut.
@MainActor
final class CarbonHotkey {
    enum Failure: Error, CustomStringConvertible {
        case registrationFailed(OSStatus)
        var description: String {
            switch self {
            case .registrationFailed(let status):
                "macOS refused this shortcut (error \(status)). It may already be used by another app."
            }
        }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private static let signature: OSType = 0x4449_4354 // 'DICT'
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(event)
                let hotkey = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
                // Application-target Carbon events are dispatched on the main thread.
                MainActor.assumeIsolated {
                    if kind == UInt32(kEventHotKeyPressed) { hotkey.onPress?() }
                    if kind == UInt32(kEventHotKeyReleased) { hotkey.onRelease?() }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    func register(_ shortcut: Shortcut) throws {
        unregister()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { throw Failure.registrationFailed(status) }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private static func carbonModifiers(_ modifiers: Shortcut.Modifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}
