import Foundation
import Synchronization

/// The input gain, in the one place the render thread can read it.
///
/// What this is and is not for, measured rather than assumed. Scaling clean
/// audio down does not hurt recognition at all — this model still scored 0.00%
/// WER on speech attenuated to 4% of full scale, because the log-mel front end
/// and the encoder's layer norms are indifferent to absolute level. Gain is
/// therefore **not** a quality knob.
///
/// What does hurt is a weak microphone, which is a different thing: it scales
/// the voice down against its own fixed electrical noise floor, so the
/// signal-to-noise ratio falls with the level. Measured on the same utterance
/// with a constant noise floor:
///
///     signal   no gain   16x gain
///     100%      0.00%      5.88%   <- gain clips a healthy signal and hurts
///      10%      0.00%      0.00%
///       4%      0.00%      0.00%
///       2%     23.53%      5.88%   <- gain earns its place here
///       1%   (nothing)    88.24%   <- past saving either way
///
/// So the honest summary: gain rescues a marginal input and damages a good one.
/// That asymmetry is why the dashboard pairs the slider with a live meter and
/// tells the user when they have gone too far — a control that can only make
/// things worse when misused must not be offered without a way to see what it
/// is doing.
///
/// The value lives here rather than in `AudioCapture` because the render thread
/// reads it on every buffer while the main actor writes it whenever the slider
/// moves, and neither may block the other — so it travels as a bit pattern
/// inside an atomic, the same handoff `LevelBox` uses in the other direction.
public final class GainBox: @unchecked Sendable {

    private let value: Atomic<UInt32>

    /// The usable range, as a linear multiplier. The bottom is −12 dB, for an
    /// input hot enough to clip; the top is +30 dB, which is what a very quiet
    /// built-in microphone actually needs.
    public static let minimum: Float = 0.25
    public static let maximum: Float = 32

    public init(_ gain: Float = 1) {
        value = Atomic(Self.clamp(gain).bitPattern)
    }

    /// Read by the tap, once per buffer.
    ///
    /// Relaxed: a buffer that uses the previous gain for a few milliseconds
    /// after the slider moves is not a defect, and demanding more ordering here
    /// would put a barrier on the render thread for nothing.
    public var current: Float {
        Float(bitPattern: value.load(ordering: .relaxed))
    }

    public func set(_ gain: Float) {
        value.store(Self.clamp(gain).bitPattern, ordering: .relaxed)
    }

    public static func clamp(_ gain: Float) -> Float {
        // NaN is the only value that cannot be ordered into the range, so it is
        // the only one that falls back to unity. Infinities clamp like any other
        // out-of-range number — treating them as "no value" would silently turn
        // a slider pinned to the top into no gain at all.
        guard !gain.isNaN else { return 1 }
        return min(max(gain, minimum), maximum)
    }

    // MARK: - Decibels
    //
    // The slider works in dB because gain is perceived logarithmically: the
    // linear range 1...32 spends three quarters of its travel on changes nobody
    // can hear, while the useful adjustments all sit in the first eighth.

    public static func decibels(fromLinear gain: Float) -> Double {
        Double(20 * log10(max(gain, .leastNormalMagnitude)))
    }

    public static func linear(fromDecibels decibels: Double) -> Float {
        clamp(Float(pow(10, decibels / 20)))
    }

    public static let minimumDecibels = decibels(fromLinear: minimum)
    public static let maximumDecibels = decibels(fromLinear: maximum)
}
