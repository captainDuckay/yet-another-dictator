/// macOS virtual key codes for keys that need special handling, plus modifier helpers.
public enum KeyCode {
    public static let leftControl: UInt16 = 0x3B
    public static let rightControl: UInt16 = 0x3E
    public static let leftOption: UInt16 = 0x3A
    public static let rightOption: UInt16 = 0x3D
    public static let leftShift: UInt16 = 0x38
    public static let rightShift: UInt16 = 0x3C
    public static let leftCommand: UInt16 = 0x37
    public static let rightCommand: UInt16 = 0x36
    public static let function: UInt16 = 0x3F
    /// Caps Lock only reports toggles, never a release, so it behaves as a momentary tap.
    public static let capsLock: UInt16 = 0x39

    /// Device-dependent modifier flag bits (IOKit `NX_DEVICE*KEYMASK`, `NX_SECONDARYFNMASK`), present
    /// in both `CGEventFlags` and `NSEvent.ModifierFlags` raw values.
    static let modifierFlagBits: [(code: UInt16, bit: UInt64)] = [
        (leftControl, 0x0000_0001), (rightControl, 0x0000_2000),
        (leftShift, 0x0000_0002), (rightShift, 0x0000_0004),
        (leftCommand, 0x0000_0008), (rightCommand, 0x0000_0010),
        (leftOption, 0x0000_0020), (rightOption, 0x0000_0040),
        (function, 0x0080_0000),
    ]

    /// F1–F20. Bare function keys rarely do anything in the focused app.
    public static let functionKeys: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    /// Modifier keys tracked through flags (everything except Caps Lock).
    public static func isModifier(_ code: UInt16) -> Bool {
        modifierFlagBits.contains { $0.code == code }
    }

    /// Maps right-hand modifiers onto their left-hand twin; other keys are unchanged.
    public static func leftSide(_ code: UInt16) -> UInt16 {
        switch code {
        case rightControl: leftControl
        case rightOption: leftOption
        case rightShift: leftShift
        case rightCommand: leftCommand
        default: code
        }
    }

    static func modifiers(in flags: UInt64) -> Set<UInt16> {
        Set(modifierFlagBits.filter { flags & $0.bit != 0 }.map(\.code))
    }
}

/// A raw keyboard event, independent of AppKit / CoreGraphics.
public enum KeyEvent: Equatable, Sendable {
    case down(UInt16)
    case up(UInt16)
    /// A modifier key changed; `flags` is the raw modifier flag word after the change.
    case flagsChanged(UInt16, flags: UInt64)
}

/// Tracks which physical keys are held and reports each individual change with the resulting set.
public struct KeyTracker: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case down, up }
    public struct Change: Equatable, Sendable {
        public let kind: Kind
        public let code: UInt16
        public let held: Set<UInt16>
    }

    public private(set) var held: Set<UInt16> = []

    public init() {}

    /// Key repeats produce no changes.
    public mutating func apply(_ event: KeyEvent) -> [Change] {
        switch event {
        case .down(let code):
            return held.insert(code).inserted ? [Change(kind: .down, code: code, held: held)] : []
        case .up(let code):
            return held.remove(code) != nil ? [Change(kind: .up, code: code, held: held)] : []
        case .flagsChanged(let code, let flags):
            // Flags are authoritative for modifiers, so a missed event can't leave one stuck.
            let now = KeyCode.modifiers(in: flags)
            let before = held.filter(KeyCode.isModifier)
            var changes: [Change] = []
            for released in before.subtracting(now).sorted() {
                held.remove(released)
                changes.append(Change(kind: .up, code: released, held: held))
            }
            for pressed in now.subtracting(before).sorted() {
                held.insert(pressed)
                changes.append(Change(kind: .down, code: pressed, held: held))
            }
            if code == KeyCode.capsLock {
                changes.append(Change(kind: .down, code: code, held: held.union([code])))
                changes.append(Change(kind: .up, code: code, held: held))
            }
            return changes
        }
    }
}

/// Detects when a shortcut chord is pressed and released.
///
/// The chord matches when exactly its keys are held. If it contains a non-modifier key, left and
/// right modifiers are interchangeable (⌃⌥D works with either ⌥); modifier-only chords are
/// side-specific so e.g. Right ⌥ alone can be used without hijacking Left ⌥.
public struct ChordMatcher: Sendable {
    public enum Action: Equatable, Sendable {
        case pressed
        case released
        /// A modifier-only chord was pressed, then another key joined it (e.g. ⌘ then C):
        /// the user was typing a different shortcut, not dictating.
        case interrupted
    }

    private let target: Set<UInt16>
    private let sideAgnostic: Bool
    private let modifierOnly: Bool
    private var tracker = KeyTracker()
    private var active = false
    private var swallowing: Set<UInt16> = []

    public init(_ shortcut: Shortcut) {
        let codes = Set(shortcut.keys.map(\.code))
        modifierOnly = codes.allSatisfy(KeyCode.isModifier)
        sideAgnostic = !modifierOnly
        target = sideAgnostic ? Set(codes.map(KeyCode.leftSide)) : codes
    }

    /// Returns the resulting actions and whether the event should be withheld from other apps.
    /// Only key down/up events of the chord's non-modifier keys are ever withheld.
    public mutating func handle(_ event: KeyEvent) -> (actions: [Action], swallow: Bool) {
        var actions: [Action] = []
        for change in tracker.apply(event) {
            let held = sideAgnostic ? Set(change.held.map(KeyCode.leftSide)) : change.held
            let matches = held == target
            if !active, matches, change.kind == .down {
                active = true
                actions.append(.pressed)
            } else if active, !matches {
                active = false
                actions.append(modifierOnly && change.kind == .down ? .interrupted : .released)
            }
        }
        return (actions, swallow(event))
    }

    private mutating func swallow(_ event: KeyEvent) -> Bool {
        switch event {
        case .down(let code) where active && target.contains(code):
            swallowing.insert(code)
            return true
        case .up(let code):
            return swallowing.remove(code) != nil
        default:
            return false
        }
    }
}

/// Records a new chord: every key held during one gesture, committed once all keys are released.
public struct ChordRecorder: Equatable, Sendable {
    private var tracker = KeyTracker()
    private var pressed: Set<UInt16> = []

    public init() {}

    /// Keys currently held down.
    public var held: Set<UInt16> { tracker.held }

    /// Returns the recorded chord once every key has been released.
    public mutating func apply(_ event: KeyEvent) -> Set<UInt16>? {
        for change in tracker.apply(event) {
            if change.kind == .down { pressed.insert(change.code) }
            if change.held.isEmpty, !pressed.isEmpty {
                defer { pressed = [] }
                return pressed
            }
        }
        return nil
    }
}
