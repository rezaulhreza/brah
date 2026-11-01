import CoreGraphics
import Foundation
import XCTest
@testable import BrahCore

final class ProvidersTests: XCTestCase {
    let snapshot = Snapshot(jpeg: Data([1, 2, 3]), imageSize: CGSize(width: 10, height: 10), screenFrame: .zero, scale: 1,
                            cursor: .zero, appName: nil, windowTitle: nil)

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testDefaultsAreHermesThenHaikuAtMedium() {
        let settings = ProviderSettings(json: [:])
        XCTAssertEqual(settings.active, .hermes)
        XCTAssertEqual(settings.claude, ModelChoice(model: "haiku", effort: .medium))
        XCTAssertEqual(settings.anthropic, ModelChoice(model: "claude-haiku-5-5", effort: .medium))
        XCTAssertNil(settings.effort)
    }

    func testSettingsRoundTripAndKeepOtherKeys() {
        var settings = ProviderSettings()
        settings.active = .custom
        settings.customURL = " http://localhost:11434/v1 "
        settings.custom.model = "qwen2.5vl"
        settings.effort = .high
        let json = settings.applied(to: ["hermes": ["url": "x"]])
        XCTAssertNotNil(json["hermes"])
        let back = ProviderSettings(json: json)
        XCTAssertEqual(back.active, .custom)
        XCTAssertEqual(back.customURL, "http://localhost:11434/v1")
        XCTAssertEqual(back.custom, ModelChoice(model: "qwen2.5vl", effort: .high))
    }

    func testErrorsFromStatus() {
        XCTAssertEqual(ProviderError.from(status: 429, body: "", retryAfter: "12"), .rateLimited(retryAfter: 12))
        XCTAssertEqual(ProviderError.from(status: 529, body: ""), .overloaded)
        XCTAssertEqual(ProviderError.from(status: 401, body: ""), .badKey)
        XCTAssertEqual(ProviderError.from(status: 503, body: "{}"), .server(503))
        XCTAssertEqual(ProviderError.from(status: 400, body: #"{"error":{"message":"bad image"}}"#), .badRequest("bad image"))
        XCTAssertEqual(ProviderError.fromClaudeCode("Claude AI usage limit reached"), .rateLimited(retryAfter: nil))
        XCTAssertEqual(ProviderError.fromClaudeCode("Invalid API key · Please run /login"), .signedOut)
    }

    func testClaudeEvents() {
        XCTAssertEqual(ClaudeEvent.parse(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hi"]]), .text("Hi"))
        XCTAssertNil(ClaudeEvent.parse(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "x"]]))
        XCTAssertEqual(ClaudeEvent.parse(["type": "message_delta", "delta": ["stop_reason": "refusal"]]), .stop("refusal"))
        XCTAssertEqual(ClaudeEvent.parse(["type": "error", "error": ["type": "overloaded_error"]]), .error(.overloaded))
    }

    func testAnthropicRequest() throws {
        var transcript = Transcript()
        transcript.add("What is this?", "A chart.")
        let messages = AnthropicConnection.messages(question: "And this?", snapshot: snapshot, transcript: transcript)
        let request = AnthropicConnection.request(messages: messages, key: "k", choice: ModelChoice(model: "claude-haiku-5-5"),
                                                  system: Brief.system(for: snapshot, hands: .none), tools: false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], "medium")
        XCTAssertNil(json["tools"])
        let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0]["content"] as? String, "What is this?")
        XCTAssertTrue((json["system"] as? String ?? "").contains("You cannot click"))

        let withTools = try body(AnthropicConnection.request(messages: messages, key: "k", choice: ModelChoice(model: "m"),
                                                             system: "S", tools: true))
        XCTAssertEqual((withTools["tools"] as? [[String: Any]])?.count, ScreenTool.names.count)
    }

    func testClaudeTurnRebuildsToolUse() throws {
        var turn = ClaudeTurn()
        let events: [[String: Any]] = [
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig"]],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "On it."]],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "t1", "name": "click", "input": [String: Any]()]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"x\": 4,"]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": " \"y\": 5}"]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
        ]
        let words = try events.compactMap { try turn.feed($0) }
        XCTAssertEqual(words, ["On it."])
        XCTAssertEqual(turn.stop, "tool_use")
        XCTAssertEqual(turn.content[0]["signature"] as? String, "sig")
        XCTAssertEqual((turn.content[2]["input"] as? [String: Int])?["y"], 5)
        XCTAssertEqual(turn.toolUses.first?.name, "click")
    }

    func testOpenAIRequestSendsEffortOnlyWhenAsked() throws {
        let url = URL(string: "http://localhost:11434/v1")!
        let plain = OpenAICompatibleConnection.request(question: "Hi", snapshot: snapshot, baseURL: url, key: nil,
                                                       choice: ModelChoice(model: "m", effort: .max), sendsEffort: false,
                                                       transcript: Transcript(), system: "S")
        XCTAssertEqual(plain.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(plain.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(try body(plain)["reasoning_effort"])

        let withEffort = OpenAICompatibleConnection.request(question: "Hi", snapshot: snapshot, baseURL: url, key: "k",
                                                            choice: ModelChoice(model: "m", effort: .max), sendsEffort: true,
                                                            transcript: Transcript(), system: "S")
        XCTAssertEqual(try body(withEffort)["reasoning_effort"] as? String, "high")
    }

    func testClaudeCodeRunsWithoutToolsAndResumes() throws {
        let args = ClaudeCodeConnection.arguments(choice: ModelChoice(model: "haiku"), system: "S", resume: "abc")
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], "medium")
        XCTAssertEqual(Array(args.suffix(2)), ["--resume", "abc"])

        let line = ClaudeCodeConnection.input(question: "Q", snapshot: snapshot)
        XCTAssertEqual(line.last, 0x0A)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "user")
    }
}

final class MarksTests: XCTestCase {
    func testMarksParseAndLeaveTheText() {
        let reply = Reply.parse("Look here.\nCIRCLE 380 210 140 40 Total\n[ARROW 1, 2 3 4 \"Go\"]\nUNDERLINE 1 2 3\nLINE 1 2 3")
        XCTAssertEqual(reply.text, "Look here.\nLINE 1 2 3")
        XCTAssertEqual(reply.marks, [
            Mark(shape: .circle, numbers: [380, 210, 140, 40], label: "Total"),
            Mark(shape: .arrow, numbers: [1, 2, 3, 4], label: "Go"),
            Mark(shape: .underline, numbers: [1, 2, 3]),
        ])
    }

    func testWhiteboardMarks() {
        let reply = Reply.parse("Here.\nHIGHLIGHT 1 2 3 4 Answer\nNUMBER 5 6 2 Next\nTICK 7 8\nCROSS 1 2 3 4\nSPOTLIGHT 1 2 3 4\nTICK 1 2 3")
        XCTAssertEqual(reply.text, "Here.\nTICK 1 2 3")
        XCTAssertEqual(reply.marks.map(\.shape), [.highlight, .number, .tick, .cross, .spotlight])
        XCTAssertEqual(reply.marks[1], Mark(shape: .number, numbers: [5, 6, 2], label: "Next"))
        var filter = SpokenText()
        XCTAssertEqual(filter.feed("Look.\nSPOTLIGHT 1 2 3 4\nDone.") + filter.finish(), "Look.\n\nDone.")
    }

    func testMarksAreNotSpoken() {
        var filter = SpokenText()
        let spoken = ["See", " the total.\nCIR", "CLE 380 210 140 40 Total\nBox", "es are fine."].map { filter.feed($0) }.joined()
            + filter.finish()
        XCTAssertEqual(spoken, "See the total.\n\nBoxes are fine.")
    }

    func testBriefTeachesMarks() {
        let snapshot = Snapshot(jpeg: Data(), imageSize: CGSize(width: 10, height: 10), screenFrame: .zero, scale: 1,
                                cursor: .zero, appName: nil, windowTitle: nil)
        XCTAssertTrue(Brief.system(for: snapshot).contains("CIRCLE 380 210 140 40 Total"))
    }
}

final class ResponsesTests: XCTestCase {
    func testStyleAndInstructionsReachTheBrief() {
        let snapshot = Snapshot(jpeg: Data(), imageSize: CGSize(width: 10, height: 10), screenFrame: .zero, scale: 1,
                                cursor: .zero, appName: nil, windowTitle: nil)
        XCTAssertTrue(Brief.system(for: snapshot).contains("at most three short sentences"))
        let responses = ResponseSettings(json: ["responses": ["style": "detailed", "instructions": " Call me Rez. "]])
        let brief = Brief.system(for: snapshot, responses: responses)
        XCTAssertTrue(brief.contains("as fully as the question needs"))
        XCTAssertTrue(brief.hasSuffix("The user's own instructions for every answer:\nCall me Rez."))
        XCTAssertEqual(ResponseSettings(json: responses.applied(to: [:])), ResponseSettings(style: .detailed, instructions: "Call me Rez."))
    }
}

final class SpeechTests: XCTestCase {
    func testSpeechSettingsRoundTrip() {
        XCTAssertEqual(SpeechSettings(json: nil), SpeechSettings())
        let settings = SpeechSettings(provider: .groq, macVoice: "x", deepgramVoice: "aura-2-pandora-en", groqVoice: "troy")
        XCTAssertEqual(SpeechSettings(json: settings.applied(to: ["other": 1])), settings)
        XCTAssertTrue(SpeechSettings.deepgramVoices.contains { $0.id == "aura-2-athena-en" })
    }

    func testOwnDeepgramKeyStaysOutOfTraining() {
        let settings = DeepgramLiveSettings(voice: "aura-2-athena-en")
        XCTAssertTrue(settings.speakURL().absoluteString.contains("mip_opt_out=true"))
        XCTAssertTrue(settings.listenURL(sampleRate: 16000).absoluteString.contains("mip_opt_out=true"))
    }

    func testGroqRequestAndPieces() throws {
        let request = GroqSpeech.request("Hi.", voice: "troy", key: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["voice"], "troy")
        XCTAssertEqual(body["model"], "canopylabs/orpheus-v1-english")

        XCTAssertEqual(GroqSpeech.pieces("One. Two. Three.", limit: 9), ["One. Two.", "Three."])
        XCTAssertEqual(GroqSpeech.pieces(""), [])
    }
}

final class ScreenToolTests: XCTestCase {
    func testRisk() {
        XCTAssertTrue(ScreenTool.isRisky(label: "Send invoice", flagged: false))
        XCTAssertTrue(ScreenTool.isRisky(label: "Open tab", flagged: true))
        XCTAssertFalse(ScreenTool.isRisky(label: "Open the Acquisition tab", flagged: false))
        XCTAssertFalse(ScreenTool.isRisky(label: "Orders page", flagged: false))
        XCTAssertFalse(ScreenTool.isRisky(label: "Open send time dropdown", flagged: false))
        XCTAssertFalse(ScreenTool.isRisky(label: "View order #1024", flagged: false))
        XCTAssertTrue(ScreenTool.isRisky(label: "Confirm send invoice", flagged: false))
        XCTAssertTrue(ScreenTool.isRisky(label: "Sign in with Google", flagged: false))
        XCTAssertFalse(ScreenTool.isRisky(label: "Sign up form", flagged: false))
    }

    func testKeyPress() {
        XCTAssertEqual(Shortcut.keyPress("return")?.modifiers, 0)
        XCTAssertEqual(Shortcut.keyPress("cmd+l")?.modifiers, Shortcut.command)
        XCTAssertNil(Shortcut.keyPress("hyper+l"))
        XCTAssertEqual(ScreenTool.specs.compactMap { $0["name"] as? String }, ScreenTool.names)
    }
}

final class MCPTests: XCTestCase {
    struct Echo: ScreenActing {
        func run(_ name: String, input: Data) async -> ToolResult {
            ToolResult(text: "\(name) \(String(decoding: input, as: UTF8.self))", jpeg: Data([1]))
        }
    }

    private func call(_ object: [String: Any]) async throws -> [String: Any]? {
        let body = try JSONSerialization.data(withJSONObject: object)
        guard let data = await MCP.respond(to: body, actions: Echo()) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testListAndCall() async throws {
        let list = try await call(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ScreenTool.names)
        XCTAssertNotNil(tools[1]["inputSchema"])

        let result = try await call(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                     "params": ["name": "click", "arguments": ["x": 1]]])?["result"] as? [String: Any]
        let content = try XCTUnwrap(result?["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, #"click {"x":1}"#)
        XCTAssertEqual(content[1]["type"] as? String, "image")

        let note = try await call(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(note)
    }

    func testClaudeCodeGetsTheTools() {
        let tools = ToolServerAddress(url: URL(string: "http://127.0.0.1:5000/mcp")!, token: "t")
        let args = ClaudeCodeConnection.arguments(choice: ModelChoice(model: "haiku"), system: "S", resume: nil, tools: tools)
        XCTAssertEqual(args[args.firstIndex(of: "--allowedTools")! + 1], "mcp__brah__screenshot,mcp__brah__click,mcp__brah__type,mcp__brah__key,mcp__brah__scroll")
        XCTAssertTrue(args[args.firstIndex(of: "--mcp-config")! + 1].contains(#""url":"http://127.0.0.1:5000/mcp""#))
    }
}

final class ChatGPTTests: XCTestCase {
    let snapshot = Snapshot(jpeg: Data([1, 2, 3]), imageSize: CGSize(width: 10, height: 10), screenFrame: .zero, scale: 1,
                            cursor: .zero, appName: nil, windowTitle: nil)

    /// A token with the claims that ChatGPT puts in its ID token.
    func jwt(_ claims: [String: Any]) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        return "e30.\(payload.base64URL).sig"
    }

    func tokens(access: String = "access", refresh: String = "refresh", expiresAt: Date = Date().addingTimeInterval(3600)) -> ChatGPTTokens {
        ChatGPTTokens(accessToken: access, refreshToken: refresh, idToken: nil, expiresAt: expiresAt, accountID: "acct",
                      email: "rez@example.com", plan: "plus")
    }

    func testSettingsKnowChatGPT() {
        XCTAssertEqual(ProviderKind(rawValue: "chatgpt"), .chatgpt)
        var settings = ProviderSettings()
        settings.active = .chatgpt
        settings.chatgpt = ModelChoice(model: "gpt-x", effort: .high)
        XCTAssertEqual(settings.effort, .high)
        settings.effort = .low
        let back = ProviderSettings(json: settings.applied(to: [:]))
        XCTAssertEqual(back.active, .chatgpt)
        XCTAssertEqual(back.chatgpt, ModelChoice(model: "gpt-x", effort: .low))
    }

    func testPKCEMatchesTheRFCExample() {
        let pkce = ChatGPTAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertNotEqual(ChatGPTAuth.PKCE().verifier, ChatGPTAuth.PKCE().verifier)
    }

    func testAuthorizeURL() throws {
        let url = ChatGPTAuth.authorizeURL(redirectURI: ChatGPTAuth.redirectURI(port: 1455), challenge: "C", state: "S")
        XCTAssertEqual(url.host, "auth.openai.com")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["client_id"], ChatGPTAuth.clientID)
        XCTAssertEqual(items["state"], "S")
        XCTAssertTrue(items["scope"]?.contains("offline_access") == true)
    }

    func testCallback() {
        XCTAssertEqual(ChatGPTAuth.callback(path: "/auth/callback?code=abc&state=S", state: "S"), .code("abc"))
        XCTAssertEqual(ChatGPTAuth.callback(path: "/auth/callback?code=abc&state=other", state: "S"), .ignore)
        XCTAssertEqual(ChatGPTAuth.callback(path: "/favicon.ico", state: "S"), .ignore)
        XCTAssertEqual(ChatGPTAuth.callback(path: "/auth/callback?error=access_denied&error_description=No&state=S", state: "S"),
                       .failed(.denied("No")))
    }

    func testTokensCarryTheAccountAndKeepOldValuesOnRefresh() throws {
        let id = jwt(["email": "rez@example.com",
                      "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "pro"]])
        let first = try ChatGPTAuth.tokens(from: ["access_token": "a1", "refresh_token": "r1", "id_token": id, "expires_in": 3600.0],
                                           previous: nil, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(first.accountID, "acct-1")
        XCTAssertEqual(first.email, "rez@example.com")
        XCTAssertEqual(first.plan, "pro")
        XCTAssertEqual(first.expiresAt, Date(timeIntervalSince1970: 4600))

        let second = try ChatGPTAuth.tokens(from: ["access_token": "a2"], previous: first)
        XCTAssertEqual(second.refreshToken, "r1")
        XCTAssertEqual(second.accountID, "acct-1")
        XCTAssertEqual(second.email, "rez@example.com")

        XCTAssertThrowsError(try ChatGPTAuth.tokens(from: ["access_token": "a"], previous: nil))
        XCTAssertTrue(tokens(expiresAt: Date().addingTimeInterval(60)).expires(within: 300))
    }

    func testRequestForTheCodexEndpoint() throws {
        let transcript = { () -> Transcript in
            var t = Transcript()
            t.add("What is this?", "A chart.")
            return t
        }()
        let input = ChatGPTConnection.input(question: "And this?", snapshot: snapshot, transcript: transcript)
        XCTAssertEqual(input.count, 3)
        let last = try XCTUnwrap((input[2]["content"] as? [[String: Any]]))
        XCTAssertEqual(last.map { $0["type"] as? String }, ["input_text", "input_image"])

        let request = ChatGPTConnection.request(input: input, instructions: "S", choice: ModelChoice(model: "m", effort: .max), tools: true,
                                                sessionID: "sid", tokens: tokens())
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session_id"), "sid")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["instructions"] as? String, "S")
        XCTAssertEqual((json["reasoning"] as? [String: String])?["effort"], "high")
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ScreenTool.names)
        XCTAssertEqual(tools[1]["type"] as? String, "function")
        XCTAssertNotNil(tools[1]["parameters"])

        let plain = ChatGPTConnection.request(input: input, instructions: "S", choice: ModelChoice(model: "m"), tools: false,
                                              sessionID: "sid", tokens: tokens())
        XCTAssertNil((try JSONSerialization.jsonObject(with: XCTUnwrap(plain.httpBody)) as? [String: Any])?["tools"])
    }

    func testTurnCollectsWordsAndToolCalls() throws {
        var turn = ResponsesTurn()
        let events: [[String: Any]] = [
            ["type": "response.output_text.delta", "delta": "On it."],
            ["type": "response.output_item.done", "item": ["type": "message", "role": "assistant"]],
            ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "click", "arguments": "{\"x\":4}"]],
            ["type": "response.completed", "response": [String: Any]()],
        ]
        XCTAssertEqual(try events.compactMap { try turn.feed($0) }, ["On it."])
        XCTAssertTrue(turn.finished)
        XCTAssertEqual(turn.toolCalls.count, 1)
        XCTAssertEqual(turn.toolCalls[0].callID, "c1")
        XCTAssertEqual(turn.toolCalls[0].arguments, "{\"x\":4}")
    }

    func testTurnFailures() {
        var turn = ResponsesTurn()
        XCTAssertThrowsError(try turn.feed(["type": "response.failed", "response": ["error": ["code": "rate_limit_exceeded"]]])) {
            XCTAssertEqual($0 as? ProviderError, .rateLimited(retryAfter: nil))
        }
        XCTAssertThrowsError(try turn.feed(["type": "error", "message": "nope"])) {
            XCTAssertEqual($0 as? ProviderError, .badRequest("nope"))
        }
    }

    func testNoModelIsHardcoded() {
        XCTAssertEqual(ProviderSettings().chatgpt.model, "")
        XCTAssertEqual(ChatGPTConnection.preferred(from: ["gpt-a", "gpt-6.1-luna", "gpt-6.1-terra"]), "gpt-6.1-luna")
        XCTAssertEqual(ChatGPTConnection.preferred(from: ["GPT 6.1 Luna"]), "GPT 6.1 Luna")
        XCTAssertEqual(ChatGPTConnection.preferred(from: ["gpt-a", "gpt-b"]), "gpt-a")
        XCTAssertNil(ChatGPTConnection.preferred(from: []))
    }

    func testModelListSkipsHiddenModels() {
        let json: [String: Any] = ["models": [["slug": "a"], ["slug": "b", "visibility": "hide"], ["slug": "c", "visibility": "list"]]]
        XCTAssertEqual(ChatGPTConnection.models(in: json), ["a", "c"])
    }

    // MARK: Refresh

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: Any]))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, json) = Self.handler?(request) ?? (500, [:])
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    final class Box: @unchecked Sendable { var tokens: ChatGPTTokens? }

    func account(_ start: ChatGPTTokens?) -> (ChatGPTAccount, Box) {
        let box = Box()
        box.tokens = start
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let store = ChatGPTTokenStore(load: { box.tokens }, save: { box.tokens = $0 })
        return (ChatGPTAccount(store: store, session: URLSession(configuration: configuration)), box)
    }

    func testFreshTokensAreNotRefreshed() async throws {
        Stub.handler = { _ in XCTFail("no refresh expected"); return (500, [:]) }
        let (account, _) = account(tokens())
        let current = try await account.current()
        XCTAssertEqual(current.accessToken, "access")
    }

    func testOldTokensAreRefreshedAndSaved() async throws {
        Stub.handler = { request in
            let body = String(decoding: request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                return data
            }!, as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("refresh_token=old"))
            return (200, ["access_token": "new", "expires_in": 3600.0])
        }
        let (account, box) = account(tokens(access: "stale", refresh: "old", expiresAt: Date().addingTimeInterval(10)))
        let current = try await account.current()
        XCTAssertEqual(current.accessToken, "new")
        XCTAssertEqual(box.tokens?.accessToken, "new")
        XCTAssertEqual(box.tokens?.refreshToken, "old")
        XCTAssertEqual(box.tokens?.accountID, "acct")
    }

    func testRefreshTokenThatChatGPTRefusesMeansSignedOut() async {
        Stub.handler = { _ in (400, ["error": "invalid_grant"]) }
        let (account, _) = account(tokens(expiresAt: Date().addingTimeInterval(10)))
        do {
            _ = try await account.current()
            XCTFail("expected a sign-out")
        } catch {
            XCTAssertEqual(error as? ProviderError, .chatgptSignedOut)
        }
    }

    func testNoTokensMeansSignedOut() async {
        let (account, _) = account(nil)
        do {
            _ = try await account.current()
            XCTFail("expected a sign-out")
        } catch {
            XCTAssertEqual(error as? ProviderError, .chatgptSignedOut)
        }
    }
}
