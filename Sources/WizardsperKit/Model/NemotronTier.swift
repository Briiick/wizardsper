import Foundation

/// A published chunk-size build of `nvidia/nemotron-speech-streaming-en-0.6b`.
///
/// Every tier is the same 0.6B FastConformer RNN-T; they differ only in how much
/// audio the encoder consumes per step, which trades latency against accuracy.
/// WERs below are the publisher's LibriSpeech test-clean numbers.
public enum NemotronTier: Int, CaseIterable, Sendable, Codable, Identifiable {
    case ms160 = 160
    case ms560 = 560
    case ms1120 = 1120
    case ms2240 = 2240

    public static let `default`: NemotronTier = .ms560

    public var id: Int { rawValue }

    public var chunkMilliseconds: Int { rawValue }

    public var displayName: String {
        switch self {
        case .ms160: return "160 ms · fastest"
        case .ms560: return "560 ms · balanced"
        case .ms1120: return "1120 ms · accurate"
        case .ms2240: return "2240 ms · most accurate"
        }
    }

    /// The *publisher's* word error rate on LibriSpeech test-clean, quoted as
    /// published. Named for its provenance because it is not a measurement of
    /// this app: the 160 ms figure in particular came from only 20 files, and
    /// Wizardsper's own front-end measures it as very close to the 560 ms tier
    /// (5.39% against 5.22% over 73 utterances of dev-clean). Do not present
    /// these as what a user should expect.
    public var publishedWER: String {
        switch self {
        case .ms160: return "~10% (20 files)"
        case .ms560: return "2.12%"
        case .ms1120: return "1.99%"
        case .ms2240: return "2.46%"
        }
    }

    /// Roughly how much disk a tier occupies, for a UI that is about to ask the
    /// user to commit to a download this size.
    public var approximateBytes: Int64 { 615_000_000 }

    public var subdirectory: String { "nemotron_coreml_\(rawValue)ms" }

    public static let repository = "FluidInference/nemotron-speech-streaming-en-0.6b-coreml"

    /// Revision to fetch from.
    ///
    /// The 160 ms and 80 ms tiers were deleted from `main` on 2026-06-05
    /// ("Remove v1 160ms tier (superseded by 2240/1120/560 + B1)"), so 160 ms
    /// pins the last commit that still contains it. The surviving tiers track
    /// `main`. A deleted tier would otherwise 404 at download time with no
    /// indication of why.
    public var revision: String {
        switch self {
        case .ms160: return "c7e2cf6aa07b"
        case .ms560, .ms1120, .ms2240: return "main"
        }
    }

    /// Files that must all be present for the tier to count as downloaded.
    /// `decoder_joint.mlmodelc` is deliberately excluded: only the tiers
    /// refreshed with the B1 fusion ship it, and it is an optimisation, not a
    /// requirement.
    public var requiredEntries: [String] {
        [
            "metadata.json",
            "tokenizer.json",
            "preprocessor.mlmodelc",
            "encoder/encoder_int8.mlmodelc",
            "decoder.mlmodelc",
            "joint.mlmodelc",
        ]
    }

}
