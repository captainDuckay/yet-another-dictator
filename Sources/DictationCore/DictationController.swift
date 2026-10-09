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
    public private(set) var lastError: String?

    @ObservationIgnored public var onStateChange: ((DictationState) -> Void)?

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

    private func startRecording() {
        do {
            try recorder.start { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
            lastError = nil
            state = .recording
        } catch {
            pressedAt = nil
            lastError = "Could not start microphone: \(error.localizedDescription)"
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
        do {
            let text = TranscriptCleaner.clean(try await transcriber.transcribe(samples))
            guard !text.isEmpty else { return }
            try inserter.insert(text)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
