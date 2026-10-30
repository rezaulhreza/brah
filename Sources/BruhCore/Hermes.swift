import Foundation

/// Where Hermes listens and the key it wants. Nothing here is stored in the source.
public struct HermesSettings: Equatable, Sendable {
    public var url: URL
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    public static let defaultURL = URL(string: "http://127.0.0.1:8642")!

    /// First match wins: the environment, then `~/.config/bruh/config.json`, then the
    /// `API_SERVER_KEY` line of `~/.hermes/.env` (a stock Hermes install on this Mac).
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HermesSettings? {
        var url = environment["BRUH_HERMES_URL"].flatMap(URL.init(string:))
        var key = environment["BRUH_HERMES_KEY"]

        if let hermes = configSection(home: home) {
            url = url ?? (hermes["url"] as? String).flatMap(URL.init(string:))
            key = key ?? hermes["key"] as? String
        }

        if key == nil, let env = try? String(contentsOf: home.appendingPathComponent(".hermes/.env"), encoding: .utf8) {
            key = envValue(env, name: "API_SERVER_KEY")
        }

        guard let key, !key.isEmpty else { return nil }
        return HermesSettings(url: url ?? defaultURL, key: key)
    }

    /// The `hermes` object of `~/.config/bruh/config.json`.
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

/// Hermes through its OpenAI-compatible API server. One conversation per run of Bruh: Hermes
/// returns a session id with the first answer, and later questions send it back.
public actor HermesConnection: AgentConnection {
    public nonisolated let name = "Hermes"
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
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            var body = Data()
            for try await byte in bytes.prefix(2000) { body.append(byte) }
            throw AgentError.http(status, String(decoding: body, as: UTF8.self))
        }

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
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
        }

        let image = "data:image/jpeg;base64,\(snapshot.jpeg.base64EncodedString())"
        let body: [String: Any] = [
            "model": "hermes-agent",
            "stream": true,
            "messages": [
                ["role": "system", "content": Brief.system(for: snapshot)],
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
