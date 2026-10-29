import Foundation

/// The Hermes web backend, which owns the voice. Its audio routes use the speech providers the
/// user chose in Hermes (Deepgram, ElevenLabs, Edge, local Whisper and others), so Bruh needs no
/// speech account of its own. The backend wants the same sign-in as the Hermes phone app.
public struct HermesVoiceSettings: Equatable, Sendable {
    public var url: URL
    public var username: String
    public var password: String

    public init(url: URL, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    public static let defaultURL = URL(string: "http://127.0.0.1:9130")!

    /// The environment first, then `voice` in the `hermes` object of `~/.config/bruh/config.json`:
    /// `{"hermes": {"voice": {"url": "...", "username": "...", "password": "..."}}}`.
    /// No username and password means no Hermes voice: Bruh then uses the voice of the Mac.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HermesVoiceSettings? {
        let voice = HermesSettings.configSection(home: home)?["voice"] as? [String: Any]
        let url = environment["BRUH_HERMES_VOICE_URL"].flatMap(URL.init(string:))
            ?? (voice?["url"] as? String).flatMap(URL.init(string:))
        guard let username = environment["BRUH_HERMES_USERNAME"] ?? voice?["username"] as? String,
              let password = environment["BRUH_HERMES_PASSWORD"] ?? voice?["password"] as? String,
              !username.isEmpty, !password.isEmpty
        else { return nil }
        return HermesVoiceSettings(url: url ?? defaultURL, username: username, password: password)
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
    private var signedIn = false

    public init(settings: HermesVoiceSettings) {
        self.settings = settings
        // Its own cookie jar: the backend keeps the sign-in in a cookie.
        session = URLSession(configuration: .ephemeral)
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

    /// One sign-in, and one more after a 401: the backend may have restarted and lost the cookie.
    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        if !signedIn {
            try await signIn()
        }
        var (data, status) = try await send(path, body: body)
        if status == 401 {
            try await signIn()
            (data, status) = try await send(path, body: body)
        }
        guard (200..<300).contains(status) else { throw AgentError.http(status, String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func signIn() async throws {
        let body = ["provider": "basic", "username": settings.username, "password": settings.password, "next": "/"]
        let (data, status) = try await send("auth/password-login", body: body)
        guard (200..<300).contains(status) else {
            signedIn = false
            throw AgentError.http(status, "Hermes refused the voice sign-in. \(String(decoding: data, as: UTF8.self))")
        }
        signedIn = true
    }

    private func send(_ path: String, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: settings.url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("bruh", forHTTPHeaderField: "X-Requested-With")
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
