import Foundation

/// The Hermes web backend, which owns the voice. Its audio routes use the speech providers the
/// user chose in Hermes (Deepgram, ElevenLabs, Edge, local Whisper and others), so Bruh needs no
/// speech account of its own.
public struct HermesVoiceSettings: Equatable, Sendable {
    public var url: URL
    public var username: String?
    public var password: String?

    public init(url: URL, username: String? = nil, password: String? = nil) {
        self.url = url
        self.username = username
        self.password = password
    }

    /// The port of `hermes dashboard`.
    public static let defaultURL = URL(string: "http://127.0.0.1:9119")!

    /// The environment first, then `voice` in the `hermes` object of `~/.config/bruh/config.json`:
    /// `{"hermes": {"voice": {"url": "...", "username": "...", "password": "..."}}}`.
    /// The sign-in is only for a dashboard that asks for one.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HermesVoiceSettings {
        let voice = HermesSettings.configSection(home: home)?["voice"] as? [String: Any]
        let url = environment["BRUH_HERMES_VOICE_URL"].flatMap(URL.init(string:))
            ?? (voice?["url"] as? String).flatMap(URL.init(string:))
        let username = environment["BRUH_HERMES_USERNAME"] ?? voice?["username"] as? String
        let password = environment["BRUH_HERMES_PASSWORD"] ?? voice?["password"] as? String
        return HermesVoiceSettings(url: url ?? defaultURL,
                                   username: username?.isEmpty == false ? username : nil,
                                   password: password?.isEmpty == false ? password : nil)
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
    /// How the backend let Bruh in: its session token, or a cookie from the password sign-in.
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

        if let (data, response) = try? await session.data(from: settings.url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let found = HermesVoiceSettings.pageToken(String(decoding: data, as: UTF8.self)) {
            token = found
            connected = true
            return
        }

        guard let username = settings.username, let password = settings.password else {
            throw AgentError.notConfigured(
                "The Hermes dashboard at \(settings.url.absoluteString) asks for a sign-in. Add hermes.voice.username and hermes.voice.password to ~/.config/bruh/config.json.")
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
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }

    /// Connect once, and again after a 401: the backend may have restarted with a new token.
    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        if !connected {
            try await connect()
        }
        var (data, status) = try await send(path, body: body)
        if status == 401 {
            try await connect()
            (data, status) = try await send(path, body: body)
        }
        guard (200..<300).contains(status) else { throw AgentError.http(status, String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func send(_ path: String, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: settings.url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("bruh", forHTTPHeaderField: "X-Requested-With")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
