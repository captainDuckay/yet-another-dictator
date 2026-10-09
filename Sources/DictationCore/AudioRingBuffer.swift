/// Keeps only the most recent `capacity` samples.
///
/// Used for the microphone pre-roll: while the microphone is kept ready, the last fraction of a
/// second is held here so a dictation can include the syllable spoken just before the shortcut
/// registered. Older audio is overwritten and never leaves memory.
public struct AudioRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [Float]
    private var start = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    public mutating func append<C: Collection>(contentsOf samples: C) where C.Element == Float {
        guard capacity > 0 else { return }
        // Only the newest `capacity` samples can survive.
        for sample in samples.suffix(capacity) {
            let end = (start + count) % capacity
            storage[end] = sample
            if count < capacity {
                count += 1
            } else {
                start = (start + 1) % capacity
            }
        }
    }

    /// The held samples, oldest first.
    public var samples: [Float] {
        (0..<count).map { storage[(start + $0) % capacity] }
    }

    public mutating func removeAll() {
        start = 0
        count = 0
    }
}
