import Foundation

public enum ProviderKind: String, CaseIterable, Sendable {
    case hermes, claude, chatgpt, anthropic, custom

    public var title: String {
        switch self {
        case .hermes: "Hermes"
        case .claude: "Claude subscription"
        case .chatgpt: "ChatGPT subscription"
        case .anthropic: "Anthropic API"
        case .custom: "OpenAI-compatible"
        }
    }
}

public enum Effort: String, CaseIterable, Sendable {
    case low, medium, high, xhigh, max

    /// The `reasoning_effort` values that OpenAI-style servers know.
    var openAI: String { self == .low || self == .medium ? rawValue : "high" }
}

public struct ModelChoice: Equatable, Sendable {
    public var model: String
    public var effort: Effort

    public init(model: String, effort: Effort = .medium) {
        self.model = model
        self.effort = effort
    }
}

/// The `provider`, `claude`, `chatgpt`, `anthropic` and `custom` keys of `~/.config/brah/config.json`.
/// Keys live in the Keychain. Without a `provider` key Brah uses Hermes, as before.
public struct ProviderSettings: Equatable, Sendable {
    public var active: ProviderKind
    public var claude: ModelChoice
    public var chatgpt: ModelChoice
    public var anthropic: ModelChoice
    public var custom: ModelChoice
    /// The base URL, with the version path: `http://localhost:11434/v1`.
    public var customURL: String
    /// Many OpenAI-compatible servers reject `reasoning_effort`, so it is opt-in.
    public var customSendsEffort: Bool

    public static let claudeModels = ["haiku", "sonnet", "opus", "fable"]

    public init(active: ProviderKind = .hermes,
                claude: ModelChoice = ModelChoice(model: "haiku"),
                chatgpt: ModelChoice = ModelChoice(model: ""),
                anthropic: ModelChoice = ModelChoice(model: "claude-haiku-5-5"),
                custom: ModelChoice = ModelChoice(model: ""),
                customURL: String = "", customSendsEffort: Bool = false) {
        self.active = active
        self.claude = claude
        self.chatgpt = chatgpt
        self.anthropic = anthropic
        self.custom = custom
        self.customURL = customURL
        self.customSendsEffort = customSendsEffort
    }

    public init(json: [String: Any]) {
        let defaults = ProviderSettings()
        func choice(_ key: String, _ fallback: ModelChoice) -> ModelChoice {
            let section = json[key] as? [String: Any]
            let model = (section?["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback.model
            let effort = (section?["effort"] as? String).flatMap(Effort.init(rawValue:)) ?? fallback.effort
            return ModelChoice(model: model, effort: effort)
        }
        let custom = json["custom"] as? [String: Any]
        self.init(active: (json["provider"] as? String).flatMap(ProviderKind.init(rawValue:)) ?? .hermes,
                  claude: choice("claude", defaults.claude),
                  chatgpt: choice("chatgpt", defaults.chatgpt),
                  anthropic: choice("anthropic", defaults.anthropic),
                  custom: choice("custom", defaults.custom),
                  customURL: custom?["url"] as? String ?? "",
                  customSendsEffort: custom?["sendEffort"] as? Bool ?? false)
    }

    /// `BRAH_PROVIDER` picks the provider for one run, without a change to the config file.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProviderSettings {
        var settings = ProviderSettings(json: Config.json(home: home) ?? [:])
        if let kind = environment["BRAH_PROVIDER"].flatMap(ProviderKind.init(rawValue:)) { settings.active = kind }
        return settings
    }

    public func applied(to json: [String: Any]) -> [String: Any] {
        var json = json
        json["provider"] = active.rawValue
        for (key, choice) in [("claude", claude), ("chatgpt", chatgpt), ("anthropic", anthropic), ("custom", custom)] {
            var section = json[key] as? [String: Any] ?? [:]
            section["model"] = choice.model
            section["effort"] = choice.effort.rawValue
            json[key] = section
        }
        var section = json["custom"] as? [String: Any] ?? [:]
        section["url"] = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        section["sendEffort"] = customSendsEffort
        json["custom"] = section
        return json
    }

    /// The effort of the active provider. Nil for Hermes, which sets its own.
    public var effort: Effort? {
        get {
            switch active {
            case .hermes: nil
            case .claude: claude.effort
            case .chatgpt: chatgpt.effort
            case .anthropic: anthropic.effort
            case .custom: custom.effort
            }
        }
        set {
            guard let newValue else { return }
            switch active {
            case .hermes: break
            case .claude: claude.effort = newValue
            case .chatgpt: chatgpt.effort = newValue
            case .anthropic: anthropic.effort = newValue
            case .custom: custom.effort = newValue
            }
        }
    }
}

public enum ProviderError: LocalizedError, Equatable {
    case rateLimited(retryAfter: Int?)
    case overloaded
    case server(Int)
    case badKey
    case noKey(String)
    case unknownModel(String)
    case badRequest(String)
    case offline
    case notInstalled
    case signedOut
    case chatgptSignedOut
    case refused

    public var errorDescription: String? {
        switch self {
        case .rateLimited(let seconds):
            "You hit the provider's rate limit." + (seconds.map { " Try again in \($0) seconds." } ?? " Try again soon.")
        case .overloaded: "The provider is busy right now. Try again in a moment."
        case .server(let status): "The provider had an error (\(status)). Try again in a moment."
        case .badKey: "The provider did not accept the API key. Check it in Settings."
        case .noKey(let provider): "No API key for \(provider). Add one in Settings."
        case .unknownModel(let model): "The provider does not know the model \"\(model)\". Pick another in Settings."
        case .badRequest(let text): "The provider refused the request: \(text)"
        case .offline: "Brah cannot reach the provider. Check the connection or the address in Settings."
        case .notInstalled: "Claude Code is not installed. Install it from claude.com/code, sign in, then try again."
        case .signedOut: "Claude Code is not signed in. Run claude in Terminal and sign in, then try again."
        case .chatgptSignedOut: "Brah is not signed in to ChatGPT. Open Settings and sign in again."
        case .refused: "The model declined to answer that."
        }
    }

    var retryable: Bool {
        switch self {
        case .overloaded, .server: true
        default: false
        }
    }

    public static func from(status: Int, body: String, retryAfter: String? = nil) -> ProviderError {
        let message = Self.message(in: body)
        switch status {
        case 401, 403: return .badKey
        case 404: return message.lowercased().contains("model") ? .unknownModel(message) : .badRequest(message)
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        case 529: return .overloaded
        case 500...: return body.contains("overloaded") ? .overloaded : .server(status)
        default: return .badRequest(message)
        }
    }

    /// Claude Code says what went wrong in plain text.
    static func fromClaudeCode(_ text: String) -> ProviderError {
        let lower = text.lowercased()
        if lower.contains("limit") { return .rateLimited(retryAfter: nil) }
        if lower.contains("log in") || lower.contains("login") || lower.contains("not authenticated") || lower.contains("sign in") {
            return .signedOut
        }
        if lower.contains("overloaded") { return .overloaded }
        return .badRequest(String(text.prefix(300)))
    }

    static func message(in body: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return String(body.prefix(200))
        }
        let error = json["error"] as? [String: Any]
        return error?["message"] as? String ?? json["message"] as? String ?? String(body.prefix(200))
    }
}

enum HTTP {
    /// Sends the request and checks the status. A busy or failing server gets one more try.
    static func stream(_ request: URLRequest, session: URLSession) async throws -> (URLSession.AsyncBytes, HTTPURLResponse?) {
        for attempt in 0..<2 {
            let bytes: URLSession.AsyncBytes, response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let error as URLError where error.code != .cancelled {
                throw ProviderError.offline
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return (bytes, http) }

            var body = Data()
            for try await byte in bytes.prefix(4000) { body.append(byte) }
            let error = ProviderError.from(status: status, body: String(decoding: body, as: UTF8.self),
                                           retryAfter: http?.value(forHTTPHeaderField: "retry-after"))
            guard error.retryable, attempt == 0 else { throw error }
            try await Task.sleep(for: .seconds(2))
        }
        throw ProviderError.overloaded
    }

    static func json(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw ProviderError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.from(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// The last questions and answers, as text. Only the newest question carries a screenshot.
struct Transcript {
    private(set) var turns: [(question: String, answer: String)] = []

    mutating func add(_ question: String, _ answer: String) {
        turns.append((question, answer))
        if turns.count > 12 { turns.removeFirst() }
    }

    mutating func clear() { turns = [] }
}

/// One event of a Claude stream: the Messages API sends them as `data:` lines, Claude Code
/// wraps them in `stream_event` lines.
enum ClaudeEvent: Equatable {
    case text(String)
    case stop(String)
    case error(ProviderError)

    static func parse(_ json: [String: Any]) -> ClaudeEvent? {
        switch json["type"] as? String {
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "message_delta":
            return ((json["delta"] as? [String: Any])?["stop_reason"] as? String).map(ClaudeEvent.stop)
        case "error":
            let error = json["error"] as? [String: Any]
            let kind = error?["type"] as? String ?? ""
            if kind == "overloaded_error" { return .error(.overloaded) }
            if kind == "rate_limit_error" { return .error(.rateLimited(retryAfter: nil)) }
            return .error(.badRequest(error?["message"] as? String ?? kind))
        default:
            return nil
        }
    }
}

/// One streamed Claude message, rebuilt block by block for the next request of a tool loop.
struct ClaudeTurn {
    private var blocks: [Int: [String: Any]] = [:]
    private var inputs: [Int: String] = [:]
    private(set) var stop = ""

    /// Takes one event. Returns the new words, if the event has any.
    mutating func feed(_ json: [String: Any]) throws -> String? {
        let index = json["index"] as? Int ?? 0
        switch json["type"] as? String {
        case "content_block_start":
            blocks[index] = json["content_block"] as? [String: Any] ?? [:]
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                blocks[index, default: [:]]["text"] = (blocks[index]?["text"] as? String ?? "") + text
                return text.isEmpty ? nil : text
            case "thinking_delta":
                blocks[index, default: [:]]["thinking"] = (blocks[index]?["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                blocks[index, default: [:]]["signature"] = (blocks[index]?["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            case "input_json_delta":
                inputs[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
        default:
            switch ClaudeEvent.parse(json) {
            case .stop(let reason): stop = reason
            case .error(let error): throw error
            default: break
            }
        }
        return nil
    }

    /// The blocks to send back as the assistant's turn, with each tool input as an object.
    var content: [[String: Any]] {
        blocks.keys.sorted().map { index in
            var block = blocks[index]!
            if block["type"] as? String == "tool_use" {
                block["input"] = inputs[index].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [String: Any]()
            }
            return block
        }
    }

    var toolUses: [(id: String, name: String, input: Data)] {
        content.filter { $0["type"] as? String == "tool_use" }.map { block in
            (block["id"] as? String ?? "", block["name"] as? String ?? "",
             (try? JSONSerialization.data(withJSONObject: block["input"] ?? [String: Any]())) ?? Data("{}".utf8))
        }
    }
}

public actor AnthropicConnection: AgentConnection {
    public nonisolated let name = "Claude"
    public nonisolated let canAct: Bool
    private let key: String
    private let actions: ScreenActing?
    private var choice: ModelChoice
    private let session: URLSession
    private var transcript = Transcript()

    private let responses: ResponseSettings

    /// With `actions`, Claude can click and type through Brah's screen tools.
    public init(key: String, choice: ModelChoice, responses: ResponseSettings = ResponseSettings(), actions: ScreenActing? = nil,
                session: URLSession = .shared) {
        self.key = key
        self.actions = actions
        canAct = actions != nil
        self.responses = responses
        self.choice = choice
        self.session = session
    }

    public func reset() { transcript.clear() }
    public func setEffort(_ effort: Effort) { choice.effort = effort }

    public func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply {
        let system = Brief.system(for: snapshot, hands: canAct ? .tools : .none, responses: responses)
        var messages = Self.messages(question: question, snapshot: snapshot, transcript: transcript)
        var text = ""
        // A tool loop: Claude asks for an action, Brah does it and sends back a new screenshot.
        for _ in 0..<25 {
            let request = Self.request(messages: messages, key: key, choice: choice, system: system, tools: canAct)
            let (bytes, _) = try await HTTP.stream(request, session: session)
            var turn = ClaudeTurn()
            if !text.isEmpty, !text.hasSuffix("\n") {
                text += "\n"
                onEvent(.text("\n"))
            }
            for try await line in bytes.lines where line.hasPrefix("data:") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                if let piece = try turn.feed(json) {
                    text += piece
                    onEvent(.text(piece))
                }
            }
            guard turn.stop == "tool_use", let actions else {
                if text.isEmpty { throw turn.stop == "refusal" ? ProviderError.refused : AgentError.emptyReply }
                break
            }
            messages.append(["role": "assistant", "content": turn.content])
            var results: [[String: Any]] = []
            for use in turn.toolUses {
                let result = await actions.run(use.name, input: use.input)
                var content: [[String: Any]] = [["type": "text", "text": result.text]]
                if let jpeg = result.jpeg {
                    content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
                }
                results.append(["type": "tool_result", "tool_use_id": use.id, "content": content, "is_error": result.isError])
            }
            messages.append(["role": "user", "content": results])
            try Task.checkCancellation()
        }
        transcript.add(question, text)
        return Reply.parse(text)
    }

    static func messages(question: String, snapshot: Snapshot, transcript: Transcript) -> [[String: Any]] {
        var messages: [[String: Any]] = transcript.turns.flatMap { turn in
            [["role": "user", "content": turn.question], ["role": "assistant", "content": turn.answer]]
        }
        messages.append(["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": snapshot.jpeg.base64EncodedString()]],
            ["type": "text", "text": question],
        ]])
        return messages
    }

    static func request(messages: [[String: Any]], key: String, choice: ModelChoice, system: String, tools: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": choice.model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "output_config": ["effort": choice.effort.rawValue],
            "messages": messages,
        ]
        if tools { body["tools"] = ScreenTool.specs }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func models(key: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let json = try await HTTP.json(request, session: session)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

/// Any server with an OpenAI-style `/chat/completions`: Ollama, LM Studio, OpenRouter, Groq, vLLM.
public actor OpenAICompatibleConnection: AgentConnection {
    public nonisolated let name: String
    public nonisolated let canAct = false
    private let baseURL: URL
    private let key: String?
    private var choice: ModelChoice
    private let sendsEffort: Bool
    private let session: URLSession
    private var transcript = Transcript()

    private let responses: ResponseSettings

    public init(baseURL: URL, key: String?, choice: ModelChoice, sendsEffort: Bool, responses: ResponseSettings = ResponseSettings(),
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.responses = responses
        self.key = key
        self.choice = choice
        self.sendsEffort = sendsEffort
        self.session = session
        name = choice.model
    }

    public func reset() { transcript.clear() }
    public func setEffort(_ effort: Effort) { choice.effort = effort }

    public func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply {
        let request = Self.request(question: question, snapshot: snapshot, baseURL: baseURL, key: key, choice: choice,
                                   sendsEffort: sendsEffort, transcript: transcript,
                                   system: Brief.system(for: snapshot, hands: .none, responses: responses))
        let (bytes, _) = try await HTTP.stream(request, session: session)
        var text = ""
        for try await line in bytes.lines {
            if case .text(let piece) = ChatStream.parse(line) {
                text += piece
                onEvent(.text(piece))
            }
        }
        guard !text.isEmpty else { throw AgentError.emptyReply }
        transcript.add(question, text)
        return Reply.parse(text)
    }

    static func request(question: String, snapshot: Snapshot, baseURL: URL, key: String?, choice: ModelChoice,
                        sendsEffort: Bool, transcript: Transcript, system: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in transcript.turns {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": [
            ["type": "text", "text": question],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(snapshot.jpeg.base64EncodedString())"]],
        ]])
        var body: [String: Any] = ["model": choice.model, "stream": true, "messages": messages]
        if sendsEffort { body["reasoning_effort"] = choice.effort.openAI }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func models(baseURL: URL, key: String?, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let json = try await HTTP.json(request, session: session)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}
