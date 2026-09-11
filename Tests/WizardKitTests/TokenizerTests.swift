import Foundation
import Testing

@testable import WizardKit

private func writeTemp(_ contents: String, _ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wizard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent(name)
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
}

@Suite("Tokenizer")
struct TokenizerTests {

    /// `\u{2581}` is SentencePiece's word-boundary marker, not a character in the
    /// text — decoding has to turn it into a space or every word runs together.
    @Test("word-boundary markers become spaces and the edges are trimmed")
    func decodesSentencePiece() throws {
        let file = try writeTemp(
            #"{"0":"<unk>","1":"▁hello","2":"▁world","3":"s"}"#, "tokenizer.json")
        let tokenizer = try NemotronTokenizer(contentsOf: file)
        #expect(tokenizer.decode([1, 2, 3]) == "hello worlds")
        #expect(tokenizer.decode([]) == "")
    }

    @Test("pieces keep the raw marker so timings can be grouped into words")
    func exposesRawPieces() throws {
        let file = try writeTemp(#"{"0":"a","1":"▁b"}"#, "tokenizer.json")
        let tokenizer = try NemotronTokenizer(contentsOf: file)
        #expect(tokenizer.piece(1) == "\u{2581}b")
        #expect(tokenizer.piece(0) == "a")
    }

    /// The blank index is `vocabSize`, one past the last real piece, and the
    /// greedy loop must never turn it into text.
    @Test("ids outside the vocabulary decode to nothing instead of trapping")
    func ignoresOutOfRange() throws {
        let file = try writeTemp(#"{"0":"a","1":"b"}"#, "tokenizer.json")
        let tokenizer = try NemotronTokenizer(contentsOf: file)
        #expect(tokenizer.decode([0, 9_999, 1, -1]) == "ab")
        #expect(tokenizer.piece(1024) == "")
    }

    @Test("a sparse vocabulary still indexes by id, not by position")
    func handlesSparseIds() throws {
        let file = try writeTemp(#"{"5":"▁five","0":"zero"}"#, "tokenizer.json")
        let tokenizer = try NemotronTokenizer(contentsOf: file)
        #expect(tokenizer.count == 6)
        #expect(tokenizer.decode([0, 5]) == "zero five")
    }

    @Test("malformed vocabularies are rejected, not half-loaded")
    func rejectsMalformed() throws {
        let notAnObject = try writeTemp("[1,2,3]", "tokenizer.json")
        #expect(throws: WizardError.self) { try NemotronTokenizer(contentsOf: notAnObject) }

        let badKey = try writeTemp(#"{"abc":"x"}"#, "tokenizer.json")
        #expect(throws: WizardError.self) { try NemotronTokenizer(contentsOf: badKey) }

        let empty = try writeTemp("{}", "tokenizer.json")
        #expect(throws: WizardError.self) { try NemotronTokenizer(contentsOf: empty) }
    }
}

@Suite("Framing")
struct FramingPolicyTests {

    /// Every tier must present the preprocessor with one constant input length —
    /// a second length makes CoreML rebuild the execution plan mid-stream.
    @Test("window length is constant per tier", arguments: [16, 56, 112, 224])
    func windowIsConstant(chunkMelFrames: Int) {
        let chunkSamples = chunkMelFrames * NemotronConfig.hopLength
        for policy in [FramingPolicy.lowLatency, .fullContext, .windowAligned] {
            let window = policy.windowSamples(chunkSamples: chunkSamples)
            #expect(window == policy.lookback + chunkSamples + policy.lookahead)
        }
    }

    /// The preprocessor emits `floor(L/160) + 1` frames and masks the last one.
    /// Selecting into the masked frame would feed the encoder a zero column.
    @Test("every shipped policy selects only unmasked frames", arguments: [16, 56, 112, 224])
    func selectionStaysInsideValidFrames(chunkMelFrames: Int) {
        let chunkSamples = chunkMelFrames * NemotronConfig.hopLength
        for policy in [FramingPolicy.lowLatency, .fullContext, .windowAligned] {
            let counts = policy.frameCounts(chunkSamples: chunkSamples)
            #expect(counts.emitted == counts.valid + 1)
            #expect(
                policy.selectionIsValid(
                    chunkSamples: chunkSamples, chunkMelFrames: chunkMelFrames),
                "\(policy) is invalid for a \(chunkMelFrames)-frame chunk")
            #expect(policy.frameOffset + chunkMelFrames <= counts.valid)
        }
    }

    @Test("the spec's 160 ms shape really is 2800 samples")
    func matchesTheSpecifiedShape() {
        // 2560 samples of new audio plus 240 of carry, the shape the 160 ms tier
        // was specified around.
        #expect(FramingPolicy.lowLatency.windowSamples(chunkSamples: 2560) == 2800)
    }

    @Test("a policy that would read past the mask is reported invalid")
    func rejectsOverrun() {
        let policy = FramingPolicy(lookback: 0, lookahead: 0, frameOffset: 4)
        #expect(!policy.selectionIsValid(chunkSamples: 8960, chunkMelFrames: 56))
    }

    /// Measurement does not separate the policies (4.96%–5.30% over 73
    /// utterances, a four-edit spread), so the default is pinned on the property
    /// that does distinguish them: no selected frame may touch the
    /// preprocessor's own zero padding. That needs n_fft/2 of real audio on each
    /// side, and a frame offset that skips past it.
    @Test("the default never lets a selected frame see the preprocessor's padding")
    func defaultSeesOnlyRealAudio() {
        let policy = FramingPolicy.default
        #expect(policy == FramingPolicy.fullContext)
        let halfWindow = NemotronConfig.fftLength / 2
        #expect(policy.lookback >= halfWindow)
        #expect(policy.lookahead >= halfWindow)
        // The first selected frame is centred `frameOffset * hop` into the
        // window; it must sit at least half an FFT past the window's start.
        #expect(policy.frameOffset * NemotronConfig.hopLength >= halfWindow)
    }
}

@Suite("Chord")
struct ChordTests {

    /// Matching must be "every bound modifier is down", not equality: an exact
    /// match breaks the moment Caps Lock is on or a keypad event sets its bit.
    @Test("extra modifiers do not break the chord")
    func matchesAsSubset() {
        let fn = Chord.fn
        #expect(fn.isHeld(in: .maskSecondaryFn))
        #expect(fn.isHeld(in: [.maskSecondaryFn, .maskAlphaShift, .maskNumericPad]))
        #expect(!fn.isHeld(in: .maskCommand))
        #expect(!fn.isHeld(in: []))
    }

    @Test("a multi-key chord needs all of its keys")
    func requiresEveryModifier() {
        let chord = Chord([.control, .option])
        #expect(chord.isHeld(in: [.maskControl, .maskAlternate]))
        #expect(!chord.isHeld(in: .maskControl))
    }

    /// An empty chord would match "no modifiers down", i.e. fire constantly.
    @Test("an empty chord never matches")
    func emptyNeverMatches() {
        #expect(!Chord([]).isHeld(in: []))
        #expect(!Chord([]).isHeld(in: .maskCommand))
    }

    @Test("chords round-trip through Codable so settings survive a relaunch")
    func codableRoundTrip() throws {
        let chord = Chord([.fn, .control])
        let data = try JSONEncoder().encode(chord)
        #expect(try JSONDecoder().decode(Chord.self, from: data) == chord)
    }
}
