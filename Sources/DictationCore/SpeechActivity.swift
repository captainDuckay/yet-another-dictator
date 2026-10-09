/// A cheap loudness check that tells clearly silent recordings apart from ones that may hold speech.
///
/// Whisper invents text for silence and faint noise ("Thank you.", "Tekster af …"), so a clip with no
/// speech must never reach it. The check is deliberately conservative: it only rejects audio that
/// stays below a quiet-room level for almost all of its length. Anything louder still goes to
/// Whisper, whose own quality checks handle noise.
public enum SpeechActivity {
    /// Analysis frame: 30 ms at 16 kHz.
    public static let frameLength = 480
    /// Frame RMS that counts as "something audible": about −48 dBFS, well below quiet speech on a
    /// laptop microphone (around −40 dBFS) and above a typical quiet-room noise floor (−60 to −55).
    public static let levelThreshold: Float = 0.004
    /// Audible audio needed in total. Shorter bursts (a key click, a tap on the desk) don't count.
    public static let minimumAudibleSeconds = 0.1

    public static func containsSpeech(_ samples: [Float], sampleRate: Double = 16_000) -> Bool {
        let needed = Int((minimumAudibleSeconds * sampleRate / Double(frameLength)).rounded(.up))
        let threshold = levelThreshold * levelThreshold * Float(frameLength)
        var audible = 0
        var start = 0
        while start + frameLength <= samples.count {
            var sumOfSquares: Float = 0
            for index in start..<(start + frameLength) { sumOfSquares += samples[index] * samples[index] }
            if sumOfSquares >= threshold {
                audible += 1
                if audible >= needed { return true }
            }
            start += frameLength
        }
        return false
    }
}
