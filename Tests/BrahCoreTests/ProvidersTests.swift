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
