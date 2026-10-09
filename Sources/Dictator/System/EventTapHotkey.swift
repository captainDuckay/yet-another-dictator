import CoreGraphics
import DictationCore
import Foundation

/// System-wide shortcut via a CoreGraphics event tap, so any key or chord can be used:
/// modifier-only (e.g. Right ⌥), fn, Caps Lock, bare keys, several keys at once.
///
/// Needs Input Monitoring permission. Events are only matched against the shortcut in memory;
/// nothing is stored or logged. The shortcut's own non-modifier keys are withheld from other apps
/// when macOS allows an active tap; otherwise the tap is listen-only and they pass through.
@MainActor
final class EventTapHotkey {
    enum Failure: Error, CustomStringConvertible {
        case inputMonitoringDenied
        case tapUnavailable
        var description: String {
            switch self {
            case .inputMonitoringDenied:
                "Grant Input Monitoring so Dictator can detect the shortcut, then reopen this window."
            case .tapUnavailable:
                "macOS refused to watch the keyboard. Check Input Monitoring, then relaunch Dictator."
            }
        }
    }

    /// How the tap was installed. macOS may refuse a tap that can withhold events (e.g. for a
    /// sandboxed app); the listen-only fallback still detects the shortcut, but its keys then also
    /// reach the focused app.
    enum Mode: Equatable, Sendable {
        case withholdsKeys
        case listenOnly
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onInterrupt: (() -> Void)?

    private(set) var isRegistered = false
    /// The mode of the current tap, or of the last one when unregistered; nil until first registered.
    private(set) var mode: Mode?
    private var shortcut: Shortcut?
    private var matcher: ChordMatcher?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)

    func register(_ shortcut: Shortcut) throws {
        unregister()
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            throw Failure.inputMonitoringDenied
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hotkey = Unmanaged<EventTapHotkey>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run loop source is on the main run loop.
            let swallow = MainActor.assumeIsolated { hotkey.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        func create(_ options: CGEventTapOptions) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                eventsOfInterest: mask, callback: callback, userInfo: refcon
            )
        }
        let tap: CFMachPort
        if let active = create(.defaultTap) {
            tap = active
            mode = .withholdsKeys
        } else if let passive = create(.listenOnly) {
            tap = passive
            mode = .listenOnly
        } else {
            throw Failure.tapUnavailable
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        self.shortcut = shortcut
        matcher = ChordMatcher(shortcut)
        isRegistered = true
    }

    func unregister() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        matcher = nil
        shortcut = nil
        isRegistered = false
    }

    /// Returns true to withhold the event from other apps.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Keys may have been released while disabled; start tracking afresh.
            if let tap, let shortcut {
                matcher = ChordMatcher(shortcut)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        default:
            break
        }
        // Ignore the text we type ourselves.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != ownPID else { return false }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let keyEvent: KeyEvent
        switch type {
        case .keyDown: keyEvent = .down(code)
        case .keyUp: keyEvent = .up(code)
        case .flagsChanged: keyEvent = .flagsChanged(code, flags: event.flags.rawValue)
        default: return false
        }
        guard var matcher else { return false }
        let (actions, swallow) = matcher.handle(keyEvent)
        self.matcher = matcher
        for action in actions {
            switch action {
            case .pressed: onPress?()
            case .released: onRelease?()
            case .interrupted: onInterrupt?()
            }
        }
        return swallow
    }
}
