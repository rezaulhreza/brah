import Foundation

/// The Hermes web backend, which owns the voice. Its audio routes use the speech providers the
/// user chose in Hermes (Deepgram, ElevenLabs, Edge, local Whisper and others), so Brah needs no
/// speech account of its own.
public struct HermesVoiceSettings: Equatable, Sendable {
    public var url: URL
    public var username: String?
    public var password: String?
    /// Extra headers for each request: the Cloudflare Access pair when it is set, else none.
    public var headers: [String: String]

    public init(url: URL, username: String? = nil, password: String? = nil, headers: [String: String] = [:]) {
        self.url = url
        self.username = username
        self.password = password
        self.headers = headers
    }

    /// The port of `hermes dashboard`.
    public static let defaultURL = URL(string: "http://127.0.0.1:9119")!

    /// True when the dashboard runs on this Mac.
    public var isLocal: Bool { CloudflareAccess.isLocal(url) }

    /// The environment first, then `voice` in the `hermes` object of `~/.config/brah/config.json`:
    /// `{"hermes": {"voice": {"url": "...", "username": "...", "password": "..."}}}`.
    /// The password comes from the Keychain before the file (see `Secrets`). `secret` looks up a
    /// Keychain account; nil means the Keychain when `home` is the user's own home folder.
    /// The sign-in is only for a dashboard that asks for one. The Cloudflare Access headers come
    /// from `CloudflareAccess.headers`.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            secret: ((String) -> String?)? = nil) -> HermesVoiceSettings {
        let secret = Secrets.lookup(secret, home: home)
        let voice = HermesSettings.configSection(home: home)?["voice"] as? [String: Any]
        let url = environment["BRAH_HERMES_VOICE_URL"].flatMap(URL.init(string:))
            ?? (voice?["url"] as? String).flatMap(URL.init(string:))
        let username = environment["BRAH_HERMES_USERNAME"] ?? voice?["username"] as? String
        let password = environment["BRAH_HERMES_PASSWORD"]
            ?? secret(Secrets.voicePassword)
            ?? voice?["password"] as? String
        return HermesVoiceSettings(url: url ?? defaultURL,
                                   username: username?.isEmpty == false ? username : nil,
                                   password: password?.isEmpty == false ? password : nil,
                                   headers: CloudflareAccess.headers(environment: environment, secret: secret))
    }

    /// The session token a local dashboard puts in its page, when it shares it.
    static func pageToken(_ html: String) -> String? {
        guard let match = html.firstMatch(of: try! Regex(#"__HERMES_SESSION_TOKEN__\s*=\s*"([^"]+)""#)),
              let token = match.output[1].substring
        else { return nil }
        return String(token)
    }
}

/// Sound from the agent's voice, as the backend sent it.
public struct Sound: Equatable, Sendable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// `data:audio/mpeg;base64,....`
    public init?(dataURL: String) {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        self.init(data: data, mimeType: String(header.split(separator: ";").first ?? "audio/mpeg"))
    }
}

public actor HermesVoice {
    private let settings: HermesVoiceSettings
    private let session: URLSession
    /// How the backend let Brah in: its session token, or a cookie from the password sign-in.
    private var token: String?
    private var connected = false

    public init(settings: HermesVoiceSettings) {
        self.settings = settings
        // Its own cookie jar: a password sign-in lives in a cookie.
        session = URLSession(configuration: .ephemeral)
    }

    /// Get in to the backend. A local dashboard that shares its session token needs no setup.
    /// One that asks for a sign-in needs the username and password from the settings.
    public func connect() async throws {
        connected = false
        token = nil

        var page = URLRequest(url: settings.url)
        settings.headers.forEach { page.setValue($1, forHTTPHeaderField: $0) }
        if let (data, response) = try? await session.data(for: page),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let found = HermesVoiceSettings.pageToken(String(decoding: data, as: UTF8.self)) {
            token = found
            connected = true
            return
        }

        guard let username = settings.username, let password = settings.password else {
            throw AgentError.notConfigured(
                "The Hermes dashboard at \(settings.url.absoluteString) asks for a sign-in. Add hermes.voice.username and hermes.voice.password to ~/.config/brah/config.json.")
        }
        let body = ["provider": "basic", "username": username, "password": password, "next": "/"]
        let (data, status) = try await send("auth/password-login", body: body)
        guard (200..<300).contains(status) else {
            throw AgentError.http(status, "Hermes refused the voice sign-in. \(String(decoding: data, as: UTF8.self))")
        }
        connected = true
    }

    /// Words from a recording. An empty string means the provider heard no words.
    public func transcribe(wav: Data) async throws -> String {
        let body: [String: Any] = ["data_url": "data:audio/wav;base64,\(wav.base64EncodedString())", "mime_type": "audio/wav"]
        let json = try await post("api/audio/transcribe", body: body)
        return (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func speak(_ text: String) async throws -> Sound {
        let json = try await post("api/audio/speak", body: ["text": text])
        guard let sound = (json["data_url"] as? String).flatMap(Sound.init(dataURL:)) else { throw AgentError.emptyReply }
        return sound
    }

    /// A WebSocket to a live audio route. The backend admits a socket with a one-time ticket.
    public func socket(_ path: String) async throws -> URLSessionWebSocketTask {
        let json = try await post("api/auth/ws-ticket", body: [:])
        guard let ticket = json["ticket"] as? String, !ticket.isEmpty else { throw AgentError.emptyReply }

        var components = URLComponents(url: settings.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.scheme = settings.url.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        var request = URLRequest(url: components.url!)
        request.setValue(settings.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        settings.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }

    /// The settings of the `deepgram-live` plugin, or nil when the host has no such plugin or it
    /// cannot work (no Deepgram key).
    public func deepgramLive() async -> DeepgramLiveSettings? {
        guard let json = try? await request("api/plugins/deepgram-live/status", method: "GET", body: nil) else { return nil }
        return DeepgramLiveSettings(status: json)
    }

    /// A Deepgram socket, opened with a short-lived token from the plugin. The token rides in the
    /// WebSocket protocol header, as Deepgram expects from a client without its own key.
    public func deepgramSocket(_ url: URL) async throws -> URLSessionWebSocketTask {
        let auth = try await post("api/plugins/deepgram-live/auth", body: [:])
        guard let scheme = auth["scheme"] as? String, let value = auth["value"] as? String, !value.isEmpty else {
            throw AgentError.emptyReply
        }
        let task = session.webSocketTask(with: url, protocols: [scheme, value])
        task.resume()
        return task
    }

    /// True when the host has the `screen-remote` plugin, which can lock the agent's screen tools.
    public func canHoldScreen() async -> Bool {
        (try? await request("api/plugins/screen-remote/status", method: "GET", body: nil)) != nil
    }

    /// Lock or unlock the agent's screen tools. While locked, every screen tool call is refused
    /// and the refusal tells the agent why, so it waits.
    public func holdScreen(_ held: Bool, reason: String = "") async throws {
        _ = try await post("api/plugins/screen-remote/hold", body: ["held": held, "reason": reason])
    }

    /// Connect once, and again after a 401: the backend may have restarted with a new token.
    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(path, method: "POST", body: body)
    }

    private func request(_ path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        if !connected {
            try await connect()
        }
        var (data, status) = try await send(path, method: method, body: body)
        if status == 401 {
            try await connect()
            (data, status) = try await send(path, method: method, body: body)
        }
        guard (200..<300).contains(status) else { throw AgentError.http(status, String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func send(_ path: String, method: String = "POST", body: [String: Any]?) async throws -> (Data, Int) {
        var request = URLRequest(url: settings.url.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("brah", forHTTPHeaderField: "X-Requested-With")
        settings.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// 16-bit mono PCM samples as a WAV file, the format every speech provider takes.
public enum WAV {
    public static func file(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
