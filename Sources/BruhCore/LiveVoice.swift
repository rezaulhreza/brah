import Foundation

/// Live words while the user talks: microphone PCM goes to `transcribe-stream`, partial text comes
/// back. When the provider has no live mode the socket says so, and `finish` returns nil: the
/// caller then sends the whole recording to `/api/audio/transcribe`.
public final class LiveTranscriber: @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var final: CheckedContinuation<String?, Never>?
    private var result: String??
    public var onPartial: @Sendable (String) -> Void = { _ in }

    public init(socket: URLSessionWebSocketTask, sampleRate: Int) {
        self.socket = socket
        socket.send(.string(#"{"sample_rate": \#(sampleRate)}"#)) { _ in }
        receive()
    }

    /// 16-bit little-endian mono samples.
    public func send(_ samples: [Int16]) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        socket.send(.data(data)) { _ in }
    }

    /// The final words, or nil when live transcription failed. Waits at most `timeout` seconds.
    public func finish(timeout: Double = 10) async -> String? {
        socket.send(.string(#"{"eos": true}"#)) { _ in }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.settle(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            lock.withLock {
                if let result {
                    continuation.resume(returning: result)
                } else {
                    final = continuation
                }
            }
        }
    }

    public func cancel() {
        socket.cancel(with: .goingAway, reason: nil)
        settle(nil)
    }

    private func settle(_ value: String?) {
        let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = .some(value)
            defer { final = nil }
            return final
        }
        waiting?.resume(returning: value)
    }

    private func receive() {
        socket.receive { [weak self] message in
            guard let self else { return }
            guard case .success(.string(let text)) = message,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else {
                if case .failure = message {
                    self.settle(nil)
                    return
                }
                self.receive()
                return
            }

            switch json["type"] as? String {
            case "partial":
                self.onPartial(json["text"] as? String ?? "")
                self.receive()
            case "final":
                self.settle((json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                self.socket.cancel(with: .normalClosure, reason: nil)
            case "error":
                self.settle(nil)
                self.socket.cancel(with: .normalClosure, reason: nil)
            default:
                self.receive()
            }
        }
    }
}

/// Live speech while the answer arrives: text goes to `speak-stream`, PCM comes back sentence by
/// sentence. `stop` is barge-in: the server stops at once.
public final class LiveSpeech: @unchecked Sendable {
    public enum Event: Sendable {
        case start(sampleRate: Double)
        case pcm(Data)
        /// The server made no sound. Say the whole answer another way.
        case fallback
        case end
    }

    private let socket: URLSessionWebSocketTask
    private let onEvent: @Sendable (Event) -> Void

    public init(socket: URLSessionWebSocketTask, onEvent: @escaping @Sendable (Event) -> Void) {
        self.socket = socket
        self.onEvent = onEvent
        receive()
    }

    public func feed(_ text: String) {
        guard !text.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    public func done() {
        socket.send(.string(#"{"done": true}"#)) { _ in }
    }

    public func stop() {
        socket.send(.string(#"{"stop": true}"#)) { [socket] _ in socket.cancel(with: .normalClosure, reason: nil) }
    }

    private func receive() {
        socket.receive { [weak self] message in
            guard let self else { return }
            switch message {
            case .failure:
                return
            case .success(.data(let data)):
                self.onEvent(.pcm(data))
            case .success(.string(let text)):
                let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
                switch json["type"] as? String {
                case "start":
                    self.onEvent(.start(sampleRate: (json["sample_rate"] as? NSNumber)?.doubleValue ?? 24_000))
                case "fallback":
                    self.onEvent(.fallback)
                case "end":
                    self.onEvent(.end)
                    self.socket.cancel(with: .normalClosure, reason: nil)
                    return
                default:
                    break
                }
            case .success:
                break
            }
            self.receive()
        }
    }
}
