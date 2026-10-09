import Foundation
import Observation

// MARK: - Ports (implemented by the app / transcription targets)

/// Captures microphone audio as 16 kHz mono Float32 samples (Whisper's native format).
@MainActor
public protocol AudioRecording: AnyObject {
    /// `onLevel` receives a 0...1 loudness value from the audio thread.
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws
    func stop() -> [Float]
}

/// Turns 16 kHz mono samples into text. Must work fully offline.
public protocol Transcribing: Sendable {
    func prepare() async throws
    /// `language` is a Whisper language code ("da", "en"), or nil to detect it from the audio.
    func transcribe(_ samples: [Float], language: String?) async throws -> String
}

/// Delivers text into whatever field currently has keyboard focus.
@MainActor
public protocol TextInserting: AnyObject {
    /// Throws a user-facing error if `insert` is known to fail (e.g. permission missing), asking
    /// for the permission if it can. Checked before recording so speech isn't wasted.
    func preflight() throws
    func insert(_ text: String) throws
    /// Deletes `count` characters before the cursor, as if Delete was pressed `count` times.
    func deleteBackward(_ count: Int) throws
}

// MARK: - State machine

/// How long one dictation took, for latency logging. Contains no text or audio.
public struct DictationTiming: Equatable, Sendable {
    /// Length of the recorded audio.
    public var audioSeconds: Double
    /// From the moment the user stopped (key release or second tap) to the text being typed.
    public var releaseToTypedSeconds: Double
    /// Time spent in the transcriber alone.
    public var transcriptionSeconds: Double
}

public enum DictationState: Equatable, Sendable {
    case loadingModel
    case ready
    case recording
    case transcribing
    /// The model could not be loaded; dictation is disabled.
    case unavailable(String)
}

/// Orchestrates hotkey → record → transcribe → insert.
///
/// Hotkey gesture: a quick tap toggles recording on/off; holding the shortcut records until release
/// (push-to-talk).
@MainActor
@Observable
public final class DictationController {
    public nonisolated static let sampleRate: Double = 16_000

    public private(set) var state: DictationState = .loadingModel {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Live input loudness while recording, 0...1.
    public private(set) var level: Float = 0
    /// Last non-fatal error (e.g. microphone denied), cleared on the next successful start.
    public private(set) var lastError: String? {
        didSet { if let lastError, lastError != oldValue { onError?(lastError) } }
    }
    /// A transcript that could not be typed, kept in memory only so it isn't lost. Replaced by the
    /// next dictation and cleared once typed or discarded.
    public private(set) var undeliveredTranscript: String?

    /// Language for the next transcriptions.
    public var language: DictationLanguage = .automatic

    /// Reads the text just before the cursor in the focused field, or returns nil when it can't.
    /// Used to space and capitalize a dictation to fit; never stored or logged.
    @ObservationIgnored public var textBeforeCursor: (() -> String?)?
    /// Called after each dictation is typed, with how long it took.
    @ObservationIgnored public var onTiming: ((DictationTiming) -> Void)?
    @ObservationIgnored public var onStateChange: ((DictationState) -> Void)?
    /// Called whenever a new error is reported, e.g. to show it briefly on screen.
    @ObservationIgnored public var onError: ((String) -> Void)?

    @ObservationIgnored private let recorder: any AudioRecording
    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let inserter: any TextInserting
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let holdThreshold: TimeInterval
    @ObservationIgnored private let minimumSamples: Int
    @ObservationIgnored private let stopTail: Duration
    /// True while the microphone is still open for the stop tail.
    @ObservationIgnored private var isInStopTail = false
    @ObservationIgnored private let containsSpeech: @Sendable ([Float]) -> Bool
    @ObservationIgnored private var pressedAt: TimeInterval?
    @ObservationIgnored private let transcriptionTimeout: @Sendable (_ sampleCount: Int) -> Duration
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Identifies the current transcription; bumped on cancel/timeout so a late result is ignored.
    @ObservationIgnored private var generation = 0
    private var history = DictationHistory()

    /// Whether the last dictation can still be undone: nothing was typed, clicked or switched since.
    public var canUndo: Bool { state == .ready && history.lastInserted != nil }

    public init(
        recorder: any AudioRecording,
        transcriber: any Transcribing,
        inserter: any TextInserting,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        holdThreshold: TimeInterval = 0.35,
        minimumDuration: TimeInterval = 0.3,
        stopTail: Duration = .milliseconds(250),
        transcriptionTimeout: @escaping @Sendable (_ sampleCount: Int) -> Duration = DictationController.defaultTranscriptionTimeout,
        containsSpeech: @escaping @Sendable ([Float]) -> Bool = { SpeechActivity.containsSpeech($0) }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.now = now
        self.holdThreshold = holdThreshold
        self.minimumSamples = Int(minimumDuration * Self.sampleRate)
        self.stopTail = stopTail
        self.containsSpeech = containsSpeech
        self.transcriptionTimeout = transcriptionTimeout
    }

    /// 30 s plus the length of the audio: far beyond normal (a few seconds), but bounded, so a stuck
    /// model can never leave dictation disabled.
    public nonisolated static func defaultTranscriptionTimeout(sampleCount: Int) -> Duration {
        .seconds(30) + .seconds(Double(sampleCount) / sampleRate)
    }

    public func loadModel() async {
        state = .loadingModel
        do {
            try await transcriber.prepare()
            state = .ready
        } catch {
            state = .unavailable(String(describing: error))
        }
    }

    public func hotkeyPressed() {
        switch state {
        case .ready:
            do {
                try inserter.preflight()
            } catch {
                report(error)
                return
            }
            pressedAt = now()
            startRecording()
        case .recording:
            pressedAt = nil
            finishRecording()
        case .loadingModel, .transcribing, .unavailable:
            break
        }
    }

    public func hotkeyReleased() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        if state == .recording, now() - pressedAt >= holdThreshold {
            finishRecording()
        }
    }

    /// Stops recording, or abandons the running transcription, without typing anything.
    public func cancel() {
        switch state {
        case .recording:
            pressedAt = nil
            _ = recorder.stop()
            level = 0
            state = .ready
        case .transcribing:
            closeStopTail()
            abandonTranscription()
            state = .ready
        case .loadingModel, .ready, .unavailable:
            break
        }
    }

    /// The user typed, clicked or switched apps, so the cursor may have moved since the last
    /// dictation. Call for any input that isn't the dictation shortcut.
    public func noteOtherInput() {
        history.otherInput()
    }

    /// The microphone stopped on its own (device unplugged, audio system error) during recording.
    /// Whatever was captured is dropped, since it may be cut off mid-word.
    public func recordingFailed(_ message: String) {
        guard state == .recording else { return }
        pressedAt = nil
        _ = recorder.stop()
        level = 0
        state = .ready
        report(message)
    }

    /// The recording reached the capture buffer's capacity (10 minutes) and stopped growing.
    /// Unlike a failure, what was captured is complete, so it is transcribed and typed as usual.
    public func recordingReachedLimit() {
        guard state == .recording else { return }
        pressedAt = nil
        finishRecording()
        report("Recording reached the 10-minute limit and was stopped.")
    }

    /// Deletes exactly the characters the last dictation typed, if nothing else happened since.
    public func undoLastDictation() {
        guard state == .ready, let count = history.takeUndo() else { return }
        do {
            try inserter.deleteBackward(count)
        } catch {
            report(error)
        }
    }

    /// Types the undelivered transcript again, e.g. after the user fixed the permission.
    public func retryUndelivered() {
        guard state == .ready, let text = undeliveredTranscript else { return }
        do {
            try inserter.insert(text)
            history.didInsert(text)
            undeliveredTranscript = nil
            lastError = nil
        } catch {
            report(error)
        }
    }

    public func discardUndelivered() {
        undeliveredTranscript = nil
    }

    private func report(_ error: any Error) {
        report(error.localizedDescription)
    }

    private func report(_ message: String) {
        // Clearing first makes a repeated identical failure notify (and be shown) again.
        lastError = nil
        lastError = message
    }

    private func startRecording() {
        do {
            try recorder.start { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
            lastError = nil
            state = .recording
        } catch {
            pressedAt = nil
            report("Could not start microphone: \(error.localizedDescription)")
        }
    }

    private func finishRecording() {
        let stoppedAt = now()
        state = .transcribing
        generation += 1
        let id = generation
        isInStopTail = true
        transcription = Task { await finishAndTranscribe(id: id, stoppedAt: stoppedAt) }
    }

    /// Closes the microphone if it's still open for the stop tail, returning what it recorded.
    @discardableResult
    private func closeStopTail() -> [Float] {
        guard isInStopTail else { return [] }
        isInStopTail = false
        level = 0
        return recorder.stop()
    }

    /// Keeps the microphone open for `stopTail` after the user stops. People release the shortcut
    /// on (not after) their last syllable, and the newest audio buffer is still in flight; cutting
    /// there clips the last word, which also makes Whisper treat the sentence as unfinished and
    /// drop its closing punctuation.
    private func finishAndTranscribe(id: Int, stoppedAt: TimeInterval) async {
        if stopTail > .zero { try? await Task.sleep(for: stopTail) }
        // Cancelled during the tail: cancel() already closed the mic; leave without typing.
        guard id == generation else { return }
        let samples = closeStopTail()
        // Too short or silent: nothing was said, and Whisper would only invent text.
        guard samples.count >= minimumSamples, containsSpeech(samples) else {
            transcription = nil
            state = .ready
            return
        }
        let timeout = transcriptionTimeout(samples.count)
        watchdog = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            guard let self, generation == id, state == .transcribing else { return }
            abandonTranscription()
            report("Transcription took too long and was stopped. Please try again.")
            state = .ready
        }
        await transcribeAndInsert(samples, id: id, stoppedAt: stoppedAt)
    }

    /// Cancels the running transcription and makes sure its result, if it still arrives, is dropped.
    private func abandonTranscription() {
        generation += 1
        transcription?.cancel()
        transcription = nil
        watchdog?.cancel()
        watchdog = nil
    }

    private func transcribeAndInsert(_ samples: [Float], id: Int, stoppedAt: TimeInterval) async {
        let outcome: Result<String, any Error>
        let transcriptionStart = now()
        var transcriptionEnd = transcriptionStart
        do {
            outcome = .success(try await transcriber.transcribe(samples, language: language.whisperCode))
        } catch {
            outcome = .failure(error)
        }
        transcriptionEnd = now()
        // Cancelled or timed out meanwhile: the user has moved on, so type nothing.
        guard id == generation else { return }
        watchdog?.cancel()
        watchdog = nil
        transcription = nil
        defer { state = .ready }
        let text: String
        do {
            text = TranscriptCleaner.clean(try outcome.get())
        } catch {
            report(error)
            return
        }
        guard !text.isEmpty else { return }
        // The field's own text when it can be read; otherwise our previous dictation, as long as
        // nothing else was typed since; otherwise unknown, and the text is typed as transcribed.
        // An empty field reading next to a dictation we just typed means the app reports its text
        // wrongly (some web views do), so the history is trusted over it.
        let fieldText = textBeforeCursor?()
        let preceding = fieldText?.isEmpty == false ? fieldText : (history.lastInserted ?? fieldText)
        let typed = SmartJoin.adjust(text, after: preceding)
        do {
            try inserter.insert(typed)
            history.didInsert(typed)
            undeliveredTranscript = nil
            onTiming?(DictationTiming(
                audioSeconds: Double(samples.count) / Self.sampleRate,
                releaseToTypedSeconds: now() - stoppedAt,
                transcriptionSeconds: transcriptionEnd - transcriptionStart
            ))
        } catch {
            undeliveredTranscript = text
            report("\(error.localizedDescription) Your dictation is kept in the menu bar menu.")
        }
    }
}
