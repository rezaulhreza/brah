import AVFoundation
import BrahCore
import Speech

enum SpeechAccess {
    /// Speech recognition that stays on this Mac, or the reason there is none.
    static func onDeviceRecognizer() async -> Result<SFSpeechRecognizer, ListeningError> {
        let status = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard status == .authorized else { return .failure(.notAllowed) }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return .failure(.noOnDevice) }
        return .success(recognizer)
    }
}

enum ListeningError: LocalizedError {
    case notAllowed, noOnDevice

    var errorDescription: String? {
        switch self {
        case .notAllowed: return "Brah needs Speech Recognition for \"Hey Brah\". Allow it in System Settings > Privacy & Security > Speech Recognition."
        case .noOnDevice: return "This Mac has no on-device speech recognition for your language, so Brah cannot listen for \"Hey Brah\" without sending audio away."
        }
    }
}

/// One on-device recognition request at a time, fed from the shared microphone. Apple limits a
/// request to about a minute, so the owner starts a new one often.
private final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replace(with request: SFSpeechAudioBufferRecognitionRequest?) {
        let old = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { self.request = request }
            return self.request
        }
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}

/// Listens on the Mac for "Hey Brah". No audio leaves the Mac.
@MainActor
final class WakeListener {
    private var recognizer: SFSpeechRecognizer?
    private let feed = RecognitionFeed()
    private var task: SFSpeechRecognitionTask?
    private var listener: UUID?
    private var restart: Timer?
    private var onWake: () -> Void = {}
    private(set) var isRunning = false

    /// Start listening. Returns why it cannot, or nil.
    func start(onWake: @escaping () -> Void) async -> String? {
        guard !isRunning else { return nil }
        switch await SpeechAccess.onDeviceRecognizer() {
        case .failure(let error): return error.localizedDescription
        case .success(let recognizer): self.recognizer = recognizer
        }
        do {
            try AudioIO.shared.acquire()
        } catch {
            return "The microphone did not start: \(error.localizedDescription)"
        }
        self.onWake = onWake
        isRunning = true
        listener = AudioIO.shared.listen { [feed] buffer in feed.append(buffer) }
        begin()
        return nil
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restart?.invalidate()
        task?.cancel()
        task = nil
        feed.replace(with: nil)
        if let listener {
            AudioIO.shared.unlisten(listener)
            AudioIO.shared.release()
            self.listener = nil
        }
    }

    private func begin() {
        guard isRunning, let recognizer else { return }
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .search
        feed.replace(with: request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString ?? ""
            let over = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    if Phrases.hasWakeWord(heard) {
                        self.begin()
                        self.onWake()
                    } else if over {
                        self.begin()
                    }
                }
            }
        }
        restart?.invalidate()
        restart = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        }
    }
}

/// Where the turns of a hands-free conversation come from.
protocol LiveTurns: AnyObject {
    /// A microphone buffer, on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer)
    func close()
}

/// Turns from Deepgram Flux through the deepgram-live plugin: it hears when the user is done.
final class FluxTurns: LiveTurns, @unchecked Sendable {
    private let listen: DeepgramListen
    private let converter: PCM16Converter

    init(_ listen: DeepgramListen) {
        self.listen = listen
        converter = PCM16Converter(sampleRate: Recorder.sampleRate)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        listen.send(converter.convert(buffer))
    }

    func close() {
        listen.close()
    }
}

/// Turns from the Mac's on-device recognition, for a user without the plugin. A turn ends after
/// a short silence.
@MainActor
final class MacTurns: LiveTurns {
    static let silence: TimeInterval = 1.3

    private let recognizer: SFSpeechRecognizer
    private let feedBox = RecognitionFeed()
    private let onTurn: (TurnEvent) -> Void
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var changed = Date()
    private var startedAt = Date()
    private var timer: Timer?
    private var open = true

    init(recognizer: SFSpeechRecognizer, onTurn: @escaping (TurnEvent) -> Void) {
        self.recognizer = recognizer
        self.onTurn = onTurn
        begin()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        feedBox.append(buffer)
    }

    nonisolated func close() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.open = false
                self.timer?.invalidate()
                self.task?.cancel()
                self.feedBox.replace(with: nil)
            }
        }
    }

    private func begin() {
        guard open else { return }
        task?.cancel()
        heard = ""
        startedAt = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        feedBox.replace(with: request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.heard(text) }
            }
        }
    }

    private func heard(_ text: String) {
        guard open, text != heard, !text.isEmpty else { return }
        if heard.isEmpty { onTurn(.started) }
        heard = text
        changed = Date()
        onTurn(.update(text))
    }

    private func tick() {
        guard open else { return }
        if !heard.isEmpty, Date().timeIntervalSince(changed) > Self.silence {
            let turn = heard
            begin()
            onTurn(.ended(turn))
        } else if heard.isEmpty, Date().timeIntervalSince(startedAt) > 45 {
            begin()
        }
    }
}

/// A hands-free conversation: the microphone stays open and every finished turn is a question.
@MainActor
final class Conversation {
    private(set) var turns: LiveTurns?
    private var listener: UUID?
    var lastActivity = Date()
    var timer: Timer?

    func attach(_ turns: LiveTurns) throws {
        try AudioIO.shared.acquire()
        self.turns = turns
        listener = AudioIO.shared.listen { [turns] buffer in turns.feed(buffer) }
    }

    func close() {
        timer?.invalidate()
        if let listener {
            AudioIO.shared.unlisten(listener)
            AudioIO.shared.release()
            self.listener = nil
        }
        turns?.close()
        turns = nil
    }
}
