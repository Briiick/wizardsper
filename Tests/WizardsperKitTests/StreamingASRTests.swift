import CoreML
import Foundation
import Testing

@testable import WizardsperKit

/// Where a real tier lives on this machine. The end-to-end tests are skipped
/// rather than failed when it is absent, so a fresh clone still runs the suite
/// without a 615 MB download.
private enum Fixtures {
    static var modelDirectory: URL? {
        let candidates = [
            WizardsperPaths.modelDirectory(for: .ms560),
            URL(fileURLWithPath: "/tmp/nemo_bundle/nemotron_coreml_560ms"),
        ]
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("metadata.json").path)
        }
    }

    static var speech: URL? {
        let url = URL(fileURLWithPath: "/tmp/wizardsper_audio/librispeech/ls_00.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static let speechTranscript =
        "MISTER QUILTER IS THE APOSTLE OF THE MIDDLE CLASSES AND WE ARE GLAD TO WELCOME HIS GOSPEL"

    static var modelsAvailable: Bool { modelDirectory != nil }
    static var audioAvailable: Bool { speech != nil }
}

/// Word error rate over case- and punctuation-insensitive words.
private func wordErrorRate(_ reference: String, _ hypothesis: String) -> Double {
    func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
    let a = words(reference)
    let b = words(hypothesis)
    guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] = min(
                previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return Double(previous[b.count]) / Double(a.count)
}

@Suite("Config")
struct NemotronConfigTests {

    private func writeMetadata(_ json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizardsper-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("metadata.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("derived values follow from the published fields")
    func derivesFromMetadata() throws {
        let file = try writeMetadata(
            #"{"mel_features":128,"chunk_mel_frames":56,"chunk_ms":560,"pre_encode_cache":9,"total_mel_frames":65,"vocab_size":1024,"blank_idx":1024,"encoder_dim":1024,"decoder_hidden":640,"decoder_layers":2}"#
        )
        let config = try NemotronConfig(contentsOf: file)
        #expect(config.chunkSamples == 8960)
        #expect(config.encoderOutputFrames == 7)  // 8x subsampling
        #expect(config.encoderMelShape == [1, 128, 65])
        #expect(config.decoderStateShape == [2, 1, 640])
        #expect(abs(config.chunkDuration - 0.56) < 1e-9)
    }

    /// `total = cache + chunk` is what makes the encoder input line up. If a
    /// bundle ever disagreed, silently trusting it would misalign every frame.
    @Test("an inconsistent frame budget is rejected at load")
    func rejectsInconsistentFrames() throws {
        let file = try writeMetadata(
            #"{"chunk_mel_frames":56,"pre_encode_cache":9,"total_mel_frames":99}"#)
        #expect(throws: WizardsperError.self) { try NemotronConfig(contentsOf: file) }
    }

    @Test("a chunk that does not divide by the 8x subsampling is rejected")
    func rejectsUnalignedChunk() throws {
        let file = try writeMetadata(
            #"{"chunk_mel_frames":50,"pre_encode_cache":9,"total_mel_frames":59}"#)
        #expect(throws: WizardsperError.self) { try NemotronConfig(contentsOf: file) }
    }

    @Test("the shipped 560 ms bundle parses", .enabled(if: Fixtures.modelsAvailable))
    func parsesRealBundle() throws {
        let directory = try #require(Fixtures.modelDirectory)
        let config = try NemotronConfig(
            contentsOf: directory.appendingPathComponent("metadata.json"))
        #expect(config.chunkMilliseconds == 560)
        #expect(config.melFeatures == 128)
        #expect(config.blankIndex == config.vocabSize)
        #expect(config.cacheChannelShape == [1, 24, 70, 1024])
        #expect(config.cacheTimeShape == [1, 24, 1024, 8])
    }
}

@Suite("Streaming recognition", .serialized)
struct StreamingASRTests {

    private func makeRecogniser(_ framing: FramingPolicy = .default) async throws -> StreamingASR {
        let directory = try #require(Fixtures.modelDirectory)
        let bundle = try await ModelBundle.load(from: directory)
        return try StreamingASR(bundle: bundle, framing: framing)
    }

    /// The probe exists to catch a Neural Engine program that came up dead and
    /// returns all zeros without throwing. If warm-up passes, the encoder is
    /// genuinely producing output.
    @Test("warm-up proves the encoder produces non-zero output",
          .enabled(if: Fixtures.modelsAvailable))
    func warmUpSucceeds() async throws {
        let asr = try await makeRecogniser()
        try await asr.warmUp()
        #expect(await asr.processedChunks == 0, "warm-up must leave a clean session behind")
    }

    @Test("silence transcribes to nothing rather than hallucinating",
          .enabled(if: Fixtures.modelsAvailable))
    func silenceProducesNothing() async throws {
        let asr = try await makeRecogniser()
        try await asr.warmUp()
        _ = try await asr.feed([Float](repeating: 0, count: NemotronConfig.sampleRate * 2))
        let text = try await asr.finish()
        #expect(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("real speech transcribes accurately",
          .enabled(if: Fixtures.modelsAvailable && Fixtures.audioAvailable))
    func transcribesSpeech() async throws {
        let asr = try await makeRecogniser()
        try await asr.warmUp()
        let samples = try AudioFileLoader.samples(at: try #require(Fixtures.speech))
        #expect(samples.count > NemotronConfig.sampleRate)

        var index = 0
        while index < samples.count {
            let end = min(index + 4096, samples.count)
            _ = try await asr.feed(Array(samples[index..<end]))
            index = end
        }
        let text = try await asr.finish()
        let wer = wordErrorRate(Fixtures.speechTranscript, text)
        #expect(wer < 0.10, "WER \(wer) for: \(text)")
    }

    /// The encoder caches, LSTM state and mel cache all carry across chunks. If
    /// any of them survives a reset, the second session is conditioned on the
    /// first and drifts.
    @Test("a reset session transcribes identically to a fresh one",
          .enabled(if: Fixtures.modelsAvailable && Fixtures.audioAvailable))
    func resetIsComplete() async throws {
        let asr = try await makeRecogniser()
        try await asr.warmUp()
        let samples = try AudioFileLoader.samples(at: try #require(Fixtures.speech))

        func run() async throws -> String {
            var index = 0
            while index < samples.count {
                let end = min(index + 4096, samples.count)
                _ = try await asr.feed(Array(samples[index..<end]))
                index = end
            }
            return try await asr.finish()
        }

        let first = try await run()
        try await asr.reset()
        let second = try await run()
        #expect(first == second, "reset left state behind")
        #expect(!first.isEmpty)
    }

    /// Buffer sizes from a live tap vary; the chunking bookkeeping must not
    /// depend on them.
    @Test("the transcript does not depend on how audio is chopped up",
          .enabled(if: Fixtures.modelsAvailable && Fixtures.audioAvailable))
    func feedSizeIsIrrelevant() async throws {
        let samples = try AudioFileLoader.samples(at: try #require(Fixtures.speech))

        func transcribe(feed: Int) async throws -> String {
            let asr = try await makeRecogniser()
            try await asr.warmUp()
            var index = 0
            while index < samples.count {
                let end = min(index + feed, samples.count)
                _ = try await asr.feed(Array(samples[index..<end]))
                index = end
            }
            return try await asr.finish()
        }

        let small = try await transcribe(feed: 512)
        let large = try await transcribe(feed: 32768)
        #expect(small == large)
    }

    /// The bug this guards against shipped once: the coordinator reset the ring
    /// buffer between sessions but never the recogniser, so the second dictation
    /// pasted the first one's words in front of its own. The earlier reset test
    /// missed it because it called `reset()` itself — it tested the API, not what
    /// happens without it. `finish()` therefore clears the token stream on its
    /// own, and this holds it to that.
    @Test("a second utterance does not inherit the first, even with no reset",
          .enabled(if: Fixtures.modelsAvailable && Fixtures.audioAvailable))
    func finishDoesNotAccumulate() async throws {
        let asr = try await makeRecogniser()
        try await asr.warmUp()
        let samples = try AudioFileLoader.samples(at: try #require(Fixtures.speech))

        func utterance() async throws -> String {
            var index = 0
            while index < samples.count {
                let end = min(index + 4096, samples.count)
                _ = try await asr.feed(Array(samples[index..<end]))
                index = end
            }
            return try await asr.finish()
        }

        let first = try await utterance()
        #expect(!first.isEmpty)
        // Deliberately no reset() here.
        let second = try await utterance()
        #expect(!second.hasPrefix(first), "the second transcript begins with the first")
        #expect(
            second.count < first.count * 2,
            "second transcript looks like two utterances glued together: \(second)")
    }

    @Test("warm-up leaves no tokens behind for the first real utterance",
          .enabled(if: Fixtures.modelsAvailable))
    func warmUpLeavesNoResidue() async throws {
        let asr = try await makeRecogniser()
        try await asr.warmUp()
        #expect(await asr.partialTranscript.isEmpty)
        #expect(await asr.processedChunks == 0)
    }

    @Test("a framing policy that reads past the mask is refused at init",
          .enabled(if: Fixtures.modelsAvailable))
    func rejectsInvalidFraming() async throws {
        let directory = try #require(Fixtures.modelDirectory)
        let bundle = try await ModelBundle.load(from: directory)
        #expect(throws: WizardsperError.self) {
            _ = try StreamingASR(
                bundle: bundle,
                framing: FramingPolicy(lookback: 0, lookahead: 0, frameOffset: 9))
        }
    }
}
