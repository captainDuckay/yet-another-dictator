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
    /// How long transcription takes; `cooperative` decides whether it stops when cancelled.
    var delay: Duration?
    var cooperative = true
    private(set) var sawCancellation = false

    func set(result: String) { self.result = result }
    func set(prepareError: any Error) { self.prepareError = prepareError }
    func set(delay: Duration?, cooperative: Bool = true) {
        self.delay = delay
        self.cooperative = cooperative
    }

    func prepare() async throws {
        if let prepareError { throw prepareError }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        received.append(samples)
        if let delay {
            if cooperative {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    sawCancellation = true
                    throw error
                }
            } else {
                // Ignores cancellation, like a model that can't be interrupted mid-step.
                let end = ContinuousClock.now + delay
                while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        return result
    }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    var preflightError: (any Error)?
    var insertError: (any Error)?

    func preflight() throws {
        if let preflightError { throw preflightError }
    }

    func insert(_ text: String) throws {
        if let insertError { throw insertError }
        inserted.append(text)
    }
}

struct Boom: Error {}

@MainActor
struct DictationControllerTests {
    let recorder = FakeRecorder()
    let transcriber = FakeTranscriber()
    let inserter = FakeInserter()
    let clock = Clock()

    final class Clock { var now: TimeInterval = 100 }

    func makeController(timeout: Duration = .seconds(30)) async -> DictationController {
        let clock = clock
        let controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            now: { clock.now },
            transcriptionTimeout: { _ in timeout }
        )
        await controller.loadModel()
        recorder.samplesToReturn = Array(repeating: 0.1, count: 16_000)
        return controller
    }

    func waitUntilReady(_ controller: DictationController, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while controller.state != .ready, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
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

    @Test func cancelDuringTranscriptionTypesNothing() async {
        let controller = await makeController()
        await transcriber.set(delay: .milliseconds(150), cooperative: false)

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        #expect(controller.state == .transcribing)

        controller.cancel()
        #expect(controller.state == .ready)

        try? await Task.sleep(for: .milliseconds(400)) // the late result arrives meanwhile
        #expect(inserter.inserted.isEmpty)
        #expect(controller.lastError == nil)
        #expect(controller.state == .ready)
    }

    @Test func cancelStopsACooperativeTranscriber() async {
        let controller = await makeController()
        await transcriber.set(delay: .seconds(60))

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        controller.cancel()

        let deadline = ContinuousClock.now + .seconds(2)
        while await !transcriber.sawCancellation, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await transcriber.sawCancellation)
    }

    @Test func stuckTranscriptionTimesOut() async {
        let controller = await makeController(timeout: .milliseconds(50))
        await transcriber.set(delay: .seconds(60))

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        #expect(controller.state == .ready)
        #expect(controller.lastError?.contains("too long") == true)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func dictationWorksAgainAfterCancel() async {
        let controller = await makeController()
        await transcriber.set(delay: .milliseconds(100), cooperative: false)
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        controller.cancel()

        await transcriber.set(delay: nil)
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)
        try? await Task.sleep(for: .milliseconds(300)) // let the abandoned one finish too

        #expect(inserter.inserted == ["hello world"])
    }

    @Test func defaultTimeoutGrowsWithAudioLength() {
        #expect(DictationController.defaultTranscriptionTimeout(sampleCount: 0) == .seconds(30))
        #expect(DictationController.defaultTranscriptionTimeout(sampleCount: 16_000 * 60) == .seconds(90))
    }

    @Test func silentRecordingIsNotTranscribed() async {
        let controller = await makeController()
        recorder.samplesToReturn = Array(repeating: 0, count: 32_000)

        controller.hotkeyPressed()
        controller.hotkeyPressed()

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

    @Test func refusesToRecordWhenTextCannotBeInserted() async {
        let controller = await makeController()
        inserter.preflightError = Boom()
        var shown: [String] = []
        controller.onError = { shown.append($0) }

        controller.hotkeyPressed()
        controller.hotkeyReleased()

        #expect(controller.state == .ready)
        #expect(!recorder.isRecording)
        #expect(controller.lastError != nil)
        #expect(shown.count == 1)

        controller.hotkeyPressed()
        #expect(shown.count == 2, "a repeated failure is shown again")
    }

    @Test func failedInsertKeepsTranscriptForRetry() async {
        let controller = await makeController()
        inserter.insertError = Boom()

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        #expect(controller.undeliveredTranscript == "hello world")
        #expect(controller.lastError != nil)

        controller.retryUndelivered()
        #expect(controller.undeliveredTranscript == "hello world", "still failing, still kept")

        inserter.insertError = nil
        controller.retryUndelivered()
        #expect(inserter.inserted == ["hello world"])
        #expect(controller.undeliveredTranscript == nil)
        #expect(controller.lastError == nil)
    }

    @Test func nextSuccessfulDictationReplacesUndeliveredTranscript() async {
        let controller = await makeController()
        inserter.insertError = Boom()
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)
        #expect(controller.undeliveredTranscript != nil)

        inserter.insertError = nil
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        #expect(controller.undeliveredTranscript == nil)
        #expect(inserter.inserted == ["hello world"])
    }

    @Test func discardForgetsUndeliveredTranscript() async {
        let controller = await makeController()
        inserter.insertError = Boom()
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        controller.discardUndelivered()

        #expect(controller.undeliveredTranscript == nil)
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
