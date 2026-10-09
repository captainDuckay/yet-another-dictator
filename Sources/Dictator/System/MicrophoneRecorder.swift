@preconcurrency import AVFoundation
import DictationCore
import Synchronization

/// Microphone capture with AVAudioEngine, resampled to 16 kHz mono Float32.
///
/// Audio lives only in memory for the duration of one dictation and is never written to disk.
@MainActor
final class MicrophoneRecorder: AudioRecording {
    enum Failure: LocalizedError {
        case permissionDenied, noInputDevice, converterUnavailable
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
            case .noInputDevice: "No microphone input is available."
            case .converterUnavailable: "Cannot convert microphone audio to 16 kHz."
            }
        }
    }

    /// Hard cap so a forgotten recording can't grow without bound (10 minutes ≈ 38 MB).
    private static let maxSamples = Int(DictationController.sampleRate) * 60 * 10

    private var engine: AVAudioEngine?
    private let samples = SampleStore(capacity: maxSamples)

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard Permissions.microphone != .denied else { throw Failure.permissionDenied }
        _ = stop()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw Failure.noInputDevice }
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: DictationController.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw Failure.converterUnavailable }

        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat,
            block: Self.makeTap(converter: converter, outputFormat: outputFormat, store: samples, onLevel: onLevel)
        )
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return samples.drain()
    }

    /// Built outside the main actor: the tap runs on a realtime audio thread.
    private nonisolated static func makeTap(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        store: SampleStore,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = output.floatChannelData?[0] else { return }

            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            store.append(chunk)

            var sumOfSquares: Float = 0
            for sample in chunk { sumOfSquares += sample * sample }
            let rms = chunk.isEmpty ? 0 : (sumOfSquares / Float(chunk.count)).squareRoot()
            onLevel(min(1, rms * 8))
        }
    }
}

/// Thread-safe sample accumulator shared between the audio thread and the main actor.
final class SampleStore: Sendable {
    private let storage = Mutex<[Float]>([])
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        storage.withLock { samples in
            let room = capacity - samples.count
            guard room > 0 else { return }
            samples.append(contentsOf: chunk.prefix(room))
        }
    }

    func drain() -> [Float] {
        storage.withLock { samples in
            defer { samples = [] }
            return samples
        }
    }
}
