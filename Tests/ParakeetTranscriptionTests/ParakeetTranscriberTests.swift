import Foundation
import ModelSession
import ParakeetTranscription
import Testing

struct ParakeetModelTests {
    @Test func incompleteFolderIsRefusedBeforeLoading() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "parakeet-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try await ModelSession.parakeet(modelFolder: folder).prepare()
            Issue.record("expected missing files")
        } catch {
            #expect(
                "\(error)".contains("parakeet_vocab.json"),
                "factory files should name parakeet_vocab.json, got: \(error)"
            )
        }
    }
}
