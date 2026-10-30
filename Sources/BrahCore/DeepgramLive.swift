import Foundation

/// The `deepgram-live` Hermes plugin: the live voice the user chose for Hermes. The plugin keeps
/// the Deepgram key on the host and hands out tokens that last 30 seconds. Brah then talks to
/// Deepgram directly, the same way the Hermes desktop app does, with the user's voice and models.
public struct DeepgramLiveSettings: Equatable, Sendable {
    public var voice: String
    public var listenModel: String
    public var eotThreshold: Double
    public var eotTimeoutMs: Int
    public var speed: Double
    public var keyterms: [String]
    public var mipOptOut: Bool

    static let speakURL = URL(string: "wss://api.deepgram.com/v1/speak")!
    static let listenURL = URL(string: "wss://api.deepgram.com/v2/listen")!
    public static let outputSampleRate = 24_000

    /// From `GET /api/plugins/deepgram-live/status`. Nil when the plugin says it cannot work.
    public init?(status: [String: Any]) {
        guard status["available"] as? Bool == true, let voice = status["voice"] as? String, !voice.isEmpty else { return nil }
        self.voice = voice
        listenModel = status["listen_model"] as? String ?? "flux-general-en"
        eotThreshold = (status["eot_threshold"] as? NSNumber)?.doubleValue ?? 0.7
        eotTimeoutMs = (status["eot_timeout_ms"] as? NSNumber)?.intValue ?? 3000
        speed = (status["speed"] as? NSNumber)?.doubleValue ?? 1
        keyterms = status["keyterms"] as? [String] ?? []
        mipOptOut = status["mip_opt_out"] as? Bool ?? true
    }

    public func speakURL() -> URL {
        var items = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "mip_opt_out", value: String(mipOptOut)),
            URLQueryItem(name: "model", value: voice),
            URLQueryItem(name: "sample_rate", value: String(Self.outputSampleRate)),
        ]
        if speed != 1 {
            items.append(URLQueryItem(name: "speed", value: String(speed)))
        }
        return Self.url(Self.speakURL, items)
    }

    public func listenURL(sampleRate: Int) -> URL {
        var items = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "eot_threshold", value: String(eotThreshold)),
            URLQueryItem(name: "eot_timeout_ms", value: String(eotTimeoutMs)),
            URLQueryItem(name: "mip_opt_out", value: String(mipOptOut)),
            URLQueryItem(name: "model", value: listenModel),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
        ]
        items += keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
        return Self.url(Self.listenURL, items)
    }

    private static func url(_ base: URL, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }
}

/// What a live voice reports while it speaks.
public enum SpeechEvent: Sendable {
    case start(sampleRate: Double)
    case pcm(Data)
    /// No sound came. Say the whole answer another way.
    case fallback
    case end
}

/// A live voice for one answer: text in while the answer arrives, sound out.
public protocol SpeechStream: AnyObject, Sendable {
    func feed(_ text: String)
    func done()
    /// Barge-in: silence at once.
    func stop()
}

/// Live words while the user talks.
public protocol WordStream: AnyObject, Sendable {
    var onPartial: @Sendable (String) -> Void { get set }
    func send(_ samples: [Int16])
    /// The final words, or nil when the live route failed.
    func finish(timeout: Double) async -> String?
    func cancel()
}

/// Deepgram Aura over its speak socket. Text is sent in whole sentences. Deepgram limits how
/// often `Flush` may be sent, so the first sentence is flushed at once and later ones at most
/// every 3.2 seconds, as the plugin's desktop half does.
public final class DeepgramSpeech: SpeechStream, @unchecked Sendable {
    static let flushInterval = 3.2
    static let textLimit = 1000

    private let socket: URLSessionWebSocketTask
    private let onEvent: @Sendable (SpeechEvent) -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "brah.deepgram.speak")
    private var pending = ""
    private var unflushed = false
    private var lastFlush = Date.distantPast
    private var flushWaiting = false
    private var outstanding = 0
    private var finished = false
    private var started = false
    private var over = false

    public init(socket: URLSessionWebSocketTask, onEvent: @escaping @Sendable (SpeechEvent) -> Void) {
        self.socket = socket
        self.onEvent = onEvent
        receive()
    }

    public func feed(_ text: String) {
        let ready: String = lock.withLock {
            pending += text
            let (whole, rest) = Self.sentences(pending)
            pending = rest
            return whole
        }
        speak(ready)
    }

    public func done() {
        let rest: String = lock.withLock {
            finished = true
            defer { pending = "" }
            return pending
        }
        speak(rest)
        lock.withLock { unflushed = true }
        scheduleFlush()
    }

    public func stop() {
        lock.withLock { over = true }
        send(["type": "Clear"])
        send(["type": "Close"])
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Whole sentences, and the text after the last one. A sentence ends at . ! ? or a line
    /// break, followed by white space: "3.5" is not an end.
    static func sentences(_ text: String) -> (String, String) {
        var cut: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if "\n".contains(text[index]) || (".!?".contains(text[index]) && next < text.endIndex && text[next].isWhitespace) {
                cut = next
            }
            index = next
        }
        guard let cut else { return ("", text) }
        return (String(text[..<cut]), String(text[cut...]))
    }

    private func speak(_ text: String) {
        let line = Phrases.spoken(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        var start = line.startIndex
        while start < line.endIndex {
            let end = line.index(start, offsetBy: Self.textLimit, limitedBy: line.endIndex) ?? line.endIndex
            send(["type": "Speak", "text": String(line[start..<end])])
            start = end
        }
        lock.withLock { unflushed = true }
        scheduleFlush()
    }

    private func scheduleFlush() {
        let wait: Double? = lock.withLock {
            guard unflushed, !flushWaiting, !over else { return nil }
            let wait = lastFlush.addingTimeInterval(Self.flushInterval).timeIntervalSinceNow
            if wait > 0 {
                flushWaiting = true
                return wait
            }
            unflushed = false
            lastFlush = Date()
            outstanding += 1
            return 0
        }
        guard let wait else { return }
        if wait > 0 {
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.lock.withLock { self?.flushWaiting = false }
                self?.scheduleFlush()
            }
        } else {
            send(["type": "Flush"])
        }
    }

    private func send(_ message: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive() {
        socket.receive { [weak self] message in
            guard let self else { return }
            switch message {
            case .failure:
                let silent = self.lock.withLock { !self.started && !self.over }
                if silent { self.onEvent(.fallback) }
                return
            case .success(.data(let data)):
                let first = self.lock.withLock { () -> Bool in
                    defer { self.started = true }
                    return !self.started
                }
                if first { self.onEvent(.start(sampleRate: Double(DeepgramLiveSettings.outputSampleRate))) }
                self.onEvent(.pcm(data))
            case .success(.string(let text)):
                let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
                if json["type"] as? String == "Flushed" {
                    let ended = self.lock.withLock { () -> Bool in
                        self.outstanding = max(0, self.outstanding - 1)
                        return self.finished && self.outstanding == 0 && !self.unflushed && !self.flushWaiting
                    }
                    if ended {
                        self.onEvent(.end)
                        self.send(["type": "Close"])
                    }
                }
            case .success:
                break
            }
            self.receive()
        }
    }
}

/// Deepgram Flux over its listen socket. Flux reports each turn as it grows; a hold of the
/// hotkey can hold more than one turn when the user pauses, so the turns are joined.
public final class DeepgramListen: WordStream, @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var done: [String] = []
    private var current = ""
    private var heard = false
    private var result: String??
    private var waiting: CheckedContinuation<String?, Never>?
    public var onPartial: @Sendable (String) -> Void = { _ in }
    /// Each turn as Flux reports it, for a hands-free conversation.
    public var onTurn: @Sendable (TurnEvent) -> Void = { _ in }

    public init(socket: URLSessionWebSocketTask) {
        self.socket = socket
        receive()
    }

    /// Close the socket without waiting for words.
    public func close() {
        socket.send(.string(#"{"type": "CloseStream"}"#)) { _ in }
        socket.cancel(with: .normalClosure, reason: nil)
        settle()
    }

    public func send(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        socket.send(.data(samples.withUnsafeBufferPointer { Data(buffer: $0) })) { _ in }
    }

    public func finish(timeout: Double = 4) async -> String? {
        socket.send(.string(#"{"type": "CloseStream"}"#)) { _ in }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.settle()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let ready: String?? = lock.withLock {
                if let result { return result }
                waiting = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    public func cancel() {
        socket.cancel(with: .goingAway, reason: nil)
        settle()
    }

    private var words: String {
        (done + [current]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The words so far. Nil when the socket never answered: the caller then uses the recording.
    private func settle() {
        let (continuation, value): (CheckedContinuation<String?, Never>?, String?) = lock.withLock {
            guard result == nil else { return (nil, nil) }
            let value: String? = heard ? words : nil
            result = .some(value)
            defer { waiting = nil }
            return (waiting, value)
        }
        continuation?.resume(returning: value)
    }

    private func receive() {
        socket.receive { [weak self] message in
            guard let self else { return }
            guard case .success(let frame) = message else {
                self.settle()
                return
            }
            if case .string(let text) = frame,
               let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                self.lock.withLock { self.heard = true }
                if json["type"] as? String == "TurnInfo" {
                    let transcript = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    switch json["event"] as? String {
                    case "StartOfTurn": self.onTurn(.started)
                    case "Update": self.onTurn(.update(transcript))
                    case "EndOfTurn": self.onTurn(.ended(transcript))
                    default: break
                    }
                    let partial: String = self.lock.withLock {
                        if json["event"] as? String == "EndOfTurn" {
                            if !transcript.isEmpty { self.done.append(transcript) }
                            self.current = ""
                        } else {
                            self.current = transcript
                        }
                        return self.words
                    }
                    self.onPartial(partial)
                }
            }
            self.receive()
        }
    }
}
