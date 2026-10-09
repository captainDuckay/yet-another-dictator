import DictationCore
import Synchronization
import Testing

/// Counts calls from @Sendable callbacks.
private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

struct CaptureBufferTests {
    private func append(_ buffer: CaptureBuffer, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer.append($0) }
    }

    @Test func preRollKeepsTheNewestSamplesAndIsPrependedOnBegin() {
        let buffer = CaptureBuffer(capacity: 100, preRoll: 3)
        append(buffer, [1, 2, 3, 4, 5])
        buffer.begin { _ in }
        append(buffer, [6, 7])
        #expect(buffer.end() == [3, 4, 5, 6, 7])
    }

    @Test func clearedPreRollIsNotPrepended() {
        let buffer = CaptureBuffer(capacity: 100, preRoll: 3)
        append(buffer, [1, 2])
        buffer.clearPreRoll()
        buffer.begin { _ in }
        append(buffer, [3])
        #expect(buffer.end() == [3])
    }

    @Test func endReturnsAndClears() {
        let buffer = CaptureBuffer(capacity: 100, preRoll: 0)
        buffer.begin { _ in }
        #expect(buffer.isCapturing)
        append(buffer, [1, 2])
        #expect(buffer.end() == [1, 2])
        #expect(!buffer.isCapturing)
        #expect(buffer.end().isEmpty)
    }

    @Test func truncatesExactlyAtCapacity() {
        let buffer = CaptureBuffer(capacity: 4, preRoll: 0)
        let reached = Counter()
        buffer.onCapacityReached = { reached.increment() }
        buffer.begin { _ in }
        append(buffer, [1, 2, 3, 4]) // fills it exactly: nothing lost yet
        #expect(reached.count == 0)
        append(buffer, [5])
        #expect(buffer.end() == [1, 2, 3, 4])
        #expect(reached.count == 1)
    }

    @Test func truncatesAChunkThatOverflows() {
        let buffer = CaptureBuffer(capacity: 3, preRoll: 0)
        buffer.begin { _ in }
        append(buffer, [1, 2])
        append(buffer, [3, 4, 5])
        #expect(buffer.end() == [1, 2, 3])
    }

    @Test func capacityCallbackFiresOncePerCaptureAndAgainAfterBegin() {
        let buffer = CaptureBuffer(capacity: 2, preRoll: 0)
        let reached = Counter()
        buffer.onCapacityReached = { reached.increment() }

        buffer.begin { _ in }
        append(buffer, [1, 2, 3])
        append(buffer, [4])
        append(buffer, [5, 6])
        #expect(reached.count == 1)
        _ = buffer.end()

        buffer.begin { _ in }
        append(buffer, [1])
        #expect(reached.count == 1)
        append(buffer, [2, 3])
        #expect(reached.count == 2)
    }

    @Test func noCapacityCallbackOutsideACapture() {
        let buffer = CaptureBuffer(capacity: 1, preRoll: 2)
        let reached = Counter()
        buffer.onCapacityReached = { reached.increment() }
        append(buffer, [1, 2, 3, 4])
        #expect(reached.count == 0)
    }

    @Test func onLevelOnlyDuringACapture() {
        let buffer = CaptureBuffer(capacity: 100, preRoll: 4)
        let levels = Counter()
        append(buffer, [0.5])
        buffer.begin { _ in levels.increment() }
        append(buffer, [0.5, 0.5])
        #expect(levels.count == 1)
        _ = buffer.end()
        append(buffer, [0.5])
        #expect(levels.count == 1)
    }
}
