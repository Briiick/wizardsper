import Foundation
import Synchronization

/// The hand-off between the audio render thread and the recogniser.
///
/// The tap that CoreAudio calls runs on a real-time thread with a hard deadline
/// (a few milliseconds at typical I/O buffer sizes). Anything that can block
/// that thread — a mutex the drain task happens to hold, a `malloc` that takes
/// the allocator lock, an ObjC message send that hits a cache miss — shows up as
/// a dropout in the recording, and dropouts are unrecoverable: the samples are
/// simply gone. So the producer side of this buffer touches nothing but plain
/// memory and two atomics.
///
/// It is a strict single-producer/single-consumer ring: exactly one thread calls
/// `write`, exactly one task calls `read`. That is what lets each index have a
/// single writer and therefore need no compare-exchange loop. Two producers, or
/// two consumers, would corrupt it silently.
///
/// Capacity is fixed at `init` and never grows. A hold-to-talk session that
/// outruns the recogniser loses its oldest-unread audio rather than growing
/// without bound, and `droppedFrames` records exactly how much, so an overrun
/// is visible in the log instead of being mistaken for a bad transcript.
public final class AudioRingBuffer: @unchecked Sendable {

    /// `@unchecked Sendable` invariant: `storage` is allocated once in `init`
    /// and freed once in `deinit`; between those it is never reassigned, so the
    /// pointer itself is immutable shared state. The *contents* are shared, but
    /// the read and write indices below partition them — the producer only ever
    /// touches slots the consumer has released, and vice versa.
    private let storage: UnsafeMutablePointer<Float>

    /// Number of frames the ring holds. Fixed for the lifetime of the object.
    public let capacity: Int

    /// Total frames ever written and ever read, monotonically increasing rather
    /// than wrapped. Using running totals instead of wrapped indices removes the
    /// classic full-vs-empty ambiguity (`head == tail` means empty, always) at
    /// the cost of one modulo per copy. `Int` is 64-bit here: at 16 kHz it would
    /// take about eighteen million years to overflow, and the `&+` below keeps
    /// even that case defined.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    /// Frames the producer had to throw away because the consumer fell behind.
    /// Diagnostic only, so both sides use relaxed ordering: an exact value is
    /// not needed, a non-zero value is.
    private let dropped = Atomic<Int>(0)

    /// 60 s at 16 kHz. Long enough that no plausible hold overruns it, and 3.8 MB
    /// is cheap enough to allocate once and keep for the life of the app rather
    /// than per session — allocating per session would put a multi-megabyte
    /// `malloc` on the path between the key going down and the first sample.
    public static let defaultCapacity = NemotronConfig.sampleRate * 60

    public init(capacity: Int = AudioRingBuffer.defaultCapacity) {
        // Clamped rather than asserted: a zero-capacity ring is a programming
        // error, but trapping inside an audio path is worse than degrading to a
        // one-frame ring that reports every frame as dropped.
        let size = max(1, capacity)
        self.capacity = size
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: size)
        self.storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    // MARK: - Producer (render thread)

    /// Append `source` to the ring, dropping whatever does not fit.
    ///
    /// Allocates nothing, takes no lock, and sends no ObjC message, so it is
    /// safe to call from the CoreAudio render thread. Returns the number of
    /// frames actually stored; the shortfall is added to `droppedFrames`.
    @discardableResult
    public func write(_ source: UnsafeBufferPointer<Float>) -> Int {
        guard let base = source.baseAddress, !source.isEmpty else { return 0 }

        // This thread is the only writer of `written`, so it can read its own
        // value relaxed. `read` is published by the consumer with a release
        // store; acquiring it here is what guarantees we do not start
        // overwriting slots the consumer is still copying out of.
        let head = written.load(ordering: .relaxed)
        let tail = read.load(ordering: .acquiring)

        let free = capacity - (head &- tail)
        let count = min(source.count, max(0, free))
        if count < source.count {
            let loss = source.count - count
            let previous = dropped.load(ordering: .relaxed)
            dropped.store(previous &+ loss, ordering: .relaxed)
        }
        guard count > 0 else { return 0 }

        // At most two contiguous runs: up to the end of the allocation, then
        // from the start. `update(from:count:)` on a trivial type lowers to
        // `memcpy` — no allocation, no retain traffic.
        let start = head % capacity
        let firstRun = min(count, capacity - start)
        storage.advanced(by: start).update(from: base, count: firstRun)
        if count > firstRun {
            storage.update(from: base + firstRun, count: count - firstRun)
        }

        // Release: every store to `storage` above must be visible to the
        // consumer before it can observe the larger index, otherwise the
        // consumer reads slots it believes are filled but that still hold the
        // previous lap's samples.
        written.store(head &+ count, ordering: .releasing)
        return count
    }

    // MARK: - Consumer (drain task)

    /// Copy up to `destination.count` frames out of the ring. Returns the number
    /// copied, which is zero when the producer has not produced anything yet.
    public func read(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = destination.baseAddress, !destination.isEmpty else { return 0 }

        // Mirror image of `write`: this task owns `read`, and acquiring
        // `written` is what makes the producer's sample stores visible here.
        let tail = read.load(ordering: .relaxed)
        let head = written.load(ordering: .acquiring)

        let count = min(destination.count, head &- tail)
        guard count > 0 else { return 0 }

        let start = tail % capacity
        let firstRun = min(count, capacity - start)
        base.update(from: storage.advanced(by: start), count: firstRun)
        if count > firstRun {
            (base + firstRun).update(from: storage, count: count - firstRun)
        }

        // Release: the copies above must complete before the producer can see
        // these slots as free, or the producer overwrites data still in flight.
        read.store(tail &+ count, ordering: .releasing)
        return count
    }

    /// Frames sitting in the ring right now. Safe to call from either side; the
    /// value is a lower bound from the consumer's point of view, because the
    /// producer may append between the load and the caller acting on it.
    public var availableToRead: Int {
        let head = written.load(ordering: .acquiring)
        let tail = read.load(ordering: .acquiring)
        return max(0, head &- tail)
    }

    /// Frames the producer threw away since the last `reset`. Non-zero means the
    /// consumer did not keep up and the recording has a hole in it.
    public var droppedFrames: Int {
        dropped.load(ordering: .relaxed)
    }

    /// Discard everything and start a new session.
    ///
    /// Not safe to call while a producer is writing: it moves both indices at
    /// once, which no amount of ordering can make atomic as a pair. Call it
    /// between sessions, with the tap removed — that is the only time the
    /// single-producer invariant lets it be correct.
    public func reset() {
        written.store(0, ordering: .sequentiallyConsistent)
        read.store(0, ordering: .sequentiallyConsistent)
        dropped.store(0, ordering: .relaxed)
    }
}
