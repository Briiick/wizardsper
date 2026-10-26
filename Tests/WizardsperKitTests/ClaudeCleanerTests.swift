import Foundation
import Testing

@testable import WizardsperKit

/// The Claude engine, exercised against a stubbed network. What is tested is
/// the contract on both sides of the wire — the request the API expects, and
/// every way a response can be unusable — because those fail only at runtime,
/// in the middle of someone's dictation.
@Suite("Claude cleaner", .serialized)
struct ClaudeCleanerTests {

    // MARK: - Request

    @Test("the body asks Haiku 5.5 for a fast, thinking-free copy edit")
    func requestBody() throws {
        let body = ClaudeCleaner.body(for: "so um I was thinking we could ship it on friday")
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect(body["system"] as? String == TranscriptCleaner.instructions)
        // Haiku 5.5 rejects non-default sampling parameters with a 400.
        #expect(body["temperature"] == nil)

        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] == "user")
        #expect(messages[0]["content"]?.contains("<<<TRANSCRIPT\nso um I was thinking") == true)
        #expect(try JSONSerialization.data(withJSONObject: body).isEmpty == false)
    }

    @Test("the request carries the key and API version headers")
    func requestHeaders() throws {
        let request = try ClaudeCleaner(apiKey: "sk-test").request(for: "hello there")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    // MARK: - Response

    @Test("text blocks are joined and echoed markers stripped")
    func parsesText() throws {
        let data = Self.message("<<<TRANSCRIPT\nWe could ship it on Friday.\nTRANSCRIPT>>>")
        #expect(try ClaudeCleaner.parse(status: 200, data: data) == "We could ship it on Friday.")
    }

    @Test("a refusal is not read as a rewrite")
    func refusal() {
        #expect(throws: ClaudeCleaner.Failure.refused) {
            try ClaudeCleaner.parse(status: 200, data: Self.message("I can't help", stop: "refusal"))
        }
    }

    @Test("a rewrite cut off at max_tokens is not used")
    func truncated() {
        #expect(throws: ClaudeCleaner.Failure.truncated) {
            try ClaudeCleaner.parse(status: 200, data: Self.message("We could", stop: "max_tokens"))
        }
    }

    @Test("an HTTP error keeps the API's message")
    func httpError() {
        let data = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        #expect(throws: ClaudeCleaner.Failure.http(status: 401, message: "invalid x-api-key")) {
            try ClaudeCleaner.parse(status: 401, data: data)
        }
    }

    // MARK: - End to end, stubbed

    @Test("a good rewrite replaces the transcript")
    func acceptsCleanup() async {
        let raw = "so um I was thinking that we could maybe like ship it on friday"
        let outcome = await Self.clean(raw) { _ in (200, Self.message("I was thinking that we could ship it on Friday.")) }
        #expect(outcome.changed)
        #expect(outcome.text == "I was thinking that we could ship it on Friday.")
    }

    @Test("an answer instead of an edit is discarded by the guard")
    func rejectsAnswer() async {
        let raw = "um so what time is the meeting tomorrow"
        let outcome = await Self.clean(raw) { _ in (200, Self.message("The meeting is at three tomorrow.")) }
        #expect(!outcome.changed)
        #expect(outcome.text == raw)
        #expect(outcome.rejected == "The meeting is at three tomorrow.")
    }

    @Test("a rejected key leaves the transcript and says why")
    func badKey() async {
        let raw = "this is a perfectly ordinary sentence to clean"
        let outcome = await Self.clean(raw) { _ in
            (401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        #expect(outcome.text == raw)
        #expect(outcome.note == "Anthropic rejected the API key")
    }

    @Test("a slow response loses to the deadline")
    func deadline() async {
        let raw = "this is a perfectly ordinary sentence to clean"
        let outcome = await Self.clean(raw, deadline: .milliseconds(100)) { _ in
            Thread.sleep(forTimeInterval: 1)
            return (200, Self.message("This is a perfectly ordinary sentence to clean."))
        }
        #expect(outcome.text == raw)
        #expect(outcome.note == "Took too long, so nothing was changed")
    }

    @Test("a transcript too short to rewrite never costs a request")
    func shortTranscript() async {
        StubProtocol.requests = 0
        let outcome = await Self.clean("um okay") { _ in (200, Self.message("Okay.")) }
        #expect(outcome.text == "um okay")
        #expect(StubProtocol.requests == 0)
    }

    // MARK: - Helpers

    static func message(_ text: String, stop: String = "end_turn") -> Data {
        let json: [String: Any] = [
            "id": "msg_test", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": stop,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func clean(
        _ raw: String, deadline: Duration = .seconds(5),
        respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) async -> ClaudeCleaner.Outcome {
        StubProtocol.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        return await ClaudeCleaner(apiKey: "sk-test", session: session).clean(raw, deadline: deadline)
    }
}

/// Answers every request from `handler` instead of the network. The suite is
/// serialized, which is what makes the shared statics safe.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
