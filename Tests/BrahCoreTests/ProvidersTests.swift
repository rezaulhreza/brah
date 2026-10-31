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
        let request = AnthropicConnection.request(question: "And this?", snapshot: snapshot, key: "k",
                                                  choice: ModelChoice(model: "claude-haiku-5-5"), transcript: transcript,
                                                  system: Brief.system(for: snapshot, hands: .none))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], "medium")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["content"] as? String, "What is this?")
        XCTAssertTrue((json["system"] as? String ?? "").contains("You cannot click"))
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
