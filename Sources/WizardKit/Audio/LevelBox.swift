import Dispatch
import Foundation
import Synchronization

/// The level meter's one shared word.
///
/// The tap has one number to tell the UI — how loud the last buffer was — and it
/// cannot use anything that blocks to say it. A `Float` is not directly atomic,
/// so it travels as its bit pattern inside an `Atomic<UInt32>`: one store on the
/// render thread, one exchange on the main actor, no lock on either side.
///
/// A raw RMS reading alone makes an ugly meter. Buffers arrive every few tens of
/// milliseconds while the UI redraws every 16 ms, so most frames would find no
/// new value and the bars would either freeze or snap to zero. `poll()` instead
/// maintains a decaying envelope: it jumps straight up to a new reading and
/// falls off exponentially when none arrives, which is what makes a meter look
/// like a meter rather than a strobe.
public final class LevelBox: @unchecked Sendable {

    /// Producer → consumer handoff. The tap stores the RMS of the buffer it just
    /// converted; `poll()` takes it and leaves zero behind, so the consumer can
    /// tell "a new buffer arrived" from "nothing since last time".
    private let latest = Atomic<UInt32>(0)

    /// The envelope, and the timestamp it was last advanced at. Both are written
    /// only by `poll()`, so a plain relaxed load/store pair is race-free even
    /// though they are two separate words: no other thread reads them as a pair.
    private let envelope = Atomic<UInt32>(0)
    private let lastPollNanos = Atomic<UInt64>(0)

    /// Time for the envelope to fall by half with no new audio. 120 ms tracks
    /// speech envelopes closely enough to look responsive without flickering on
    /// the gaps between words.
    public let halfLife: Double

    public init(halfLife: Double = 0.12) {
        self.halfLife = max(0.001, halfLife)
    }

    // MARK: - Producer (render thread)

    /// Publish the loudness of the buffer just captured, 0...1-ish RMS.
    ///
    /// One atomic store, nothing else — safe on the render thread. Non-finite
    /// values are rejected rather than stored: a NaN out of a misbehaving input
    /// device would poison the envelope permanently, since `max` with NaN is not
    /// well behaved and nothing downstream would ever clear it.
    public func store(_ level: Float) {
        guard level.isFinite, level >= 0 else { return }
        // Release so that, paired with the acquiring exchange in `poll`, the UI
        // cannot observe this value before the samples it was computed from were
        // written to the ring. Nothing depends on that ordering today, but a
        // meter that runs ahead of the waveform is the kind of bug that costs an
        // afternoon to find.
        latest.store(level.bitPattern, ordering: .releasing)
    }

    // MARK: - Consumer (main actor, ~60 Hz)

    /// Advance the envelope and return the value to draw.
    ///
    /// Call this once per displayed frame — it is not a pure getter: it consumes
    /// the pending reading and moves the decay forward in time. Use `current`
    /// for a look that does not advance anything.
    @discardableResult
    public func poll() -> Float {
        let reading = Float(bitPattern: latest.exchange(0, ordering: .acquiring))

        let now = DispatchTime.now().uptimeNanoseconds
        let previousTick = lastPollNanos.exchange(now, ordering: .relaxed)
        let elapsed = previousTick == 0 ? 0 : Double(now &- previousTick) / 1_000_000_000

        // Exponential decay expressed as a half-life rather than a per-frame
        // multiplier, so the meter falls at the same rate whether the UI is
        // running at 120 Hz, 60 Hz, or dropping frames under load.
        let decayed = Float(bitPattern: envelope.load(ordering: .relaxed))
            * Float(exp2(-elapsed / halfLife))

        // Instant attack, slow release: a transient must be visible on the very
        // next frame, or the meter lags the voice noticeably.
        let next = max(reading, decayed.isFinite ? decayed : 0)
        envelope.store(next.bitPattern, ordering: .relaxed)
        return next
    }

    /// The last value `poll()` produced, without advancing the decay. For code
    /// that wants to read the meter without owning its cadence.
    public var current: Float {
        Float(bitPattern: envelope.load(ordering: .relaxed))
    }

    /// Drop the envelope to silence. Called when a session ends so the next one
    /// does not open with the tail of the previous one's last syllable.
    public func reset() {
        latest.store(0, ordering: .releasing)
        envelope.store(0, ordering: .relaxed)
        lastPollNanos.store(0, ordering: .relaxed)
    }
}
