import AVFoundation
import DictationCore
import Foundation
import Testing
import WhisperTranscription

/// End-to-end check against the real model. Run `scripts/fetch-model.sh` first; skipped otherwise.
struct WhisperKitTranscriberTests {
    static let modelFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Model", directoryHint: .isDirectory)

    static var modelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelFolder.appending(path: "tokenizer.json").path(percentEncoded: false))
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(10)))
    func transcribesSynthesisedSpeech() async throws {
        let samples = try Self.speak("The quick brown fox jumps over the lazy dog.")
        let transcriber = WhisperKitTranscriber(modelFolder: Self.modelFolder)

        let text = try await transcriber.transcribe(samples)

        let normalised = text.lowercased()
        #expect(normalised.contains("quick brown fox"), "got: \(text)")
        #expect(normalised.contains("lazy dog"), "got: \(text)")
    }

    /// Short single sentences are where Whisper used to drop the closing punctuation.
    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(10)), arguments: [
        "Please send me the report tomorrow",
        "Can you call me back later",
    ])
    func shortSentenceEndsWithPunctuation(_ sentence: String) async throws {
        let transcriber = WhisperKitTranscriber(modelFolder: Self.modelFolder)

        let text = TranscriptCleaner.clean(try await transcriber.transcribe(try Self.speak(sentence)))

        #expect(text.last.map { ".?!".contains($0) } == true, "got: \(text)")
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(10)))
    func silenceDoesNotEchoThePrompt() async throws {
        let transcriber = WhisperKitTranscriber(modelFolder: Self.modelFolder)

        let text = try await transcriber.transcribe(Array(repeating: 0, count: 32_000))

        #expect(!text.contains("hvordan går det"), "got: \(text)")
        #expect(!text.contains("how are you"), "got: \(text)")
    }

    @Test func refusesToLoadIncompleteModelFolder() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        await #expect(throws: WhisperKitTranscriber.Failure.self) {
            try await WhisperKitTranscriber(modelFolder: empty).prepare()
        }
    }

    /// Uses macOS `say` to render 16 kHz mono float PCM.
    static func speak(_ text: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }

        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["--file-format=WAVE", "--data-format=LEF32@16000", "-o", file.path(percentEncoded: false), text]
        try say.run()
        say.waitUntilExit()

        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
