import Foundation

/// How one chunk of audio is framed before it reaches the CoreML preprocessor.
///
/// The preprocessor is a center-padded STFT: it zero-pads `n_fft/2 = 256`
/// samples on each end, then strides a 512-wide window by `hop = 160`. For an
/// input of `L` samples it emits `floor(L/160) + 1` frames and reports
/// `mel_length = floor(L/160)`, masking the final frame to zero. Frame `t` is
/// centered on input sample `160 * t`.
///
/// A chunk cannot simply be handed over on its own: the frames near each edge
/// would be computed against the preprocessor's own zero padding rather than the
/// neighbouring audio, and that discontinuity recurs at every chunk boundary.
/// So each chunk is widened with real audio on one or both sides, and the frames
/// that belong to the chunk are selected out of the result.
///
/// `windowSamples` is constant for a given tier, which is the property that
/// matters most at runtime — see `StreamingASR` for why the preprocessor must
/// never see a second input length.
public struct FramingPolicy: Sendable, Equatable, Codable {
    /// Real audio retained from the previous chunk, prepended to this one.
    public var lookback: Int
    /// Real audio from the *next* chunk that must arrive before this chunk runs.
    /// Non-zero values buy full-context edge frames at the cost of that much
    /// added latency.
    public var lookahead: Int
    /// Index of the first preprocessor frame that belongs to this chunk.
    public var frameOffset: Int

    public init(lookback: Int, lookahead: Int, frameOffset: Int) {
        self.lookback = lookback
        self.lookahead = lookahead
        self.frameOffset = frameOffset
    }

    /// One hop short of a full analysis window (`win_length - hop = 400 - 160`)
    /// of history, no lookahead. This is the lowest-latency option: a chunk runs
    /// the instant its last sample lands. Its first selected frame still reaches
    /// 96 samples into the preprocessor's zero padding.
    public static let lowLatency = FramingPolicy(lookback: 240, lookahead: 0, frameOffset: 1)

    /// Half an FFT of real audio on each side, so every selected frame is
    /// computed entirely from real samples and no frame ever sees the
    /// preprocessor's padding. Costs 256 samples (16 ms) of lookahead.
    public static let fullContext = FramingPolicy(lookback: 256, lookahead: 256, frameOffset: 2)

    public static let `default` = FramingPolicy.fullContext

    public func windowSamples(chunkSamples: Int) -> Int {
        lookback + chunkSamples + lookahead
    }

    /// Frames the preprocessor emits for this window, and how many of them are
    /// unmasked. The last frame is always masked to zero by the model.
    public func frameCounts(chunkSamples: Int) -> (emitted: Int, valid: Int) {
        let valid = windowSamples(chunkSamples: chunkSamples) / NemotronConfig.hopLength
        return (valid + 1, valid)
    }

    /// True when every frame this policy selects is unmasked by the model.
    public func selectionIsValid(chunkSamples: Int, chunkMelFrames: Int) -> Bool {
        let (_, valid) = frameCounts(chunkSamples: chunkSamples)
        return frameOffset >= 0 && frameOffset + chunkMelFrames <= valid
    }
}
