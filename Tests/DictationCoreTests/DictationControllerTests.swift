import DictationCore
import Foundation
import Testing

@MainActor
final class FakeRecorder: AudioRecording {
    var samplesToReturn: [Float] = []
    var startError: (any Error)?
    private(set) var isRecording = false
    private(set) var startCount = 0

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        if let startError { throw startError }
        isRecording = true
        startCount += 1
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
    private(set) var languages: [String?] = []
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

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        received.append(samples)
        languages.append(language)
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
    /// Completed inserts.
    private(set) var inserted: [String] = []
    /// Every character "posted", including those of an insert that was cancelled part-way.
    private(set) var posted: [Character] = []
    var preflightError: (any Error)?
    var insertError: (any Error)?
    /// When set, each character is posted separately with this pause, like a long text typed in
    /// chunks, and cancellation is checked between them like the real inserter does.
    var delayPerCharacter: Duration?

    func preflight() throws {
        if let preflightError { throw preflightError }
    }

    func insert(_ text: String) async throws {
        if let insertError { throw insertError }
        if let delayPerCharacter {
            for character in text {
                if Task.isCancelled { throw CancellationError() }
                posted.append(character)
                try? await Task.sleep(for: delayPerCharacter)
            }
        } else {
            posted.append(contentsOf: text)
        }
        inserted.append(text)
    }

    private(set) var deleted: [Int] = []
    func deleteBackward(_ count: Int) async throws {
        if let insertError { throw insertError }
        deleted.append(count)
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
            stopTail: .zero,
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
        await waitUntilReady(controller)

        #expect(controller.state == .ready)
        #expect(!recorder.isRecording)
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

    @Test func keepsRecordingForTheTailAfterStop() async {
        let clock = clock
        let controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            now: { clock.now },
            stopTail: .milliseconds(50),
            transcriptionTimeout: { _ in .seconds(30) }
        )
        await controller.loadModel()
        recorder.samplesToReturn = Array(repeating: 0.1, count: 16_000)

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        #expect(controller.state == .transcribing)
        #expect(recorder.isRecording, "the microphone must stay open during the tail")

        await waitUntilReady(controller, timeout: .seconds(5))
        #expect(!recorder.isRecording)
        #expect(inserter.inserted == ["hello world"])
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
        // Cancel once the transcriber is actually running, i.e. after the stop tail.
        let started = ContinuousClock.now + .seconds(2)
        while await transcriber.received.isEmpty, ContinuousClock.now < started {
            try? await Task.sleep(for: .milliseconds(1))
        }
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
        await waitUntilReady(controller)

        #expect(controller.state == .ready)
        #expect(await transcriber.received.isEmpty)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func microphoneFailureDuringRecordingReturnsToReadyAndReports() async {
        let controller = await makeController()
        controller.hotkeyPressed()
        #expect(controller.state == .recording)

        controller.recordingFailed("The microphone was disconnected.")

        #expect(controller.state == .ready)
        #expect(!recorder.isRecording)
        #expect(controller.lastError == "The microphone was disconnected.")
        #expect(await transcriber.received.isEmpty)
    }

    @Test func microphoneFailureOutsideRecordingIsIgnored() async {
        let controller = await makeController()
        controller.recordingFailed("The microphone was disconnected.")
        #expect(controller.state == .ready)
        #expect(controller.lastError == nil)
    }

    @Test func passesTheChosenLanguageToTheTranscriber() async {
        let controller = await makeController()

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)
        controller.language = .danish
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        #expect(await transcriber.languages == [nil, "da"])
    }

    private func dictate(_ controller: DictationController, _ result: String) async {
        await transcriber.set(result: result)
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)
    }

    @Test func consecutiveDictationsAreSpacedAndCapitalized() async {
        let controller = await makeController()
        await dictate(controller, "Hello world.")
        await dictate(controller, "and more")
        await dictate(controller, "So that's it.")
        #expect(inserter.inserted == ["Hello world.", " And more", " so that's it."])
    }

    @Test func otherInputMakesTheContextUnknown() async {
        let controller = await makeController()
        await dictate(controller, "Hello world.")
        controller.noteOtherInput()
        await dictate(controller, "and more.")
        #expect(inserter.inserted == ["Hello world.", "and more."])
    }

    @Test func readableFieldTextWinsOverHistory() async {
        let controller = await makeController()
        await dictate(controller, "Hello world.")
        controller.textBeforeCursor = { "Dear Sir," }
        await dictate(controller, "Thanks for writing.")
        #expect(inserter.inserted.last == " thanks for writing.")
    }

    @Test func emptyFieldReadingDoesNotOverrideHistory() async {
        let controller = await makeController()
        controller.textBeforeCursor = { "" }
        await dictate(controller, "hello world.")
        await dictate(controller, "and more.")
        #expect(inserter.inserted == ["Hello world.", " And more."])
    }

    @Test func reportsTimingFromReleaseToTypedText() async {
        let controller = await makeController()
        var timings: [DictationTiming] = []
        controller.onTiming = { timings.append($0) }

        controller.hotkeyPressed()
        clock.now += 2
        controller.hotkeyReleased() // hold: stops here, at t = 102
        clock.now += 0.5 // transcription and typing take 0.5 s on the fake clock
        await waitUntilReady(controller)

        #expect(timings.count == 1)
        #expect(timings.first?.audioSeconds == 1) // FakeRecorder returns 16 000 samples
        #expect(timings.first?.releaseToTypedSeconds == 0.5)
    }

    @Test func noTimingWhenNothingIsTyped() async {
        await transcriber.set(result: "[BLANK_AUDIO]")
        let controller = await makeController()
        var timings: [DictationTiming] = []
        controller.onTiming = { timings.append($0) }

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        await waitUntilReady(controller)

        #expect(timings.isEmpty)
    }

    @Test func undoDeletesExactlyWhatWasTyped() async {
        let controller = await makeController()
        await dictate(controller, "Hello world.")
        await dictate(controller, "and more 👋🏽.")
        #expect(controller.canUndo)

        await controller.undoLastDictation()

        #expect(inserter.deleted == [" And more 👋🏽.".count])
        #expect(inserter.deleted == [12]) // the emoji with skin tone is one character
        #expect(!controller.canUndo)
        await controller.undoLastDictation() // only once
        #expect(inserter.deleted.count == 1)
    }

    @Test func undoIsUnavailableAfterOtherInput() async {
        let controller = await makeController()
        await dictate(controller, "Hello world.")
        controller.noteOtherInput()
        #expect(!controller.canUndo)
        await controller.undoLastDictation()
        #expect(inserter.deleted.isEmpty)
    }

    @Test func undoIsUnavailableBeforeAnyDictationAndWhileRecording() async {
        let controller = await makeController()
        #expect(!controller.canUndo)
        await dictate(controller, "Hello.")
        controller.hotkeyPressed()
        #expect(!controller.canUndo)
        await controller.undoLastDictation()
        #expect(inserter.deleted.isEmpty)
    }

    @Test func reachingTheLimitStillTranscribesAndTypes() async {
        let controller = await makeController()
        controller.hotkeyPressed()
        #expect(controller.state == .recording)

        controller.recordingReachedLimit()
        #expect(controller.lastError == "Recording reached the 10-minute limit and was stopped.")
        await waitUntilReady(controller)

        #expect(controller.state == .ready)
        #expect(!recorder.isRecording)
        #expect(await transcriber.received.count == 1)
        #expect(inserter.inserted == ["hello world"])
        #expect(controller.lastError == "Recording reached the 10-minute limit and was stopped.")
    }

    @Test func reachingTheLimitAfterHoldReleaseIsIgnored() async {
        let controller = await makeController()
        controller.hotkeyPressed()
        clock.now += 2
        controller.recordingReachedLimit()
        controller.hotkeyReleased() // the hold already ended by the limit: no second stop
        await waitUntilReady(controller)
        #expect(await transcriber.received.count == 1)
    }

    @Test func reachingTheLimitIsANoOpWhenReady() async {
        let controller = await makeController()
        controller.recordingReachedLimit()
        #expect(controller.state == .ready)
        #expect(controller.lastError == nil)
        #expect(await transcriber.received.isEmpty)
    }

    @Test func reachingTheLimitIsANoOpWhileTranscribing() async {
        let controller = await makeController()
        await transcriber.set(delay: .milliseconds(300))
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        #expect(controller.state == .transcribing)
        controller.recordingReachedLimit()
        #expect(controller.lastError == nil)
        await waitUntilReady(controller)
        #expect(await transcriber.received.count == 1)
        #expect(inserter.inserted.count == 1)
    }

    @Test func cancelWhileTypingStopsPostingAndEndsReady() async {
        let controller = await makeController()
        await transcriber.set(result: "This is a long dictation that takes a while to type.")
        inserter.delayPerCharacter = .milliseconds(5)

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        // Wait until typing has started.
        let deadline = ContinuousClock.now + .seconds(2)
        while inserter.posted.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(controller.state == .transcribing)

        controller.cancel()
        #expect(controller.state == .ready)
        let postedAtCancel = inserter.posted.count
        try? await Task.sleep(for: .milliseconds(100))

        #expect(inserter.posted.count <= postedAtCancel + 1) // at most the chunk in flight
        #expect(inserter.posted.count < 52)
        #expect(inserter.inserted.isEmpty)
        #expect(controller.state == .ready)
        #expect(controller.lastError == nil)
        #expect(controller.undeliveredTranscript == nil)
        #expect(!controller.canUndo) // a partial insert is never undoable
    }

    @Test func cancelWhileTypingReportsNoTimingAndDoesntJoinTheNextDictation() async {
        let controller = await makeController()
        var timings: [DictationTiming] = []
        controller.onTiming = { timings.append($0) }
        await transcriber.set(result: "First dictation that is cancelled.")
        inserter.delayPerCharacter = .milliseconds(5)
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        let deadline = ContinuousClock.now + .seconds(2)
        while inserter.posted.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        inserter.delayPerCharacter = nil
        await dictate(controller, "next one.")
        #expect(timings.count == 1) // only the second dictation
        #expect(inserter.inserted == ["next one."]) // no smart join with the partial text
    }

    @Test func aNewDictationStartedRightAfterCancellingTypingIsNotStopped() async {
        let controller = await makeController()
        await transcriber.set(result: "A long dictation being typed slowly.")
        inserter.delayPerCharacter = .milliseconds(5)
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        let deadline = ContinuousClock.now + .seconds(2)
        while inserter.posted.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        controller.cancel()
        controller.hotkeyPressed()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.state == .recording) // the old task didn't reset it to .ready
        #expect(recorder.isRecording)
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

        await controller.retryUndelivered()
        #expect(controller.undeliveredTranscript == "hello world", "still failing, still kept")

        inserter.insertError = nil
        await controller.retryUndelivered()
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
        await transcriber.set(delay: .milliseconds(300))
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        #expect(controller.state == .transcribing)
        // stopTail is zero, but stop still runs on a Task; wait for the mic to close.
        let deadline = ContinuousClock.now + .seconds(2)
        while recorder.isRecording, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!recorder.isRecording)

        controller.hotkeyPressed()
        #expect(recorder.startCount == 1)
        #expect(controller.state == .transcribing)
        await waitUntilReady(controller)
        #expect(await transcriber.received.count == 1)
    }

    @Test func cancelDuringStopTailClosesTheMicrophoneAtOnce() async {
        let controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            now: { [clock] in clock.now }, stopTail: .milliseconds(200)
        )
        await controller.loadModel()
        recorder.samplesToReturn = [Float](repeating: 0.1, count: 16_000)

        controller.hotkeyPressed()
        controller.hotkeyPressed()
        #expect(recorder.isRecording) // still in the tail
        controller.cancel()
        #expect(!recorder.isRecording)
        #expect(controller.state == .ready)

        // A new dictation right away isn't cut off by the abandoned tail.
        controller.hotkeyPressed()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(recorder.isRecording)
        #expect(controller.state == .recording)
        #expect(await transcriber.received.isEmpty)
    }
}
