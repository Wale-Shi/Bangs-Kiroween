import XCTest
@testable import Bangs

/// Plays a recorded reply to whatever Bangs asks a model, and keeps the request to look at.
final class StubAPI: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var sent: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.request = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            stream.close()
            Self.sent = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class TranslateEngineTests: XCTestCase {
    override class func setUp() { TestData.isolate }

    override func setUp() {
        ModelAPI.sessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubAPI.self]
            return configuration
        }
        StubAPI.status = 200
    }

    override func tearDown() { ModelAPI.sessionConfiguration = { .ephemeral } }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await piece in stream { text += piece }
        return text
    }

    func testEndpoints() {
        XCTAssertEqual(ModelAPI.endpoint("https://api.deepseek.com", format: .openAI)?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(ModelAPI.endpoint("https://api.openai.com/v1/", format: .openAI)?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(ModelAPI.endpoint("http://localhost:11434/v1/chat/completions", format: .openAI)?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(ModelAPI.endpoint("https://api.anthropic.com", format: .anthropic)?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(ModelAPI.endpoint("https://proxy.example/v1", format: .anthropic)?.absoluteString, "https://proxy.example/v1/messages")
        XCTAssertNil(ModelAPI.endpoint("api.openai.com", format: .openAI), "a scheme is needed")
        XCTAssertEqual(TranslatePrompt.language("zh-Hans"), "Simplified Chinese")
        XCTAssertEqual(TranslatePrompt.language("ja"), "Japanese")
    }

    /// An OpenAI-style stream comes back a piece at a time; the request carries the key, the model and the instructions.
    func testOpenAIStream() async throws {
        StubAPI.body = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"这一轮"}}]}

        data: {"choices":[{"delta":{"content":"改了 3 个文件。"}}]}

        data: [DONE]

        """
        let text = try await collect(ModelAPI.stream(text: "This turn changed 3 files.", to: "zh-Hans", format: .openAI,
                                                     base: "https://api.deepseek.com", model: "deepseek-chat", key: "sk-test"))
        XCTAssertEqual(text, "这一轮改了 3 个文件。")
        XCTAssertEqual(StubAPI.request?.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(StubAPI.request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(StubAPI.sent["model"] as? String, "deepseek-chat")
        XCTAssertEqual(StubAPI.sent["stream"] as? Bool, true)
        let messages = try XCTUnwrap(StubAPI.sent["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("Simplified Chinese") == true)
        XCTAssertEqual(messages[1]["content"], "This turn changed 3 files.")
    }

    /// Anthropic's events: text deltas count, the rest does not; low effort and the fallback go only where they apply.
    func testAnthropicStream() async throws {
        StubAPI.body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"All tests "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"passed."}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let text = try await collect(ModelAPI.stream(text: "测试都通过了。", to: "en", format: .anthropic,
                                                     base: "https://api.anthropic.com", model: "claude-opus-5-5", key: "sk-ant-test"))
        XCTAssertEqual(text, "All tests passed.")
        XCTAssertEqual(StubAPI.request?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(StubAPI.request?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(StubAPI.request?.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(StubAPI.request?.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(StubAPI.sent["fallbacks"] as? String, "default")
        XCTAssertEqual((StubAPI.sent["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(StubAPI.sent["temperature"])
        XCTAssertTrue((StubAPI.sent["system"] as? String)?.contains("English") == true)

        // Through a proxy, or with an older model, neither is sent.
        _ = try await collect(ModelAPI.stream(text: "你好", to: "en", format: .anthropic, base: "https://proxy.example", model: "claude-haiku-4-5", key: "k"))
        XCTAssertNil(StubAPI.request?.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertNil(StubAPI.sent["fallbacks"])
        XCTAssertNil(StubAPI.sent["output_config"])
    }

    /// A refusal or an error the provider explains shows in its own words.
    func testFailuresAreExplained() async {
        StubAPI.status = 401
        StubAPI.body = #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#
        do {
            _ = try await collect(ModelAPI.stream(text: "hi", to: "zh-Hans", format: .openAI, base: "https://api.openai.com/v1", model: "m", key: "bad"))
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "API Key 不对或没有权限：Incorrect API key provided")
        }
        StubAPI.status = 200
        StubAPI.body = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Part"}}

        data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}

        """
        do {
            _ = try await collect(ModelAPI.stream(text: "hi", to: "en", format: .anthropic, base: "https://api.anthropic.com", model: "claude-opus-5-5", key: "k"))
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "模型拒绝翻译这段文字。")
        }
        do {
            _ = try await collect(ModelAPI.stream(text: "hi", to: "en", format: .openAI, base: "https://api.openai.com/v1", model: " ", key: "k"))
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "还没有填模型名称。")
        }
    }

    /// An agent over ACP: started once, a session per translation, the reply streamed, any tool it asks for turned down.
    func testAgentOverACP() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-acp-\(UUID().uuidString).py")
        try """
        import json, sys
        def send(o):
            sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        sessions = 0
        prompt = None
        for line in sys.stdin:
            m = json.loads(line)
            method = m.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
            elif method == "session/new":
                sessions += 1
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s%d" % sessions}})
            elif method == "session/prompt":
                prompt = m
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": m["params"]["sessionId"], "options": []}})
            elif m.get("id") == 900:
                sid = prompt["params"]["sessionId"]
                text = prompt["params"]["prompt"][0]["text"]
                outcome = m["result"]["outcome"]["outcome"]
                pieces = ["你好，", "世界。", "[%s %s %s]" % (sid, outcome, "<text>" in text and "Simplified Chinese" in text)]
                for piece in pieces:
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": piece}}}})
                send({"jsonrpc": "2.0", "id": prompt["id"], "result": {"stopReason": "end_turn"}})
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let agent = ACPAgent()
        defer { agent.stop() }
        let command = "/usr/bin/python3 -I \(script.path)"
        let first = try await collect(agent.translate("Hello, world.", to: "zh-Hans", command: command))
        XCTAssertEqual(first, "你好，世界。[s1 cancelled True]")
        let second = try await collect(agent.translate("Hello again.", to: "zh-Hans", command: command))
        XCTAssertEqual(second, "你好，世界。[s2 cancelled True]", "the same agent, a new session")

        do {
            _ = try await collect(agent.translate("x", to: "en", command: "bangs-no-such-agent --acp"))
            XCTFail("should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("找不到 bangs-no-such-agent"), error.localizedDescription)
        }
    }
}
