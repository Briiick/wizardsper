import CoreML
import Foundation

/// The four CoreML models plus the tokenizer and metadata that make up one tier.
///
/// Loading is separated from recognition so the (slow, ~1 s) model load can
/// happen once at launch while the actor that uses them stays cheap to create.
public struct ModelBundle: @unchecked Sendable {
    public let directory: URL
    public let config: NemotronConfig
    public let tokenizer: NemotronTokenizer
    public let preprocessor: MLModel
    public let encoder: MLModel
    public let decoder: MLModel
    public let joint: MLModel

    /// The encoder is int8 and was converted for the Neural Engine. Under the
    /// default `.all` compute units CoreML routes int8 operations to the GPU
    /// instead, where this graph runs roughly an order of magnitude slower, so
    /// the encoder is pinned explicitly.
    public static func encoderConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    /// The preprocessor, decoder and joint are small float32 graphs. They are
    /// left on `.all` so CoreML can keep them wherever dispatch is cheapest —
    /// the decoder in particular is called several times per chunk, where
    /// round-trip latency dominates the arithmetic.
    public static func auxiliaryConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return configuration
    }

    public static func load(from directory: URL) async throws -> ModelBundle {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw WizardError.modelsMissing(directory.path)
        }

        let metadataURL = directory.appendingPathComponent("metadata.json")
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw WizardError.modelsMissing(metadataURL.path)
        }
        guard fileManager.fileExists(atPath: tokenizerURL.path) else {
            throw WizardError.modelsMissing(tokenizerURL.path)
        }

        let declared = try NemotronConfig(contentsOf: metadataURL)
        let tokenizer = try NemotronTokenizer(contentsOf: tokenizerURL)

        // Loads run concurrently; the 590 MB encoder dominates and there is no
        // reason for the three small models to queue behind it. Each call builds
        // its own MLModelConfiguration inside `loadModel` — the configuration
        // object is not Sendable, so it must not cross the task boundary.
        async let preprocessor = loadModel(directory, "preprocessor.mlmodelc", onNeuralEngine: false)
        async let encoder = loadModel(
            directory, "encoder/encoder_int8.mlmodelc", onNeuralEngine: true)
        async let decoder = loadModel(directory, "decoder.mlmodelc", onNeuralEngine: false)
        async let joint = loadModel(directory, "joint.mlmodelc", onNeuralEngine: false)

        // The compiled encoder, not the sidecar metadata, is the authority on
        // the mel budget and the hidden dimension.
        let encoderModel = try await encoder
        let config = try declared.reconciled(withEncoder: encoderModel.modelDescription)

        return ModelBundle(
            directory: directory,
            config: config,
            tokenizer: tokenizer,
            preprocessor: try await preprocessor,
            encoder: encoderModel,
            decoder: try await decoder,
            joint: try await joint)
    }

    private static func loadModel(
        _ directory: URL, _ relativePath: String, onNeuralEngine: Bool
    ) async throws -> MLModel {
        let url = directory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WizardError.modelsMissing(url.path)
        }
        let configuration =
            onNeuralEngine ? encoderConfiguration() : auxiliaryConfiguration()
        do {
            return try await MLModel.load(contentsOf: url, configuration: configuration)
        } catch {
            throw WizardError.modelLoadFailed(relativePath, underlying: error.localizedDescription)
        }
    }
}
