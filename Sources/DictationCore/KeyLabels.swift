import Foundation

/// Human-readable labels for keys whose typed character is invisible or ambiguous.
public enum KeyLabels {
    private static let special: [UInt32: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
    ]

    /// Prefers the fixed label for special keys, otherwise the typed character uppercased.
    public static func label(forKeyCode keyCode: UInt32, typed: String?) -> String {
        if let label = special[keyCode] { return label }
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Key \(keyCode)" : trimmed.uppercased()
    }
}
