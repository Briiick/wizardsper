import Foundation

/// Rewrites a finished transcript with Claude Haiku 5.5 over the Anthropic API,
/// billed to the user's own API key.
///
/// The alternative to `TranscriptCleaner` for Macs without Apple Intelligence,
/// or for users who want a stronger editor than the on-device model and accept
/// the trade: **the transcript leaves the Mac.** That is the opposite of every
/// other stage in Wizardsper, so it is a separate, explicit engine choice rather
/// than a fallback that quietly kicks in.
///
/// Everything else is deliberately identical to the on-device path — the same
/// instructions, the same fenced prompt, the same `CleanupGuard`, the same
/// deadline — so switching engines changes who does the rewrite and nothing
/// about what a rewrite is allowed to be. On any doubt the raw transcript wins.
public struct ClaudeCleaner: Sendable {

    public typealias Outcome = TranscriptCleaner.Outcome

    /// The current Haiku. Small, fast and cheap — a dictation's worth of text
    /// costs a small fraction of a cent — which is the only kind of model that
    /// fits inside a paste deadline.
    public static let model = "claude-haiku-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Request

    /// Request body. Exposed to tests because its shape is the contract with the
    /// API, and a field that is wrong here fails only at runtime.
    ///
    /// - Thinking off and effort low: this is a copy edit, not a problem to
    ///   reason about, and every token of thinking is latency the paste waits
    ///   through. Haiku 5.5 accepts `disabled` at any effort up to `high`.
    /// - No `temperature`: Haiku 5.5 rejects non-default sampling parameters,
    ///   so the determinism the on-device path gets from greedy sampling is not
    ///   available here. The guard is what keeps a varied rewrite honest.
    /// - `max_tokens` scales with the input, because a rewrite only ever
    ///   shrinks: a ceiling well above the transcript's own size can only be hit
    ///   by a model that has stopped editing and started writing.
    static func body(for transcript: String) -> [String: Any] {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        return [
            "model": model,
            "max_tokens": max(256, words * 4),
            "system": TranscriptCleaner.instructions,
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
            "messages": [
                ["role": "user", "content": TranscriptCleaner.prompt(for: transcript)]
            ],
        ]
    }

    func request(for transcript: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: transcript))
        return request
    }

    // MARK: - Response

    enum Failure: Error, Equatable {
        case http(status: Int, message: String?)
        case refused
        case truncated
        case malformed
    }

    /// The text of a Messages API response, or why there is none worth using.
    ///
    /// `stop_reason` is checked before the content is read. A refusal arrives as
    /// HTTP 200, and a `max_tokens` stop is a rewrite that was cut off mid-word;
    /// both carry text that looks usable and is not.
    static func parse(status: Int, data: Data) throws(Failure) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            throw .http(status: status, message: error?["message"] as? String)
        }
        guard let json else { throw .malformed }
        switch json["stop_reason"] as? String {
        case "refusal": throw .refused
        case "max_tokens": throw .truncated
        default: break
        }
        guard let content = json["content"] as? [[String: Any]] else { throw .malformed }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return unfence(text)
    }

    /// Strip the transcript markers if the model echoed them back. Told not to,
    /// and mostly does not — but a stray `TRANSCRIPT>>>` pasted into someone's
    /// email is a worse failure than the cost of checking.
    static func unfence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "<<<TRANSCRIPT" { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "TRANSCRIPT>>>" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ failure: Failure) -> String {
        switch failure {
        case .http(401, _), .http(403, _):
            return "Anthropic rejected the API key"
        case .http(429, _):
            return "Anthropic rate limit reached"
        case .http(529, _):
            return "Anthropic's API is overloaded"
        case .http(let status, let message):
            return "Anthropic API error \(status)" + (message.map { ": \($0)" } ?? "")
        case .refused:
            return "Claude declined to edit this text"
        case .truncated:
            return "Claude's rewrite was cut off"
        case .malformed:
            return "Anthropic sent a response that could not be read"
        }
    }

    // MARK: - Cleaning

    /// Returns the cleaned transcript, or `raw` unchanged with a reason. Same
    /// contract as `TranscriptCleaner.clean`.
    public func clean(
        _ raw: String, deadline: Duration = .milliseconds(1500),
        guardrail: CleanupGuard = CleanupGuard()
    ) async -> Outcome {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(text: raw, changed: false, note: nil)
        }
        // Not worth a network round trip — and not worth the user's money — for
        // a transcript the guard would refuse to replace whatever came back.
        guard CleanupGuard.words(raw).count >= guardrail.minimumWords else {
            return Outcome(text: raw, changed: false, note: nil)
        }

        let request: URLRequest
        do {
            request = try self.request(for: raw)
        } catch {
            return Outcome(text: raw, changed: false, note: "Could not build the request")
        }

        let started = ContinuousClock.now
        let rewritten: String?
        do {
            let session = self.session
            rewritten = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return try Self.parse(status: status, data: data)
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch let failure as Failure {
            Log.asr.notice("Claude cleanup failed: \(String(describing: failure), privacy: .public)")
            return Outcome(text: raw, changed: false, note: Self.describe(failure))
        } catch {
            Log.asr.notice("Claude cleanup failed: \(error.localizedDescription, privacy: .public)")
            return Outcome(text: raw, changed: false, note: "Could not reach Anthropic: \(error.localizedDescription)")
        }

        let elapsed = ContinuousClock.now - started
        guard let rewritten else {
            Log.asr.notice("Claude cleanup exceeded its deadline; pasting the raw transcript")
            return Outcome(text: raw, changed: false, note: "Took too long, so nothing was changed")
        }

        switch guardrail.check(raw: raw, rewritten: rewritten) {
        case .accept(let text):
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            Log.asr.info("Cleaned by Claude in \(ms) ms")
            return Outcome(text: text, changed: true, note: nil)
        case .reject(let reason):
            Log.asr.notice("Claude cleanup rejected: \(reason.rawValue, privacy: .public)")
            return Outcome(
                text: raw, changed: false, note: reason == .unchanged ? nil : reason.rawValue,
                rejected: reason == .unchanged ? nil : rewritten)
        }
    }
}
