import CoreML
import Foundation
import WizardKit

// A development harness for the recognition path, deliberately kept separate
// from the app: the streaming algorithm has to be provable against a file with
// a known transcript before it is worth wiring a microphone to it.

struct Arguments {
    var command = "help"
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var rest = Array(raw.dropFirst())
        if let first = rest.first, !first.hasPrefix("-") {
            command = first
            rest.removeFirst()
        }
        var index = 0
        while index < rest.count {
            let token = rest[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if index + 1 < rest.count, !rest[index + 1].hasPrefix("--") {
                    options[key] = rest[index + 1]
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            } else {
                positional.append(token)
                index += 1
            }
        }
    }

    func option(_ key: String) -> String? { options[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func parseFraming(_ raw: String?) -> FramingPolicy {
    guard let raw else { return .default }
    switch raw.lowercased() {
    case "lowlatency", "low-latency", "low": return .lowLatency
    case "fullcontext", "full-context", "full": return .fullContext
    case "windowaligned", "window-aligned", "default": return .windowAligned
    default:
        let parts = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else {
            fail("--framing takes lowLatency, fullContext, or lookback,lookahead,offset")
        }
        return FramingPolicy(lookback: parts[0], lookahead: parts[1], frameOffset: parts[2])
    }
}

func resolveModelDirectory(_ arguments: Arguments) -> URL {
    if let explicit = arguments.option("model") {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
    }
    let tierMilliseconds = Int(arguments.option("tier") ?? "560") ?? 560
    guard let tier = NemotronTier(rawValue: tierMilliseconds) else {
        fail("unknown tier \(tierMilliseconds); expected 160, 560, 1120 or 2240")
    }
    let installed = WizardPaths.modelDirectory(for: tier)
    if FileManager.default.fileExists(atPath: installed.appendingPathComponent("metadata.json").path) {
        return installed
    }
    // Development fallback: the fetch script drops tiers here.
    return URL(fileURLWithPath: "/tmp/nemo_bundle/\(tier.subdirectory)")
}

// MARK: - Word error rate

/// Levenshtein distance over whitespace-separated, case- and
/// punctuation-insensitive words. Matches how the published WER figures for
/// these bundles are computed, so the numbers are comparable.
func wordErrorRate(reference: String, hypothesis: String) -> (wer: Double, edits: Int, words: Int) {
    // The same expansions standard ASR scoring applies before counting edits.
    // LibriSpeech references spell abbreviations out ("MISTER"), while a model
    // trained with punctuation emits "Mr." — scoring those as errors measures the
    // reference's orthography, not the recogniser.
    let expansions = [
        "mr": "mister", "mrs": "missus", "dr": "doctor", "st": "saint",
        "co": "company", "jr": "junior", "maj": "major", "gen": "general",
        "capt": "captain", "lt": "lieutenant", "col": "colonel", "sgt": "sergeant",
        "hon": "honorable", "rev": "reverend", "prof": "professor", "mt": "mount",
    ]
    func normalise(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { expansions[$0] ?? $0 }
    }
    let reference = normalise(reference)
    let hypothesis = normalise(hypothesis)
    guard !reference.isEmpty else { return (hypothesis.isEmpty ? 0 : 1, hypothesis.count, 0) }

    var previous = Array(0...hypothesis.count)
    var current = [Int](repeating: 0, count: hypothesis.count + 1)
    for i in 1...reference.count {
        current[0] = i
        for j in 1...hypothesis.count {
            let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    let edits = previous[hypothesis.count]
    return (Double(edits) / Double(reference.count), edits, reference.count)
}

// MARK: - Commands

func describe(_ description: MLFeatureDescription) -> String {
    guard let constraint = description.multiArrayConstraint else {
        return "\(description.name): \(description.type.rawValue)"
    }
    let shape = constraint.shape.map(\.stringValue).joined(separator: "×")
    var line = "\(description.name): [\(shape)] \(constraint.dataType)"
    switch constraint.shapeConstraint.type {
    case .enumerated:
        let options = constraint.shapeConstraint.enumeratedShapes
            .map { "[" + $0.map(\.stringValue).joined(separator: "×") + "]" }
        line += "  enumerated " + options.joined(separator: " ")
    case .range:
        // Each entry is an NSValue boxing an NSRange of (lower, upper).
        let ranges = constraint.shapeConstraint.sizeRangeForDimension.map { value -> String in
            let range = value.rangeValue
            return "\(range.location)...\(range.length)"
        }
        line += "  FLEXIBLE range " + ranges.joined(separator: " × ")
    case .unspecified:
        break
    @unknown default:
        break
    }
    return line
}

func commandProbe(_ arguments: Arguments) async throws {
    let directory = resolveModelDirectory(arguments)
    print("model directory: \(directory.path)\n")
    let bundle = try await ModelBundle.load(from: directory)
    let config = bundle.config

    print("metadata")
    print("  chunk            \(config.chunkMilliseconds) ms = \(config.chunkSamples) samples = \(config.chunkMelFrames) mel frames")
    print("  pre-encode cache \(config.preEncodeCache) frames -> encoder mel \(config.encoderMelShape)")
    print("  encoder output   \(config.encoderOutputFrames) frames of \(config.encoderDim)")
    print("  vocabulary       \(config.vocabSize) (+ blank at \(config.blankIndex))")
    print("  decoder          \(config.decoderLayers) × \(config.decoderHidden) LSTM")
    print("")

    for (name, model) in [
        ("preprocessor", bundle.preprocessor), ("encoder", bundle.encoder),
        ("decoder", bundle.decoder), ("joint", bundle.joint),
    ] {
        print("\(name)")
        for (_, value) in model.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            print("  in   " + describe(value))
        }
        for (_, value) in model.modelDescription.outputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            print("  out  " + describe(value))
        }
        print("")
    }

    for policy in [FramingPolicy.lowLatency, .fullContext] {
        let window = policy.windowSamples(chunkSamples: config.chunkSamples)
        let counts = policy.frameCounts(chunkSamples: config.chunkSamples)
        let ok = policy.selectionIsValid(
            chunkSamples: config.chunkSamples, chunkMelFrames: config.chunkMelFrames)
        print(
            "framing lookback=\(policy.lookback) lookahead=\(policy.lookahead) "
                + "offset=\(policy.frameOffset) -> window \(window) samples, "
                + "\(counts.emitted) frames (\(counts.valid) valid), "
                + "selects \(policy.frameOffset)..<\(policy.frameOffset + config.chunkMelFrames)"
                + (ok ? "" : "  ** INVALID **"))
    }
}

@discardableResult
func transcribe(
    directory: URL, audio: URL, framing: FramingPolicy, realtime: Bool, verbose: Bool
) async throws -> (text: String, seconds: Double, audioSeconds: Double) {
    let bundle = try await ModelBundle.load(from: directory)
    let asr = try StreamingASR(bundle: bundle, framing: framing)
    try await asr.warmUp()

    let samples = try AudioFileLoader.samples(at: audio)
    guard !samples.isEmpty else { throw WizardError.noAudioCaptured }
    let audioSeconds = Double(samples.count) / Double(NemotronConfig.sampleRate)

    // Feed in the size the live capture path delivers, not one big buffer, so
    // the harness exercises the same partial-chunk bookkeeping the app will.
    let feedSize = 4096
    let started = Date()
    var index = 0
    while index < samples.count {
        let end = min(index + feedSize, samples.count)
        let slice = Array(samples[index..<end])
        if let partial = try await asr.feed(slice), verbose {
            print("  … \(partial)")
        }
        index = end
        if realtime {
            try await Task.sleep(for: .seconds(Double(slice.count) / 16000.0))
        }
    }
    let text = try await asr.finish()
    let elapsed = Date().timeIntervalSince(started)
    return (text, elapsed, audioSeconds)
}

func commandTranscribe(_ arguments: Arguments) async throws {
    guard let path = arguments.positional.first else { fail("usage: wizard-cli transcribe <audio>") }
    let audio = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let directory = resolveModelDirectory(arguments)
    let framing = parseFraming(arguments.option("framing"))

    let result = try await transcribe(
        directory: directory, audio: audio, framing: framing,
        realtime: arguments.has("realtime"), verbose: arguments.has("verbose"))

    print("\n\(result.text)\n")
    let rtfx = result.audioSeconds / max(result.seconds, 0.0001)
    print(
        String(
            format: "%.2f s audio in %.2f s  (%.1f× realtime)", result.audioSeconds, result.seconds,
            rtfx))
    if let reference = arguments.option("reference") {
        let scored = wordErrorRate(reference: reference, hypothesis: result.text)
        print(String(format: "WER %.2f%%  (%d edits over %d words)", scored.wer * 100, scored.edits, scored.words))
    }
}

/// Transcribe the same audio under several framing policies and score each.
/// This is how the shipped default was chosen rather than argued about.
func commandSweep(_ arguments: Arguments) async throws {
    guard let path = arguments.positional.first else {
        fail("usage: wizard-cli sweep <audio> --reference \"...\"")
    }
    let audio = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let directory = resolveModelDirectory(arguments)
    let reference = arguments.option("reference")

    var policies: [(String, FramingPolicy)] = [
        ("lowLatency  240/0/1", .lowLatency),
        ("fullContext 256/256/2", .fullContext),
        ("windowAligned 400/0/2", .windowAligned),
        ("offset-0     256/256/1", FramingPolicy(lookback: 256, lookahead: 256, frameOffset: 1)),
        ("wide        512/512/3", FramingPolicy(lookback: 512, lookahead: 512, frameOffset: 3)),
        ("none          0/0/0", FramingPolicy(lookback: 0, lookahead: 0, frameOffset: 0)),
    ]
    if let extra = arguments.option("also") {
        policies.append(("custom", parseFraming(extra)))
    }

    for (name, policy) in policies {
        do {
            let result = try await transcribe(
                directory: directory, audio: audio, framing: policy, realtime: false,
                verbose: false)
            var line = "\(name.padding(toLength: 24, withPad: " ", startingAt: 0))"
            if let reference {
                let scored = wordErrorRate(reference: reference, hypothesis: result.text)
                line += String(format: "WER %6.2f%%  ", scored.wer * 100)
            }
            line += String(format: "%.1f× rt", result.audioSeconds / max(result.seconds, 0.0001))
            print(line)
            print("    \(result.text)")
        } catch {
            print("\(name.padding(toLength: 24, withPad: " ", startingAt: 0))failed: \(error.localizedDescription)")
        }
    }
}

func commandHelp() {
    print(
        """
        wizard-cli — development harness for the Wizard recognition path

        USAGE
          wizard-cli probe        [--model DIR | --tier 560]
              Print each model's real input/output signatures and the framing arithmetic.

          wizard-cli transcribe <audio> [--model DIR | --tier 560] [--framing NAME]
                                        [--reference "ground truth"] [--realtime] [--verbose]
              Transcribe a file through the streaming path.

          wizard-cli sweep <audio> --reference "ground truth" [--model DIR | --tier 560]
              Transcribe under every framing policy and score them side by side.

        --framing accepts: lowLatency, fullContext, or lookback,lookahead,offset
        """)
}

let arguments = Arguments(CommandLine.arguments)
do {
    switch arguments.command {
    case "probe": try await commandProbe(arguments)
    case "transcribe": try await commandTranscribe(arguments)
    case "sweep": try await commandSweep(arguments)
    case "help", "--help", "-h": commandHelp()
    default: fail("unknown command “\(arguments.command)”. Try: wizard-cli help")
    }
} catch let error as WizardError {
    fail(error.errorDescription ?? "\(error)")
} catch {
    fail(error.localizedDescription)
}
