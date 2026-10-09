import AVFoundation
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

        let text = try await transcriber.transcribe(samples, language: nil)

        let normalised = text.lowercased()
        #expect(normalised.contains("quick brown fox"), "got: \(text)")
        #expect(normalised.contains("lazy dog"), "got: \(text)")
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
