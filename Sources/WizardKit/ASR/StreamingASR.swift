import Accelerate
import CoreML
import Foundation

/// Cache-aware streaming recognition over the Nemotron FastConformer RNN-T.
///
/// One chunk of audio at a time: window it, run the preprocessor to log-mel,
/// prepend the mel frames the pre-encode convolutions need for left context,
/// run the encoder (which carries its own attention and convolution caches
/// across chunks), then greedily decode the encoder frames into tokens. Nothing
/// is re-processed — the caches are what make this streaming rather than
/// repeated batch transcription of a growing buffer.
///
/// An actor because the models, the caches and the LSTM state are one
/// indivisible piece of mutable state: two chunks running concurrently would
/// interleave cache writes and desynchronise the decoder from the encoder.
public actor StreamingASR {

    // MARK: - Immutable configuration

    public let config: NemotronConfig
    public let framing: FramingPolicy
    private let bundle: ModelBundle

    /// The one and only length the preprocessor is ever called with.
    ///
    /// The preprocessor's `audio` input is a flexible `RangeDim` of 1...480000.
    /// CoreML specialises the execution plan per concrete shape, so every new
    /// length triggers a full plan rebuild — hundreds of milliseconds on the
    /// audio path, and under memory pressure it is where the process dies. So
    /// the input tensor is allocated once at this length and never resized;
    /// a short final chunk is zero-extended into it and bounded by
    /// `audio_length` instead.
    ///
    /// The zero extension is safe because the graph masks on `audio_length`
    /// twice over: samples past the length are excluded from the framing, and
    /// mel frames past `audio_length / 160` are forced to zero on the way out.
    private let windowSamples: Int

    /// Frames the preprocessor emits per window: `floor(L / 160) + 1`, of which
    /// the last is always masked to zero.
    private let emittedFrames: Int
    private let maxSymbolsPerFrame = 10

    // MARK: - Reused CoreML tensors
    //
    // Allocated once. Rebuilding these per chunk would put a 2 MB allocation on
    // the path that has to keep up with real time.

    private let audioInput: MLMultiArray
    private let audioLengthInput: MLMultiArray
    private let melInput: MLMultiArray
    private let melLengthInput: MLMultiArray
    private let encoderStepInput: MLMultiArray
    private let tokenInput: MLMultiArray
    private let tokenLengthInput: MLMultiArray

    // MARK: - Streaming state

    /// `lookback` samples of history followed by audio not yet consumed. Seeded
    /// with zeros so the first chunk has the same shape as every other one.
    private var window: [Float]
    /// Real samples fed in that have not yet been the new part of a chunk.
    private var unconsumedReal = 0

    /// The `preEncodeCache` mel frames immediately preceding this chunk's
    /// frames, laid out bin-major (`melFeatures × preEncodeCache`) to match the
    /// encoder's `[1, mel, time]` input. Zeros at the start of a session, which
    /// is what the encoder expects for "no history".
    private var melCache: [Float]
    /// Dense, stride-flattened copy of the preprocessor's output.
    private var melScratch: [Float]

    private var cacheChannel: MLMultiArray
    private var cacheTime: MLMultiArray
    private var cacheLen: MLMultiArray
    private var hState: MLMultiArray
    private var cState: MLMultiArray
    private var lastToken: Int32

    /// `decoder_out` for the current `(lastToken, hState, cState)`.
    ///
    /// The prediction network only advances when a non-blank symbol is emitted,
    /// so its output is constant across every encoder frame that decodes to a
    /// blank. Recomputing it per joint call — as the straightforward loop does —
    /// runs the 28 MB LSTM several times per chunk for an identical answer.
    private var decoderOut: MLMultiArray?

    private var tokenIDs: [Int] = []
    private var timings: [TokenTiming] = []
    /// Snapshot taken by `finish()` before it clears `timings`.
    private var finishedTimings: [TokenTiming] = []
    private var frameBase = 0
    public private(set) var processedChunks = 0

    /// One decoded token and the encoder frame it was emitted on.
    public struct TokenTiming: Sendable, Equatable {
        public let tokenID: Int
        public let piece: String
        public let start: Double
        public let end: Double
    }

    // MARK: - Init

    public init(bundle: ModelBundle, framing: FramingPolicy = .default) throws {
        self.bundle = bundle
        self.config = bundle.config
        self.framing = framing

        let chunkSamples = config.chunkSamples
        guard framing.selectionIsValid(
            chunkSamples: chunkSamples, chunkMelFrames: config.chunkMelFrames)
        else {
            throw WizardError.modelLoadFailed(
                "framing",
                underlying:
                    "policy (lookback \(framing.lookback), lookahead \(framing.lookahead), "
                    + "offset \(framing.frameOffset)) selects frames past the masked boundary "
                    + "for a \(config.chunkMelFrames)-frame chunk")
        }
        guard config.chunkMelFrames >= config.preEncodeCache else {
            throw WizardError.modelLoadFailed(
                "framing",
                underlying:
                    "a \(config.chunkMelFrames)-frame chunk cannot supply the "
                    + "\(config.preEncodeCache)-frame pre-encode cache the next chunk needs")
        }

        self.windowSamples = framing.windowSamples(chunkSamples: chunkSamples)
        self.emittedFrames = framing.frameCounts(chunkSamples: chunkSamples).emitted

        self.audioInput = try MLArrayReader.float32(shape: [1, windowSamples])
        self.audioLengthInput = try MLArrayReader.int32(shape: [1], value: Int32(windowSamples))
        self.melInput = try MLArrayReader.float32(shape: config.encoderMelShape)
        self.melLengthInput = try MLArrayReader.int32(
            shape: [1], value: Int32(config.totalMelFrames))
        self.encoderStepInput = try MLArrayReader.float32(shape: [1, config.encoderDim, 1])
        self.tokenInput = try MLArrayReader.int32(shape: [1, 1])
        self.tokenLengthInput = try MLArrayReader.int32(shape: [1], value: 1)

        self.window = [Float](repeating: 0, count: framing.lookback)
        self.melCache = [Float](repeating: 0, count: config.melFeatures * config.preEncodeCache)
        self.melScratch = [Float](repeating: 0, count: config.melFeatures * emittedFrames)

        self.cacheChannel = try MLArrayReader.float32(shape: config.cacheChannelShape)
        self.cacheTime = try MLArrayReader.float32(shape: config.cacheTimeShape)
        self.cacheLen = try MLArrayReader.int32(shape: [1], value: 1)
        self.hState = try MLArrayReader.float32(shape: config.decoderStateShape)
        self.cState = try MLArrayReader.float32(shape: config.decoderStateShape)
        self.lastToken = Int32(config.blankIndex)
    }

    // MARK: - Session lifecycle

    /// Return to the state a fresh session starts in. Cheap — no model reload.
    public func reset() throws {
        window = [Float](repeating: 0, count: framing.lookback)
        unconsumedReal = 0
        MLArrayReader.zero(cacheChannel)
        MLArrayReader.zero(cacheTime)
        MLArrayReader.zero(hState)
        MLArrayReader.zero(cState)
        // Seeded to 1, not 0: the encoder's `slice_by_index` on the cache would
        // see a zero-length slice at 0, which fails CoreML's shape inference and
        // forces it to re-plan the graph on every single session start. The
        // cache buffers themselves are zero, so this reads as one frame of
        // silence rather than as real history.
        cacheLen[0] = 1
        for i in melCache.indices { melCache[i] = 0 }
        lastToken = Int32(config.blankIndex)
        decoderOut = nil
        tokenIDs.removeAll(keepingCapacity: true)
        timings.removeAll(keepingCapacity: true)
        finishedTimings.removeAll(keepingCapacity: true)
        frameBase = 0
        processedChunks = 0
    }

    /// Run one chunk of silence to force CoreML to build its execution plans and
    /// to prove the encoder actually came up.
    ///
    /// The int8 encoder's Neural Engine program can fail to instantiate on a
    /// cold start. When it does, `prediction` does not throw — it returns an
    /// all-zero `encoded` buffer, the greedy loop sees nothing but blanks, and
    /// the user gets an empty transcript with no error anywhere. A healthy
    /// encoder cannot return all zeros for non-zero input, because the
    /// LayerNorm biases alone guarantee otherwise, so one probe separates the
    /// two cases.
    public func warmUp() throws {
        try autoreleasepool {
            melInput.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                guard let pointer = buffer.baseAddress else { return }
                // A ramp rather than a constant, so nothing can cancel to zero.
                for i in 0..<buffer.count { pointer[i] = Float(i % 17) * 0.01 + 0.1 }
            }
            let output = try runEncoder(adoptCaches: false)
            let encoded = try MLArrayReader.output(
                output, "encoded", expecting: [1, config.encoderDim, -1])
            if try MLArrayReader.isAllZero(encoded, named: "encoded") {
                throw WizardError.encoderProducedSilence
            }
        }
        try reset()

        // Then push one real chunk of silence through the whole pipeline. The
        // encoder probe above does not touch the preprocessor, the decoder or
        // the joint — and the preprocessor is precisely the model whose plan is
        // expensive to build, because its `audio` input is a flexible shape and
        // CoreML specialises per concrete length. Warming only the encoder would
        // leave that build to land on the user's first hold, which is the cost
        // the single fixed input length exists to avoid paying twice.
        _ = try feed([Float](repeating: 0, count: config.chunkSamples))
        _ = try finish()
        try reset()
    }

    // MARK: - Feeding audio

    /// Append captured audio and process every chunk it completes.
    /// Returns the updated partial transcript when new tokens were decoded.
    @discardableResult
    public func feed(_ samples: [Float]) throws -> String? {
        guard !samples.isEmpty else { return nil }
        window.append(contentsOf: samples)
        unconsumedReal += samples.count

        var decodedAnything = false
        while window.count >= windowSamples {
            let real = min(windowSamples, framing.lookback + unconsumedReal)
            if try runChunk(audioLength: real) { decodedAnything = true }
            advanceWindow()
        }
        return decodedAnything ? bundle.tokenizer.decode(tokenIDs) : nil
    }

    /// Drain whatever audio is left, zero-extending the last window, and return
    /// the final transcript. Safe to call with nothing buffered.
    public func finish() throws -> String {
        while unconsumedReal > 0 {
            let real = min(windowSamples, framing.lookback + unconsumedReal)
            if window.count < windowSamples {
                window.append(
                    contentsOf: repeatElement(0, count: windowSamples - window.count))
            }
            _ = try runChunk(audioLength: real)
            advanceWindow()
        }
        let transcript = bundle.tokenizer.decode(tokenIDs)
        // Clear the token stream here, not only in reset(). finish() means the
        // utterance is over, and a caller that forgets to reset would otherwise
        // have its next transcript silently prefixed with this one — a failure
        // that looks like the recogniser hallucinating rather than like missing
        // bookkeeping. The encoder caches and LSTM state still need reset().
        finishedTimings = timings
        tokenIDs.removeAll(keepingCapacity: true)
        timings.removeAll(keepingCapacity: true)
        return transcript
    }

    /// Token timings for the utterance the last `finish()` returned.
    public var lastFinishedTimings: [TokenTiming] { finishedTimings }

    public var partialTranscript: String {
        bundle.tokenizer.decode(tokenIDs)
    }

    public var tokenTimings: [TokenTiming] { timings }

    private func advanceWindow() {
        window.removeFirst(min(config.chunkSamples, window.count))
        unconsumedReal -= min(config.chunkSamples, unconsumedReal)
        // Keep the invariant that the window always opens with `lookback`
        // samples of context, even after the final short drain.
        if window.count < framing.lookback {
            window.append(
                contentsOf: repeatElement(0, count: framing.lookback - window.count))
        }
    }

    // MARK: - One chunk

    /// The whole per-chunk pipeline, inside a single autorelease pool.
    ///
    /// Every CoreML `prediction` hands back autoreleased Objective-C objects —
    /// feature providers, the output arrays, their backing buffers. Without a
    /// pool scoped to the chunk they accumulate until the enclosing pool drains,
    /// which on a Task-driven audio loop may be never: the resident set climbs
    /// by the size of an encoder output every chunk until the app is killed.
    /// Synchronous predictions keep every one of those objects inside this pool.
    ///
    /// Returns whether any token was decoded.
    private func runChunk(audioLength: Int) throws -> Bool {
        try autoreleasepool {
            try writeWindowToAudioInput(audioLength: audioLength)

            let melOutput = try predict(
                bundle.preprocessor, inputs: ["audio": audioInput, "audio_length": audioLengthInput],
                named: "preprocessor")
            let mel = try MLArrayReader.output(
                melOutput, "mel", expecting: [1, config.melFeatures, -1])

            let producedFrames = MLArrayReader.shape(of: mel)[2]
            guard producedFrames >= framing.frameOffset + config.chunkMelFrames else {
                throw WizardError.modelShapeMismatch(
                    name: "mel",
                    expected: [1, config.melFeatures, framing.frameOffset + config.chunkMelFrames],
                    actual: MLArrayReader.shape(of: mel))
            }
            if producedFrames != emittedFrames {
                // A different frame count means the framing arithmetic and the
                // graph disagree; the selection window would silently slide.
                throw WizardError.modelShapeMismatch(
                    name: "mel", expected: [1, config.melFeatures, emittedFrames],
                    actual: MLArrayReader.shape(of: mel))
            }
            try melScratch.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress else { return }
                try MLArrayReader.copy(mel, named: "mel", into: base)
            }

            buildEncoderMelInput()
            let encoderOutput = try runEncoder(adoptCaches: true)
            let encoded = try MLArrayReader.output(
                encoderOutput, "encoded", expecting: [1, config.encoderDim, -1])

            captureMelCache()
            let newTokens = try decode(encoded: encoded)

            processedChunks += 1
            return !newTokens.isEmpty
        }
    }

    private func writeWindowToAudioInput(audioLength: Int) throws {
        precondition(window.count >= windowSamples, "window is short of one full input length")
        audioLengthInput[0] = NSNumber(value: Int32(audioLength))
        audioInput.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            guard let destination = buffer.baseAddress else { return }
            window.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base, count: windowSamples)
            }
        }
    }

    /// `melInput` = [ `preEncodeCache` cached frames | this chunk's frames ].
    ///
    /// The cached frames produce no encoder output; they exist purely so the
    /// pre-encode convolution stack sees real left context at the chunk
    /// boundary instead of zeros, which would otherwise put a seam in the
    /// features every chunk.
    private func buildEncoderMelInput() {
        let mels = config.melFeatures
        let cacheFrames = config.preEncodeCache
        let chunkFrames = config.chunkMelFrames
        let totalFrames = config.totalMelFrames
        let offset = framing.frameOffset
        let produced = emittedFrames

        melInput.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            guard let destination = buffer.baseAddress else { return }
            let binStride = strides[1]
            let timeStride = strides[2]
            melCache.withUnsafeBufferPointer { cache in
                melScratch.withUnsafeBufferPointer { scratch in
                    guard let cacheBase = cache.baseAddress,
                        let scratchBase = scratch.baseAddress
                    else { return }
                    for bin in 0..<mels {
                        let row = destination + bin * binStride
                        let cacheRow = cacheBase + bin * cacheFrames
                        for t in 0..<cacheFrames {
                            row[t * timeStride] = cacheRow[t]
                        }
                        let chunkRow = scratchBase + bin * produced + offset
                        for t in 0..<chunkFrames {
                            row[(cacheFrames + t) * timeStride] = chunkRow[t]
                        }
                    }
                    _ = totalFrames
                }
            }
        }
    }

    /// Keep the last `preEncodeCache` of *this chunk's selected* frames. Because
    /// consecutive windows advance by exactly `chunkMelFrames`, those are the
    /// frames immediately preceding the next chunk's first frame — contiguous on
    /// the same global 10 ms grid, with no gap and no duplicate.
    private func captureMelCache() {
        let mels = config.melFeatures
        let cacheFrames = config.preEncodeCache
        let start = framing.frameOffset + config.chunkMelFrames - cacheFrames
        let produced = emittedFrames

        melScratch.withUnsafeBufferPointer { scratch in
            guard let scratchBase = scratch.baseAddress else { return }
            melCache.withUnsafeMutableBufferPointer { cache in
                guard let cacheBase = cache.baseAddress else { return }
                for bin in 0..<mels {
                    let source = scratchBase + bin * produced + start
                    let destination = cacheBase + bin * cacheFrames
                    destination.update(from: source, count: cacheFrames)
                }
            }
        }
    }

    /// Run the encoder and, unless this is a throwaway probe, adopt the caches
    /// it returns. Adopting them is what carries attention and convolution
    /// context into the next chunk.
    private func runEncoder(adoptCaches: Bool) throws -> MLFeatureProvider {
        let output = try predict(
            bundle.encoder,
            inputs: [
                "mel": melInput,
                "mel_length": melLengthInput,
                "cache_channel": cacheChannel,
                "cache_time": cacheTime,
                "cache_len": cacheLen,
            ],
            named: "encoder")

        if adoptCaches {
            cacheChannel = try MLArrayReader.output(
                output, "cache_channel_out", expecting: config.cacheChannelShape)
            cacheTime = try MLArrayReader.output(
                output, "cache_time_out", expecting: config.cacheTimeShape)
            cacheLen = try MLArrayReader.output(output, "cache_len_out", expecting: [1])
        }
        return output
    }

    // MARK: - Greedy RNN-T

    private func decode(encoded: MLMultiArray) throws -> [Int] {
        let frames = MLArrayReader.shape(of: encoded)[2]
        var newTokens: [Int] = []

        if decoderOut == nil {
            try advanceDecoder(to: lastToken)
        }

        for frame in 0..<frames {
            try encoderStepInput.withUnsafeMutableBufferPointer(ofType: Float.self) {
                buffer, _ in
                guard let destination = buffer.baseAddress else { return }
                try MLArrayReader.timeStep(
                    encoded, named: "encoded", time: frame, into: destination)
            }

            var symbols = 0
            while symbols < maxSymbolsPerFrame {
                guard let prediction = decoderOut else {
                    throw WizardError.modelOutputMissing("decoder_out")
                }
                let jointOutput = try predict(
                    bundle.joint,
                    inputs: ["encoder": encoderStepInput, "decoder": prediction],
                    named: "joint")
                let logits = try MLArrayReader.output(jointOutput, "logits")
                let (token, _) = try MLArrayReader.argmax(logits, named: "logits")

                // Blank means "this encoder frame is spent"; move to the next.
                if token == config.blankIndex { break }

                newTokens.append(token)
                tokenIDs.append(token)
                let start = Double(frameBase + frame) * config.secondsPerEncoderFrame
                timings.append(
                    TokenTiming(
                        tokenID: token, piece: bundle.tokenizer.piece(token),
                        start: start, end: start + config.secondsPerEncoderFrame))

                lastToken = Int32(token)
                try advanceDecoder(to: lastToken)
                symbols += 1
            }
        }

        frameBase += frames
        return newTokens
    }

    /// Step the prediction network onto `token`, adopting its new LSTM state.
    private func advanceDecoder(to token: Int32) throws {
        tokenInput[0] = NSNumber(value: token)
        let output = try predict(
            bundle.decoder,
            inputs: [
                "token": tokenInput,
                "token_length": tokenLengthInput,
                "h_in": hState,
                "c_in": cState,
            ],
            named: "decoder")
        decoderOut = try MLArrayReader.output(
            output, "decoder_out", expecting: [1, config.decoderHidden, -1])
        hState = try MLArrayReader.output(output, "h_out", expecting: config.decoderStateShape)
        cState = try MLArrayReader.output(output, "c_out", expecting: config.decoderStateShape)
    }

    // MARK: - Prediction

    private func predict(
        _ model: MLModel, inputs: [String: MLMultiArray], named name: String
    ) throws -> MLFeatureProvider {
        let features = inputs.mapValues { MLFeatureValue(multiArray: $0) }
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: features)
            return try model.prediction(from: provider)
        } catch {
            throw WizardError.modelLoadFailed(name, underlying: error.localizedDescription)
        }
    }
}
