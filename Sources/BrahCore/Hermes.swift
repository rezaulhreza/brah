import Foundation

/// Where Hermes listens and the key it wants. Nothing here is stored in the source.
/// Hermes can run on this Mac or on a server (a VPS, through a Cloudflare tunnel or Tailscale).
public struct HermesSettings: Equatable, Sendable {
    public var url: URL
    public var key: String
    /// Extra headers for each request: the Cloudflare Access pair when it is set, else none.
    public var headers: [String: String]

    public init(url: URL, key: String, headers: [String: String] = [:]) {
        self.url = url
        self.key = key
        self.headers = headers
    }

    public static let defaultURL = URL(string: "http://127.0.0.1:8642")!

    /// True when Hermes runs on this Mac.
    public var isLocal: Bool { CloudflareAccess.isLocal(url) }

    /// First match wins: the environment, then the Keychain (the key only, see `Secrets`), then
    /// `~/.config/brah/config.json`, then the `API_SERVER_KEY` line of `~/.hermes/.env` (a stock
    /// Hermes install on this Mac). `secret` looks up a Keychain account; nil means the Keychain
    /// when `home` is the user's own home folder. The Cloudflare Access headers come from
    /// `CloudflareAccess.headers`.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            secret: ((String) -> String?)? = nil) -> HermesSettings? {
        let secret = Secrets.lookup(secret, home: home)
        var url = environment["BRAH_HERMES_URL"].flatMap(URL.init(string:))
        var key = environment["BRAH_HERMES_KEY"] ?? secret(Secrets.hermesKey)

        if let hermes = configSection(home: home) {
            url = url ?? (hermes["url"] as? String).flatMap(URL.init(string:))
            key = key ?? hermes["key"] as? String
        }

        if key == nil, let env = try? String(contentsOf: home.appendingPathComponent(".hermes/.env"), encoding: .utf8) {
            key = envValue(env, name: "API_SERVER_KEY")
        }

        guard let key, !key.isEmpty else { return nil }
        return HermesSettings(url: url ?? defaultURL, key: key,
                              headers: CloudflareAccess.headers(environment: environment, secret: secret))
    }

    /// The `hermes` object of `~/.config/brah/config.json`.
    static func configSection(home: URL) -> [String: Any]? {
        Config.json(home: home)?["hermes"] as? [String: Any]
    }

    static func envValue(_ text: String, name: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(name)=") else { continue }
            let value = trimmed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}

/// Hermes through its OpenAI-compatible API server. One conversation per run of Brah: Hermes
/// returns a session id with the first answer, and later questions send it back.
public actor HermesConnection: AgentConnection {
    public nonisolated let name = "Hermes"
    public nonisolated var canAct: Bool { settings.isLocal }
    private let settings: HermesSettings
    private let session: URLSession
    private var sessionID: String?

    public init(settings: HermesSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public func reset() {
        sessionID = nil
    }

    public func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply {
        let request = Self.request(question: question, snapshot: snapshot, settings: settings, sessionID: sessionID)
        let (bytes, http) = try await HTTP.stream(request, session: session)
        if let id = http?.value(forHTTPHeaderField: "X-Hermes-Session-Id"), !id.isEmpty {
            sessionID = id
        }

        var text = ""
        var parser = ChatStream.Parser()
        for try await line in bytes.lines {
            switch parser.feed(line) {
            case .text(let piece):
                text += piece
                onEvent(.text(piece))
            case .step(let label):
                onEvent(.step(label))
            case .done, nil:
                continue
            }
        }

        guard !text.isEmpty else { throw AgentError.emptyReply }
        return Reply.parse(text)
    }

    static func request(question: String, snapshot: Snapshot, settings: HermesSettings, sessionID: String?) -> URLRequest {
        var request = URLRequest(url: settings.url.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.key)", forHTTPHeaderField: "Authorization")
        settings.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
        }

        let image = "data:image/jpeg;base64,\(snapshot.jpeg.base64EncodedString())"
        let body: [String: Any] = [
            "model": "hermes-agent",
            "stream": true,
            "messages": [
                ["role": "system", "content": Brief.system(for: snapshot, hands: settings.isLocal ? .acts : .remote)],
                ["role": "user", "content": [
                    ["type": "text", "text": question],
                    ["type": "image_url", "image_url": ["url": image]],
                ]],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
