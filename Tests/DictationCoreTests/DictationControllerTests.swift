import DictationCore
import Foundation
import Testing

@MainActor
final class FakeRecorder: AudioRecording {
    var samplesToReturn: [Float] = []
    var startError: (any Error)?
    private(set) var isRecording = false

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() -> [Float] {
        isRecording = false
        return samplesToReturn
    }
}

actor FakeTranscriber: Transcribing {
    var result = "hello world"
    var prepareError: (any Error)?
    private(set) var received: [[Float]] = []

    func set(result: String) { self.result = result }
    func set(prepareError: any Error) { self.prepareError = prepareError }

    func prepare() async throws {
        if let prepareError { throw prepareError }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        received.append(samples)
        return result
    }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    func insert(_ text: String) throws { inserted.append(text) }
}

struct Boom: Error {}

@MainActor
struct DictationControllerTests {
    let recorder = FakeRecorder()
    let transcriber = FakeTranscriber()
    let inserter = FakeInserter()
    let clock = Clock()

    final class Clock { var now: TimeInterval = 100 }

    func makeController() async -> DictationController {
        let clock = clock
        let controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            now: { clock.now }
        )
        await controller.loadModel()
        recorder.samplesToReturn = Array(repeating: 0.1, count: 16_000)
        return controller
    }

    func waitUntilReady(_ controller: DictationController) async {
        for _ in 0..<1_000 where controller.state != .ready { await Task.yield() }
    }

    @Test func loadsModelThenBecomesReady() async {
        let controller = await makeController()
        #expect(controller.state == .ready)
    }

    @Test func failedModelLoadDisablesDictation() async {
        await transcriber.set(prepareError: Boom())
        let controller = await makeController()
        guard case .unavailable = controller.state else {
            Issue.record("expected unavailable, got \(controller.state)")
            return
        }
        controller.hotkeyPressed()
        #expect(!recorder.isRecording)
    }

    @Test func tapTogglesRecordingAndInsertsText() async {
        let controller = await makeController()

        controller.hotkeyPressed()
        clock.now += 0.1
        controller.hotkeyReleased()
        #expect(controller.state == .recording)

        controller.hotkeyPressed()
        controller.hotkeyReleased()
        #expect(controller.state == .transcribing)

        await waitUntilReady(controller)
        #expect(inserter.inserted == ["hello world"])
        #expect(await transcriber.received.count == 1)
    }

    @Test func holdIsPushToTalk() async {
        let controller = await makeController()

        controller.hotkeyPressed()
        clock.now += 1
        controller.hotkeyReleased()

        #expect(controller.state == .transcribing)
        await waitUntilReady(controller)
        #expect(inserter.inserted == ["hello world"])
    }

    @Test func tooShortRecordingIsDiscarded() async {
        let controller = await makeController()
        recorder.samplesToReturn = Array(repeating: 0, count: 100)

        controller.hotkeyPressed()
        controller.hotkeyPressed()

        #expect(controller.state == .ready)
        #expect(await transcriber.received.isEmpty)
    }

    @Test func cancelDiscardsAudio() async {
        let controller = await makeController()

        controller.hotkeyPressed()
        controller.cancel()

        #expect(controller.state == .ready)
        #expect(await transcriber.received.isEmpty)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func emptyTranscriptInsertsNothing() async {
        await transcriber.set(result: " [BLANK_AUDIO] ")
        let controller = await makeController()

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        #expect(inserter.inserted.isEmpty)
    }

    @Test func microphoneFailureSurfacesErrorAndStaysReady() async {
        let controller = await makeController()
        recorder.startError = Boom()

        controller.hotkeyPressed()

        #expect(controller.state == .ready)
        #expect(controller.lastError != nil)
    }

    @Test func hotkeyIgnoredWhileTranscribing() async {
        let controller = await makeController()
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        #expect(controller.state == .transcribing)

        controller.hotkeyPressed()
        #expect(!recorder.isRecording)
        await waitUntilReady(controller)
    }
}
