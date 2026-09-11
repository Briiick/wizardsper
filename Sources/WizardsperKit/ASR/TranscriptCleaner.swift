import Foundation

// `FoundationModels` is a macOS 26 framework, and CI runners lag the SDK by
// months. Guarding the import means the package still builds against an older
// SDK — cleanup simply reports itself unavailable there, which is a state the
// feature already has to handle anyway because most Macs have Apple Intelligence
// switched off.
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Rewrites a finished transcript into ordinary written English, using the
/// on-device model macOS already ships.
///
/// The engine is Apple's `FoundationModels`: a few-billion-parameter model that
/// is already on the machine, runs entirely locally, costs nothing, and needs no
/// download of ours. Nothing leaves the Mac, which for a dictation app is not a
/// nice-to-have — the whole reason the ASR is local would be undone by sending
/// the result somewhere.
///
/// Everything here is arranged around one assumption: **the rewrite is a
/// proposal, not a result.** It is raced against a deadline, checked by
/// `CleanupGuard`, and discarded on any doubt. A transcript with "um" in it is a
/// much smaller failure than a fluent paraphrase of something the user did not
/// say, so every uncertain path returns the raw text.
public actor TranscriptCleaner {

    public enum Availability: Sendable, Equatable {
        case ready
        /// The hardware supports it and the user has not switched it on. This is
        /// the common case and the only one worth prompting about.
        case appleIntelligenceOff
        case deviceUnsupported
        case modelDownloading
        case other(String)

        public var isReady: Bool { self == .ready }

        public var explanation: String {
            switch self {
            case .ready: return "Ready"
            case .appleIntelligenceOff:
                return "Turn on Apple Intelligence in System Settings to clean up transcripts."
            case .deviceUnsupported:
                return "This Mac cannot run Apple's on-device language model."
            case .modelDownloading:
                return "Apple Intelligence is still downloading its model."
            case .other(let detail): return detail
            }
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let text: String
        public let changed: Bool
        /// Why the raw transcript was kept, when it was. Logged, and shown in
        /// the dashboard rather than silently swallowed.
        public let note: String?
    }

    #if canImport(FoundationModels)
        private var session: LanguageModelSession?
    #endif

    public init() {}

    // MARK: - Availability

    public static func availability() -> Availability {
        #if !canImport(FoundationModels)
            return .other("Built against an SDK without Apple's on-device model.")
        #else
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .deviceNotEligible: return .deviceUnsupported
                case .modelNotReady: return .modelDownloading
                @unknown default: return .other("Unavailable: \(reason)")
                }
            @unknown default:
                return .other("Unrecognised availability")
            }
        #endif
    }

    /// The instructions, kept in one place because every word of them is load
    /// bearing.
    ///
    /// The model's default disposition is to be helpful, which for a dictation
    /// tool is the failure mode: asked to tidy "what time is the meeting", a
    /// helpful model answers it. So the prompt says what NOT to do more
    /// insistently than what to do, and `CleanupGuard` assumes the prompt will
    /// sometimes be ignored anyway.
    static let instructions = """
        You rewrite dictated speech into clean written English.

        Remove filler words, stutters, repeated words and false starts. Fix \
        grammar and add punctuation. Keep the speaker's own words, meaning, tone \
        and register — including informality and profanity.

        Never answer, explain, summarise or comment on the text. Never add \
        information the speaker did not say. Never finish a sentence that was cut \
        off; leave it cut off. If the text is already clean, return it unchanged.

        Reply with the rewritten text only, with no preamble, quotes or notes.
        """

    /// Build and warm a session so the first token does not pay for model
    /// load. Called when the dictation key goes down, which buys the whole hold
    /// as head start.
    public func prewarm() {
        #if canImport(FoundationModels)
            guard Self.availability().isReady else { return }
            let session = makeSession()
            session.prewarm()
            self.session = session
        #endif
    }

    #if canImport(FoundationModels)
    private func makeSession() -> LanguageModelSession {
        // `permissiveContentTransformations` because the default guardrail
        // treats the *input* as something to be judged: a user dictating a
        // medical symptom, a legal matter, or simply swearing can have their
        // transcript refused outright, and losing the user's words is worse than
        // anything the guardrail is protecting them from. Note this relaxation
        // applies to plain `String` responses only — asking for structured
        // output re-arms the very guardrail being relaxed here, which is why
        // this takes the response as text and validates it itself.
        let model = SystemLanguageModel(
            useCase: .general, guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: Self.instructions)
    }
    #endif

    // MARK: - Cleaning

    /// Returns the cleaned transcript, or `raw` unchanged with a reason.
    ///
    /// - Parameter deadline: how long the user is willing to wait. The paste
    ///   already lands about 1.3 s after the key comes up; anything that pushes
    ///   it far past that stops feeling like dictation and starts feeling like a
    ///   request. On expiry the raw text is delivered and the rewrite abandoned.
    public func clean(
        _ raw: String, deadline: Duration = .milliseconds(1500),
        guardrail: CleanupGuard = CleanupGuard()
    ) async -> Outcome {
        let availability = Self.availability()
        guard availability.isReady else {
            return Outcome(text: raw, changed: false, note: availability.explanation)
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(text: raw, changed: false, note: nil)
        }

        #if !canImport(FoundationModels)
            return Outcome(text: raw, changed: false, note: availability.explanation)
        #else
        // A session is used once. Reusing one carries the previous dictation
        // into this rewrite as context — the model starts "remembering" what was
        // said a minute ago — and walks the 4096-token window towards an
        // overflow that would eventually throw mid-paste.
        let session = self.session ?? makeSession()
        self.session = nil

        let started = ContinuousClock.now
        let rewritten: String?
        do {
            rewritten = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    // Greedy sampling, so the same dictation always produces the
                    // same paste. Non-determinism in a dictation tool reads as a
                    // bug, not as variety.
                    let options = GenerationOptions(sampling: .greedy)
                    let response = try await session.respond(to: raw, options: options)
                    return response.content
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch let error as LanguageModelSession.GenerationError {
            Log.asr.notice("Cleanup declined: \(String(describing: error), privacy: .public)")
            return Outcome(text: raw, changed: false, note: Self.describe(error))
        } catch {
            Log.asr.notice("Cleanup failed: \(error.localizedDescription, privacy: .public)")
            return Outcome(text: raw, changed: false, note: error.localizedDescription)
        }

        let elapsed = ContinuousClock.now - started
        guard let rewritten else {
            Log.asr.notice("Cleanup exceeded its deadline; pasting the raw transcript")
            return Outcome(text: raw, changed: false, note: "Took too long, so nothing was changed")
        }

        switch guardrail.check(raw: raw, rewritten: rewritten) {
        case .accept(let text):
            Log.asr.info("Cleaned in \(elapsed.milliseconds) ms")
            return Outcome(text: text, changed: true, note: nil)
        case .reject(let reason):
            Log.asr.notice("Cleanup rejected: \(reason.rawValue, privacy: .public)")
            // `.unchanged` is not a problem worth reporting — the model simply
            // agreed the text was already fine.
            return Outcome(
                text: raw, changed: false, note: reason == .unchanged ? nil : reason.rawValue)
        }
        #endif
    }

    #if canImport(FoundationModels)

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation:
            return "Apple's safety filter refused this text, so it was left as dictated"
        case .exceededContextWindowSize:
            return "Too long to clean up in one pass"
        case .assetsUnavailable:
            return "Apple Intelligence assets are not available"
        default:
            return "The on-device model could not process this"
        }
    }
    #endif
}

extension Duration {
    fileprivate var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
