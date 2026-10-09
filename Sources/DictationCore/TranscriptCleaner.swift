import Foundation

/// Normalises raw Whisper output into text that is safe to type into another app.
public enum TranscriptCleaner {
    /// Output is a single line: newlines/tabs become spaces so dictation can never submit a form
    /// or move focus, and control characters are dropped so we never synthesise e.g. ESC.
    public static func clean(_ raw: String) -> String {
        // Whisper emits these for silence/noise; typing them into a field is never wanted.
        let withoutAnnotations = raw.replacing(
            /(?i)\[(?:blank_audio|music|noise|silence|inaudible)\]|<\|[^|]*\|>/,
            with: ""
        )
        var scalars = String.UnicodeScalarView()
        for scalar in withoutAnnotations.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .replacing(/\ {2,}/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
