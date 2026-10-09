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
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Delivers text into whatever field currently has keyboard focus.
@MainActor
public protocol TextInserting: AnyObject {
    /// Throws a user-facing error if `insert` is known to fail (e.g. permission missing), asking
    /// for the permission if it can. Checked before recording so speech isn't wasted.
    func preflight() throws
    func insert(_ text: String) throws
}

// MARK: - State machine

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
    public static let sampleRate: Double = 16_000

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

    @ObservationIgnored public var onStateChange: ((DictationState) -> Void)?
    /// Called whenever a new error is reported, e.g. to show it briefly on screen.
    @ObservationIgnored public var onError: ((String) -> Void)?

    @ObservationIgnored private let recorder: any AudioRecording
    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let inserter: any TextInserting
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let holdThreshold: TimeInterval
    @ObservationIgnored private let minimumSamples: Int
    @ObservationIgnored private var pressedAt: TimeInterval?

    public init(
        recorder: any AudioRecording,
        transcriber: any Transcribing,
        inserter: any TextInserting,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        holdThreshold: TimeInterval = 0.35,
        minimumDuration: TimeInterval = 0.3
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.now = now
        self.holdThreshold = holdThreshold
        self.minimumSamples = Int(minimumDuration * Self.sampleRate)
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

    /// Stops recording and discards the audio without transcribing.
    public func cancel() {
        guard state == .recording else { return }
        pressedAt = nil
        _ = recorder.stop()
        level = 0
        state = .ready
    }

    /// Types the undelivered transcript again, e.g. after the user fixed the permission.
    public func retryUndelivered() {
        guard state == .ready, let text = undeliveredTranscript else { return }
        do {
            try inserter.insert(text)
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
        let samples = recorder.stop()
        level = 0
        guard samples.count >= minimumSamples else {
            state = .ready
            return
        }
        state = .transcribing
        Task { await transcribeAndInsert(samples) }
    }

    private func transcribeAndInsert(_ samples: [Float]) async {
        defer { state = .ready }
        let text: String
        do {
            text = TranscriptCleaner.clean(try await transcriber.transcribe(samples))
        } catch {
            report(error)
            return
        }
        guard !text.isEmpty else { return }
        do {
            try inserter.insert(text)
            undeliveredTranscript = nil
        } catch {
            undeliveredTranscript = text
            report("\(error.localizedDescription) Your dictation is kept in the menu bar menu.")
        }
    }
}
