import Foundation
import Testing
import WhisperTranscription
@testable import Dictator

/// Counts fetches; the tests below expect none.
final class CountingTransport: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var fetches: Int { lock.withLock { count } }

    func fetch(_ entry: ModelManifest.Entry, into part: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { count += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
struct SpeechModelTests {
    let defaults = UserDefaults(suiteName: "SpeechModelTests-\(UUID().uuidString)")!

    static func bundledManifest() throws -> ModelManifest {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/model-manifest.txt")
        return try ModelManifest(text: String(contentsOf: url, encoding: .utf8))
    }

    @Test func rankingPutsParakeetFirstThenWhisper() {
        #expect(SpeechModel.ranked == [.parakeetV2, .whisperLargeV3Turbo])
    }

    @Test func everyModelIsPinnedInTheManifest() throws {
        let manifest = try Self.bundledManifest()
        for model in SpeechModel.allCases {
            #expect(!manifest.files(for: model.rawValue).isEmpty, "\(model.rawValue) missing from manifest")
        }
        #expect(manifest.files(for: SpeechModel.parakeetV2.rawValue).map(\.localPath).contains("parakeet_vocab.json"))
    }

    @Test func choiceIsUnsetAtFirstLaunch() {
        let choice = ModelChoice(defaults: defaults)
        #expect(choice.selected == nil)
        #expect(choice.needsChoice)
    }

    @Test func choicePersists() {
        ModelChoice(defaults: defaults).choose(.parakeetV2)
        let reloaded = ModelChoice(defaults: defaults)
        #expect(reloaded.selected == .parakeetV2)
        #expect(!reloaded.needsChoice)

        reloaded.choose(.whisperLargeV3Turbo)
        #expect(ModelChoice(defaults: defaults).selected == .whisperLargeV3Turbo)
    }

    @Test func unknownStoredModelCountsAsUnset() {
        defaults.set("some-removed-model", forKey: ModelChoice.key)
        #expect(ModelChoice(defaults: defaults).needsChoice)
    }

    @Test func pickerShownOnlyWhenNothingIsChosen() {
        #expect(ModelStartup.decide(choice: nil, installed: []) == .showPicker)
        #expect(ModelStartup.decide(choice: .parakeetV2, installed: []) == .load(.parakeetV2))
        #expect(ModelStartup.decide(choice: .whisperLargeV3Turbo, installed: [.parakeetV2]) == .load(.whisperLargeV3Turbo))
    }

    @Test func existingWhisperInstallIsKeptWithoutAsking() {
        #expect(ModelStartup.decide(choice: nil, installed: [.whisperLargeV3Turbo]) == .load(.whisperLargeV3Turbo))
    }

    @Test func nothingDownloadsUntilAModelIsChosen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SpeechModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CountingTransport()
        let download = ModelDownload(manifest: try Self.bundledManifest(), root: root, transport: transport)

        #expect(download.statusText == "No speech model chosen")
        #expect(await download.ensureInstalled() == false)
        #expect(transport.fetches == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))

        // Selecting alone downloads nothing either; only ensureInstalled() does.
        download.select(.parakeetV2)
        #expect(transport.fetches == 0)
    }

    @Test func onlyTheChosenModelIsDownloaded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SpeechModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CountingTransport()
        let manifest = try Self.bundledManifest()
        var installer = ModelInstaller(manifest: manifest, modelID: SpeechModel.parakeetV2.rawValue, root: root)
        installer.maxAttempts = 1
        try? await installer.install(using: transport)
        // The first fetch failed; nothing from the other model was requested or created.
        #expect(transport.fetches == 1)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        #expect(!folders.contains(SpeechModel.whisperLargeV3Turbo.rawValue))
    }

    @Test func sizesReadWell() {
        #expect(ModelDownload.size(464_000_000) == "464 MB")
        #expect(ModelDownload.size(1_625_000_000) == "1.6 GB")
    }
}
