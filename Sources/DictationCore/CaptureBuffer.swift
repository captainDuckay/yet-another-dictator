import Synchronization

/// Thread-safe sample store shared between the realtime audio thread and the main actor.
///
/// While a dictation is being captured, samples accumulate up to `capacity`. Otherwise only the
/// newest pre-roll samples are kept, and they become the start of the next capture. The app's
/// audio tap feeds it; it has no audio dependencies itself, so it is tested in DictationCore.
public final class CaptureBuffer: Sendable {
    private struct State: Sendable {
        var isCapturing = false
        var samples: [Float] = []
        var preRoll: AudioRingBuffer
        var onLevel: (@Sendable (Float) -> Void)?
        var onCapacityReached: (@Sendable () -> Void)?
        /// Whether this capture already hit the capacity (and reported it).
        var reachedCapacity = false
    }

    private let state: Mutex<State>
    private let capacity: Int

    public init(capacity: Int, preRoll: Int) {
        self.capacity = capacity
        state = Mutex(State(preRoll: AudioRingBuffer(capacity: preRoll)))
    }

    /// Called once per capture, on the first chunk that doesn't fit. Runs on the thread calling
    /// `append` (the realtime audio thread), outside the lock, so it must return immediately,
    /// e.g. by hopping to another actor.
    public var onCapacityReached: (@Sendable () -> Void)? {
        get { state.withLock { $0.onCapacityReached } }
        set { state.withLock { $0.onCapacityReached = newValue } }
    }

    public var isCapturing: Bool { state.withLock { $0.isCapturing } }

    public func begin(onLevel: @escaping @Sendable (Float) -> Void) {
        state.withLock { state in
            state.samples = state.preRoll.samples
            state.preRoll.removeAll()
            state.onLevel = onLevel
            state.isCapturing = true
            state.reachedCapacity = false
        }
    }

    public func end() -> [Float] {
        state.withLock { state in
            defer { state.samples = [] }
            state.isCapturing = false
            state.onLevel = nil
            return state.samples
        }
    }

    public func clearPreRoll() {
        state.withLock { $0.preRoll.removeAll() }
    }

    public func append(_ chunk: UnsafeBufferPointer<Float>) {
        let (onLevel, onCapacityReached) = state.withLock {
            state -> ((@Sendable (Float) -> Void)?, (@Sendable () -> Void)?) in
            guard state.isCapturing else {
                state.preRoll.append(contentsOf: chunk)
                return (nil, nil)
            }
            let room = capacity - state.samples.count
            if room > 0 { state.samples.append(contentsOf: chunk.prefix(room)) }
            var capacityCallback: (@Sendable () -> Void)?
            if chunk.count > max(room, 0), !state.reachedCapacity {
                state.reachedCapacity = true
                capacityCallback = state.onCapacityReached
            }
            return (state.onLevel, capacityCallback)
        }
        onCapacityReached?()
        guard let onLevel else { return }
        var sumOfSquares: Float = 0
        for sample in chunk { sumOfSquares += sample * sample }
        let rms = chunk.isEmpty ? 0 : (sumOfSquares / Float(chunk.count)).squareRoot()
        onLevel(min(1, rms * 8))
    }
}
