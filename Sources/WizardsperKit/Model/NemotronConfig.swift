import CoreML
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


    public var chunkDuration: Double {
        Double(chunkSamples) / Double(Self.sampleRate)
    }

    public var encoderMelShape: [Int] { [1, melFeatures, totalMelFrames] }
    public var decoderStateShape: [Int] { [decoderLayers, 1, decoderHidden] }

    /// Memberwise, for `reconciled(withEncoder:)` to build an adjusted copy.
    private init(
        melFeatures: Int, chunkMelFrames: Int, chunkMilliseconds: Int, preEncodeCache: Int,
        totalMelFrames: Int, vocabSize: Int, blankIndex: Int, encoderDim: Int,
        decoderHidden: Int, decoderLayers: Int, cacheChannelShape: [Int], cacheTimeShape: [Int]
    ) {
        self.melFeatures = melFeatures
        self.chunkMelFrames = chunkMelFrames
        self.chunkMilliseconds = chunkMilliseconds
        self.preEncodeCache = preEncodeCache
        self.totalMelFrames = totalMelFrames
        self.vocabSize = vocabSize
        self.blankIndex = blankIndex
        self.encoderDim = encoderDim
        self.decoderHidden = decoderHidden
        self.decoderLayers = decoderLayers
        self.cacheChannelShape = cacheChannelShape
        self.cacheTimeShape = cacheTimeShape
    }

    /// Take the encoder's own declared shapes over `metadata.json`.
    ///
    /// `metadata.json` is a sidecar written by the conversion script, not
    /// something CoreML enforces. The compiled encoder is the authority on what
    /// it actually emits, and the two can drift — a re-converted tier shipped
    /// with a stale sidecar would have every downstream buffer sized wrong, and
    /// the first symptom would be a shape error deep inside the RNN-T loop
    /// rather than at load.
    ///
    /// The encoder declares `mel` as `[1, melFeatures, totalMelFrames]` and
    /// `encoded` as `[1, encoderDim, encoderOutputFrames]`, which pins the mel
    /// budget and the hidden dimension between them.
    public func reconciled(withEncoder description: MLModelDescription) throws -> NemotronConfig {
        func shape(_ name: String, _ table: [String: MLFeatureDescription]) -> [Int]? {
            guard let constraint = table[name]?.multiArrayConstraint else { return nil }
            let dimensions = constraint.shape.map(\.intValue)
            return dimensions.contains(0) ? nil : dimensions
        }

        var melFeatures = self.melFeatures
        var totalMelFrames = self.totalMelFrames
        var encoderDim = self.encoderDim

        if let mel = shape("mel", description.inputDescriptionsByName), mel.count == 3 {
            if mel[1] != melFeatures {
                Log.model.notice(
                    "encoder declares \(mel[1]) mel bins; metadata.json said \(self.melFeatures)")
                melFeatures = mel[1]
            }
            if mel[2] != totalMelFrames {
                Log.model.notice(
                    "encoder declares \(mel[2]) mel frames; metadata.json said \(self.totalMelFrames)")
                totalMelFrames = mel[2]
            }
        }

        if let encoded = shape("encoded", description.outputDescriptionsByName), encoded.count == 3 {
            if encoded[1] != encoderDim {
                Log.model.notice(
                    "encoder declares a hidden dimension of \(encoded[1]); metadata.json said \(self.encoderDim)")
                encoderDim = encoded[1]
            }
            let chunkFrames = totalMelFrames - preEncodeCache
            guard encoded[2] == chunkFrames / 8 else {
                throw WizardsperError.modelLoadFailed(
                    "encoder",
                    underlying:
                        "declares \(encoded[2]) output frames, but \(chunkFrames) chunk mel frames "
                        + "subsample 8x to \(chunkFrames / 8) — the tier's files do not match")
            }
        }

        let chunkMelFrames = totalMelFrames - preEncodeCache
        guard chunkMelFrames > 0, chunkMelFrames % 8 == 0 else {
            throw WizardsperError.modelLoadFailed(
                "encoder",
                underlying: "a \(totalMelFrames)-frame input minus a \(preEncodeCache)-frame cache "
                    + "leaves \(chunkMelFrames) frames, which is not a usable chunk")
        }

        return NemotronConfig(
            melFeatures: melFeatures, chunkMelFrames: chunkMelFrames,
            chunkMilliseconds: chunkMelFrames * 10, preEncodeCache: preEncodeCache,
            totalMelFrames: totalMelFrames, vocabSize: vocabSize, blankIndex: blankIndex,
            encoderDim: encoderDim, decoderHidden: decoderHidden, decoderLayers: decoderLayers,
            cacheChannelShape: cacheChannelShape, cacheTimeShape: cacheTimeShape)
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WizardsperError.modelLoadFailed("metadata.json", underlying: "not a JSON object")
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
            throw WizardsperError.modelLoadFailed(
                "metadata.json",
                underlying:
                    "total_mel_frames (\(totalMelFrames)) != pre_encode_cache (\(preEncodeCache)) "
                    + "+ chunk_mel_frames (\(chunkMelFrames))")
        }
        guard chunkMelFrames % 8 == 0 else {
            throw WizardsperError.modelLoadFailed(
                "metadata.json",
                underlying: "chunk_mel_frames (\(chunkMelFrames)) is not a multiple of the 8× "
                    + "encoder subsampling factor")
        }
    }
}
