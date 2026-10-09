/// A global keyboard shortcut: any combination of physical keys held together.
///
/// Codes are macOS virtual key codes (layout independent). Each key keeps the label the user saw
/// when recording it, so we don't need keyboard-layout lookups to display it.
public struct Shortcut: Equatable, Sendable {
    public struct Key: Codable, Hashable, Sendable {
        public var code: UInt16
        public var label: String

        public init(code: UInt16, label: String) {
            self.code = code
            self.label = label
        }
    }

    /// Sorted in display order: modifiers first (fn ⌃ ⌥ ⇧ ⌘), then other keys by code.
    public private(set) var keys: [Key]

    public init(keys: [Key]) {
        var seen = Set<UInt16>()
        self.keys = keys.filter { seen.insert($0.code).inserted }.sorted { Self.order($0.code) < Self.order($1.code) }
    }

    /// ⌃⌥D — "D for dictate". Not bound by macOS by default.
    public static let `default` = Shortcut(keys: [
        Key(code: KeyCode.leftControl, label: "⌃"),
        Key(code: KeyCode.leftOption, label: "⌥"),
        Key(code: 0x02, label: "D"),
    ])

    public var codes: Set<UInt16> { Set(keys.map(\.code)) }

    /// e.g. "⌃⌥D", "⌘A+S", "Right ⌥", "fn".
    public var displayString: String {
        let modifiers = keys.filter { KeyCode.isModifier($0.code) }
        let others = keys.filter { !KeyCode.isModifier($0.code) }
        if others.isEmpty {
            return modifiers.map { KeyLabels.sidedName(forModifier: $0.code) }.joined(separator: " + ")
        }
        var symbols: [String] = []
        for key in modifiers {
            let symbol = KeyLabels.symbol(forModifier: key.code)
            if !symbols.contains(symbol) { symbols.append(symbol) }
        }
        return symbols.joined() + others.map(\.label).joined(separator: "+")
    }

    /// What pressing the shortcut does in the focused app when its keys can't be withheld (the
    /// hotkey tap is listen-only), so every key also reaches the app.
    public enum PassThroughEffect: Equatable, Sendable {
        /// Only modifiers, Caps Lock or F-keys: nothing visible happens.
        case harmless
        /// Includes ⌃ or ⌘, so the app may run its own command for the combination.
        case appShortcut
        /// Types a character or acts on the text (letters, Space, Return, arrows, ⌫, ⎋…).
        case typing
    }

    public var passThroughEffect: PassThroughEffect {
        let acting = keys.map(\.code).filter {
            !KeyCode.isModifier($0) && $0 != KeyCode.capsLock && !KeyCode.functionKeys.contains($0)
        }
        if acting.isEmpty { return .harmless }
        let commandLike: Set<UInt16> = [KeyCode.leftControl, KeyCode.leftCommand]
        if keys.contains(where: { commandLike.contains(KeyCode.leftSide($0.code)) }) { return .appShortcut }
        return .typing
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case empty
    }

    public func validate() throws(ValidationError) {
        guard !keys.isEmpty else { throw .empty }
    }

    private static let modifierOrder: [UInt16] = [
        KeyCode.function,
        KeyCode.leftControl, KeyCode.rightControl,
        KeyCode.leftOption, KeyCode.rightOption,
        KeyCode.leftShift, KeyCode.rightShift,
        KeyCode.leftCommand, KeyCode.rightCommand,
    ]

    private static func order(_ code: UInt16) -> Int {
        modifierOrder.firstIndex(of: code) ?? (modifierOrder.count + Int(code))
    }
}

extension Shortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case keys
        // Pre-chord format: one key plus a modifier bit set.
        case keyCode, modifiers, keyLabel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let keys = try container.decodeIfPresent([Key].self, forKey: .keys) {
            self.init(keys: keys)
            return
        }
        let keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let modifiers = try container.decode(Int.self, forKey: .modifiers)
        let label = try container.decode(String.self, forKey: .keyLabel)
        let legacy: [(bit: Int, code: UInt16)] = [
            (1 << 0, KeyCode.leftControl), (1 << 1, KeyCode.leftOption),
            (1 << 2, KeyCode.leftShift), (1 << 3, KeyCode.leftCommand),
        ]
        let modifierKeys = legacy.filter { modifiers & $0.bit != 0 }.map {
            Key(code: $0.code, label: KeyLabels.symbol(forModifier: $0.code))
        }
        self.init(keys: modifierKeys + [Key(code: UInt16(keyCode), label: label)])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
    }
}
