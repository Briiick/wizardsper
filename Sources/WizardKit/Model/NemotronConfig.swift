import Foundation

/// A tier's `metadata.json`, plus the values derived from it.
///
/// Everything the streaming algorithm needs is read from the bundle rather than
/// hard-coded, so switching tiers changes only this struct. Fields that older
/// bundles omit (`chunk_samples`, `encoder_output_frames`) are derived from the
/// fields that are always present.
public struct NemotronConfig: Sendable, Equatable {

    // MARK: - Front-end constants
    //
    // Fixed by the exported preprocessor graph, not by metadata.json:
    // pad = [256, 256] constant zero, conv stride 160 with a 512-wide kernel and
    // `valid` padding, pre-emphasis 0.97, natural log with a 2^-149 guard.

    public static let sampleRate = 16_000
    public static let hopLength = 160      // 10 ms
    public static let windowLength = 400   // 25 ms
    public static let fftLength = 512

    // MARK: - From metadata.json

    public let melFeatures: Int
    public let chunkMelFrames: Int
    public let chunkMilliseconds: Int
    public let preEncodeCache: Int
    public let totalMelFrames: Int
    public let vocabSize: Int
    public let blankIndex: Int
    public let encoderDim: Int
    public let decoderHidden: Int
    public let decoderLayers: Int
    public let cacheChannelShape: [Int]
    public let cacheTimeShape: [Int]

    // MARK: - Derived

    /// New audio consumed per streaming step.
    public var chunkSamples: Int { chunkMelFrames * Self.hopLength }

    /// Encoder frames produced per chunk. The FastConformer subsamples 8×, and
    /// the `preEncodeCache` frames exist only to give the pre-encode convolution
    /// stack left context — they produce no output.
    public var encoderOutputFrames: Int { chunkMelFrames / 8 }

    /// Seconds of audio behind one encoder output frame, for token timings.
    public var secondsPerEncoderFrame: Double {
        Double(Self.hopLength * 8) / Double(Self.sampleRate)
    }

    public var chunkDuration: Double {
        Double(chunkSamples) / Double(Self.sampleRate)
    }

    public var encoderMelShape: [Int] { [1, melFeatures, totalMelFrames] }
    public var decoderStateShape: [Int] { [decoderLayers, 1, decoderHidden] }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WizardError.modelLoadFailed("metadata.json", underlying: "not a JSON object")
        }
        func int(_ key: String, _ fallback: Int) -> Int { json[key] as? Int ?? fallback }

        self.melFeatures = int("mel_features", 128)
        self.chunkMelFrames = int("chunk_mel_frames", 56)
        self.chunkMilliseconds = int("chunk_ms", chunkMelFrames * 10)
        self.preEncodeCache = int("pre_encode_cache", 9)
        self.totalMelFrames = int("total_mel_frames", preEncodeCache + chunkMelFrames)
        self.vocabSize = int("vocab_size", 1024)
        self.blankIndex = int("blank_idx", vocabSize)
        self.encoderDim = int("encoder_dim", 1024)
        self.decoderHidden = int("decoder_hidden", 640)
        self.decoderLayers = int("decoder_layers", 2)
        self.cacheChannelShape = json["cache_channel_shape"] as? [Int] ?? [1, 24, 70, 1024]
        self.cacheTimeShape = json["cache_time_shape"] as? [Int] ?? [1, 24, 1024, 8]

        guard totalMelFrames == preEncodeCache + chunkMelFrames else {
            throw WizardError.modelLoadFailed(
                "metadata.json",
                underlying:
                    "total_mel_frames (\(totalMelFrames)) != pre_encode_cache (\(preEncodeCache)) "
                    + "+ chunk_mel_frames (\(chunkMelFrames))")
        }
        guard chunkMelFrames % 8 == 0 else {
            throw WizardError.modelLoadFailed(
                "metadata.json",
                underlying: "chunk_mel_frames (\(chunkMelFrames)) is not a multiple of the 8× "
                    + "encoder subsampling factor")
        }
    }
}
