import Foundation
import Testing
@testable import ParakeetTranscription

struct ParakeetTranscriberTests {
    @Test func incompleteFolderIsRefusedBeforeLoading() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "parakeet-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = ParakeetTranscriber(modelFolder: folder)
        await #expect(throws: ParakeetTranscriber.Failure.self) { try await transcriber.prepare() }
    }
}
