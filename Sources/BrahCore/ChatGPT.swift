import CryptoKit
import Foundation
import Security

/// A ChatGPT sign-in. Brah gets these tokens by itself, with the same browser sign-in that the
/// Codex app uses, so the Codex app does not need to be on the Mac.
public struct ChatGPTTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String?
    public var expiresAt: Date
    public var accountID: String
    public var email: String?
    public var plan: String?

    func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < seconds
    }
}

public enum ChatGPTLoginError: LocalizedError, Equatable {
    case portBusy
    case timedOut
    case denied(String)
    case noAccount

    public var errorDescription: String? {
        switch self {
        case .portBusy: "Brah cannot listen for the ChatGPT sign-in. Close any other sign-in (for example codex login) and try again."
        case .timedOut: "The ChatGPT sign-in took too long. Try again."
        case .denied(let why): "ChatGPT did not sign you in: \(why)"
        case .noAccount: "ChatGPT signed you in, but sent no account. Try again."
        }
    }
}

public enum ChatGPTAuth {
    /// The public client of the Codex apps. ChatGPT only accepts a sign-in from a known client.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    /// The ports of the sign-in redirect that the client allows. The first one is the usual one.
    public static let ports: [UInt16] = [1455, 1457]
    static let scope = "openid profile email offline_access"
    static let originator = "brah"

    public static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/auth/callback" }

    /// The proof key of one sign-in (RFC 7636): the challenge goes to the browser, the verifier
    /// goes with the code to the token endpoint.
    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

        public init() { verifier = ChatGPTAuth.random(bytes: 64) }
        public init(verifier: String) { self.verifier = verifier }
    }

    static func random(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }

    public static func randomState() -> String { random(bytes: 24) }

    public static func authorizeURL(redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "\(issuer)/oauth/authorize")!
        components.queryItems = [
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI), ("scope", scope),
            ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
            ("id_token_add_organizations", "true"), ("codex_cli_simplified_flow", "true"), ("originator", originator),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    public enum Callback: Equatable {
        case code(String)
        case failed(ChatGPTLoginError)
        /// Some other request to the port, such as a favicon. The sign-in goes on.
        case ignore
    }

    /// What the browser asks of Brah's port after the sign-in: `/auth/callback?code=…&state=…`.
    public static func callback(path: String, state: String) -> Callback {
        guard let components = URLComponents(string: "http://localhost\(path)"), components.path == "/auth/callback" else {
            return .ignore
        }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        guard items["state"] == state else { return .ignore }
        if let error = items["error"] {
            return .failed(.denied(items["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error))
        }
        guard let code = items["code"], !code.isEmpty else { return .ignore }
        return .code(code)
    }

    // MARK: Tokens

    static func claims(of jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URL: String(parts[1])) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The tokens that the token endpoint sent. A refresh may leave out the refresh token or the
    /// ID token, and then the old ones stay.
    static func tokens(from json: [String: Any], previous: ChatGPTTokens?, now: Date = Date()) throws -> ChatGPTTokens {
        guard let access = json["access_token"] as? String, !access.isEmpty else { throw ChatGPTLoginError.noAccount }
        let idToken = (json["id_token"] as? String) ?? previous?.idToken
        let id = claims(of: idToken ?? ""), accessClaims = claims(of: access)
        func auth(_ claims: [String: Any]) -> [String: Any] { claims["https://api.openai.com/auth"] as? [String: Any] ?? [:] }

        guard let account = (auth(id)["chatgpt_account_id"] as? String) ?? (auth(accessClaims)["chatgpt_account_id"] as? String)
                ?? previous?.accountID, !account.isEmpty else { throw ChatGPTLoginError.noAccount }
        let profile = id["https://api.openai.com/profile"] as? [String: Any]
        let expiry = (json["expires_in"] as? Double).map { now.addingTimeInterval($0) }
            ?? (accessClaims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? now.addingTimeInterval(3600)
        return ChatGPTTokens(accessToken: access,
                             refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken ?? "",
                             idToken: idToken, expiresAt: expiry, accountID: account,
                             email: (id["email"] as? String) ?? (profile?["email"] as? String) ?? previous?.email,
                             plan: (auth(id)["chatgpt_plan_type"] as? String) ?? (auth(accessClaims)["chatgpt_plan_type"] as? String) ?? previous?.plan)
    }

    static func tokenRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        return request
    }

    /// Trades the code of the browser sign-in for tokens.
    public static func exchange(code: String, verifier: String, redirectURI: String, session: URLSession = .shared) async throws -> ChatGPTTokens {
        let request = tokenRequest([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                                    ("client_id", clientID), ("code_verifier", verifier)])
        return try tokens(from: try await HTTP.json(request, session: session), previous: nil)
    }

    /// New tokens for a refresh token. ChatGPT gives each refresh token to one use, so the caller
    /// must save the result at once.
    static func refresh(_ old: ChatGPTTokens, session: URLSession = .shared) async throws -> ChatGPTTokens {
        let request = tokenRequest([("grant_type", "refresh_token"), ("refresh_token", old.refreshToken), ("client_id", clientID)])
        do {
            return try tokens(from: try await HTTP.json(request, session: session), previous: old)
        } catch ProviderError.badRequest, ProviderError.badKey {
            throw ProviderError.chatgptSignedOut
        }
    }
}

/// Where the sign-in lives between runs.
public struct ChatGPTTokenStore: Sendable {
    public var load: @Sendable () -> ChatGPTTokens?
    public var save: @Sendable (ChatGPTTokens?) throws -> Void

    public init(load: @escaping @Sendable () -> ChatGPTTokens?, save: @escaping @Sendable (ChatGPTTokens?) throws -> Void) {
        self.load = load
        self.save = save
    }

    /// The login Keychain, as one JSON secret.
    public static let keychain = ChatGPTTokenStore(
        load: { Secrets.get(Secrets.chatgptAuth).flatMap { try? JSONDecoder().decode(ChatGPTTokens.self, from: Data($0.utf8)) } },
        save: { tokens in
            let text = try tokens.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
            try Secrets.set(text, for: Secrets.chatgptAuth)
        })
}

/// The one place that hands out a valid access token and refreshes it when it runs out.
public actor ChatGPTAccount {
    public static let shared = ChatGPTAccount(store: .keychain)

    private let store: ChatGPTTokenStore
    private let session: URLSession

    public init(store: ChatGPTTokenStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public var signedIn: Bool { store.load() != nil }

    public func signIn(_ tokens: ChatGPTTokens) throws { try store.save(tokens) }
    public func signOut() throws { try store.save(nil) }

    /// The tokens, refreshed first when they have less than five minutes left.
    public func current() async throws -> ChatGPTTokens {
        guard let tokens = store.load() else { throw ProviderError.chatgptSignedOut }
        return tokens.expires(within: 300) ? try await refresh(tokens) : tokens
    }

    /// A refresh that the server asked for, after it turned an access token down.
    public func renewed(after rejected: ChatGPTTokens) async throws -> ChatGPTTokens {
        guard let tokens = store.load() else { throw ProviderError.chatgptSignedOut }
        // Another question may have refreshed it already.
        return tokens.accessToken != rejected.accessToken ? tokens : try await refresh(tokens)
    }

    private func refresh(_ tokens: ChatGPTTokens) async throws -> ChatGPTTokens {
        let renewed = try await ChatGPTAuth.refresh(tokens, session: session)
        try store.save(renewed)
        return renewed
    }
}

// MARK: The model

/// One streamed answer of the Responses API, collected item by item for the next request of a
/// tool loop.
struct ResponsesTurn {
    private(set) var items: [[String: Any]] = []
    private(set) var finished = false

    /// Takes one event. Returns the new words, if the event has any.
    mutating func feed(_ json: [String: Any]) throws -> String? {
        switch json["type"] as? String {
        case "response.output_text.delta":
            let text = json["delta"] as? String ?? ""
            return text.isEmpty ? nil : text
        case "response.output_item.done":
            if let item = json["item"] as? [String: Any] { items.append(item) }
        case "response.completed", "response.incomplete":
            finished = true
        case "response.failed":
            throw Self.failure((json["response"] as? [String: Any])?["error"] as? [String: Any] ?? [:])
        case "error":
            throw Self.failure(json["error"] as? [String: Any] ?? json)
        default:
            break
        }
        return nil
    }

    var toolCalls: [(callID: String, name: String, arguments: String)] {
        items.filter { $0["type"] as? String == "function_call" }.map {
            ($0["call_id"] as? String ?? "", $0["name"] as? String ?? "", $0["arguments"] as? String ?? "{}")
        }
    }

    static func failure(_ error: [String: Any]) -> ProviderError {
        let code = (error["code"] as? String) ?? (error["type"] as? String) ?? ""
        let message = error["message"] as? String ?? code
        switch code {
        case "rate_limit_exceeded", "usage_limit_reached", "insufficient_quota": return .rateLimited(retryAfter: nil)
        case "server_is_overloaded", "overloaded", "slow_down": return .overloaded
        case "model_not_found": return .unknownModel(message)
        default: return .badRequest(message)
        }
    }
}

/// ChatGPT through the user's own subscription: the Codex endpoint of ChatGPT, with the sign-in
/// that Brah got itself. It sees the screen, and it clicks and types through Brah's screen tools.
public actor ChatGPTConnection: AgentConnection {
    public nonisolated let name = "ChatGPT"
    public nonisolated let canAct: Bool
    private let account: ChatGPTAccount
    private let actions: ScreenActing?
    private var choice: ModelChoice
    private let session: URLSession
    private var transcript = Transcript()
    private var sessionID = UUID().uuidString
    /// The model that Brah picked when the setting was empty.
    private var picked: String?

    private let responses: ResponseSettings

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex")!

    public init(choice: ModelChoice, responses: ResponseSettings = ResponseSettings(), actions: ScreenActing? = nil,
                account: ChatGPTAccount = .shared, session: URLSession = .shared) {
        self.choice = choice
        self.responses = responses
        self.actions = actions
        canAct = actions != nil
        self.account = account
        self.session = session
    }

    public func reset() {
        transcript.clear()
        sessionID = UUID().uuidString
    }

    public func setEffort(_ effort: Effort) { choice.effort = effort }

    public func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply {
        let system = Brief.system(for: snapshot, hands: canAct ? .tools : .none, responses: responses)
        var input = Self.input(question: question, snapshot: snapshot, transcript: transcript)
        let model = try await resolvedModel()
        var text = ""
        // A tool loop: the model asks for an action, Brah does it and sends back a new screenshot.
        for _ in 0..<25 {
            let bytes = try await open { tokens in
                Self.request(input: input, instructions: system, choice: ModelChoice(model: model, effort: choice.effort), tools: canAct, sessionID: sessionID, tokens: tokens)
            }
            var turn = ResponsesTurn()
            var spoken = ""
            if !text.isEmpty, !text.hasSuffix("\n") {
                text += "\n"
                onEvent(.text("\n"))
            }
            for try await line in bytes.lines where line.hasPrefix("data:") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                if let piece = try turn.feed(json) {
                    spoken += piece
                    text += piece
                    onEvent(.text(piece))
                }
            }
            let calls = turn.toolCalls
            guard !calls.isEmpty, let actions else {
                if text.isEmpty { throw AgentError.emptyReply }
                break
            }
            if !spoken.isEmpty {
                input.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": spoken]]])
            }
            for call in calls {
                input.append(["type": "function_call", "call_id": call.callID, "name": call.name, "arguments": call.arguments])
            }
            var screenshots: [[String: Any]] = []
            for call in calls {
                let result = await actions.run(call.name, input: Data(call.arguments.utf8))
                input.append(["type": "function_call_output", "call_id": call.callID, "output": result.text])
                if let jpeg = result.jpeg {
                    screenshots.append(Self.image(jpeg, caption: "The screen after \(call.name):"))
                }
            }
            input += screenshots
            try Task.checkCancellation()
        }
        transcript.add(question, text)
        return Reply.parse(text)
    }

    /// The model of the setting, or when it is empty the best one that the account has.
    private func resolvedModel() async throws -> String {
        if !choice.model.isEmpty { return choice.model }
        if let picked { return picked }
        guard let model = Self.preferred(from: try await Self.models(account: account, session: session)) else {
            throw ProviderError.unknownModel("none")
        }
        picked = model
        return model
    }

    /// Brah's first choice, matched by name because the slug may differ. Else the first model.
    public static func preferred(from models: [String]) -> String? {
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return models.first { plain($0).contains(plain(favourite)) } ?? models.first
    }

    static let favourite = "gpt 6.1 luna"

    /// Opens the stream. When ChatGPT turns the access token down, it refreshes once and tries again.
    private func open(_ build: (ChatGPTTokens) -> URLRequest) async throws -> URLSession.AsyncBytes {
        var tokens = try await account.current()
        do {
            return try await HTTP.stream(build(tokens), session: session).0
        } catch ProviderError.badKey {
            tokens = try await account.renewed(after: tokens)
            do {
                return try await HTTP.stream(build(tokens), session: session).0
            } catch ProviderError.badKey {
                throw ProviderError.chatgptSignedOut
            }
        }
    }

    static func image(_ jpeg: Data, caption: String) -> [String: Any] {
        ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": caption],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
        ]]
    }

    static func input(question: String, snapshot: Snapshot, transcript: Transcript) -> [[String: Any]] {
        var input: [[String: Any]] = transcript.turns.flatMap { turn -> [[String: Any]] in
            [["type": "message", "role": "user", "content": [["type": "input_text", "text": turn.question]]],
             ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": turn.answer]]]]
        }
        input.append(["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": question],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(snapshot.jpeg.base64EncodedString())"],
        ]])
        return input
    }

    static func headers(_ request: inout URLRequest, tokens: ChatGPTTokens, sessionID: String? = nil) {
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(ChatGPTAuth.originator, forHTTPHeaderField: "originator")
        request.setValue("Brah", forHTTPHeaderField: "User-Agent")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "session_id") }
    }

    static func request(input: [[String: Any]], instructions: String, choice: ModelChoice, tools: Bool, sessionID: String,
                        tokens: ChatGPTTokens) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        headers(&request, tokens: tokens, sessionID: sessionID)
        var body: [String: Any] = [
            "model": choice.model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "stream": true,
            "reasoning": ["effort": choice.effort.openAI],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "prompt_cache_key": sessionID,
        ]
        if tools {
            body["tools"] = ScreenTool.specs.map { spec in
                ["type": "function", "name": spec["name"]!, "description": spec["description"]!, "parameters": spec["input_schema"]!,
                 "strict": false] as [String: Any]
            }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The model slugs that the account can use. Hidden models are left out.
    public static func models(account: ChatGPTAccount = .shared, session: URLSession = .shared) async throws -> [String] {
        let tokens = try await account.current()
        var components = URLComponents(url: endpoint.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client_version", value: "1.0.0")]
        var request = URLRequest(url: components.url!)
        headers(&request, tokens: tokens)
        do {
            return models(in: try await HTTP.json(request, session: session))
        } catch ProviderError.badKey {
            throw ProviderError.chatgptSignedOut
        }
    }

    static func models(in json: [String: Any]) -> [String] {
        (json["models"] as? [[String: Any]] ?? []).compactMap { model in
            model["visibility"] as? String == "hide" ? nil : model["slug"] as? String
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
