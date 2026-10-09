/// A global keyboard shortcut: one key plus modifiers.
///
/// `keyCode` is the macOS virtual key code (layout independent). `keyLabel` is what the
/// user saw when recording it, so we don't need keyboard-layout lookups to display it.
public struct Shortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// ⌃⌥D — "D for dictate". Not bound by macOS by default.
    public static let `default` = Shortcut(keyCode: 0x02, modifiers: [.control, .option], keyLabel: "D")

    /// Display string in the conventional macOS modifier order, e.g. "⌃⌥⇧⌘D".
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    public enum ValidationError: Error, Equatable, Sendable {
        /// macOS 15+ rejects global hotkeys without ⌘ or ⌃, and bare keys would hijack typing.
        case needsCommandOrControl
    }

    public func validate() throws(ValidationError) {
        guard !modifiers.isDisjoint(with: [.command, .control]) else { throw .needsCommandOrControl }
    }
}
