import AVFoundation
import BrahCore
import Speech

/// Records the microphone as 16 kHz mono, the rate speech providers expect, from the shared
/// audio engine.
final class Recorder {
    static let sampleRate = 16_000.0

    private let lock = NSLock()
    private var samples: [Int16] = []
    private var listener: UUID?
    private var live: (([Int16]) -> Void)?

    static func allowed() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Send everything recorded so far to `live`, then every new chunk as it comes.
    func attach(_ live: @escaping ([Int16]) -> Void) {
        lock.withLock {
            live(samples)
            self.live = live
        }
    }

    func start() throws {
        lock.withLock {
            samples = []
            live = nil
        }
        try AudioIO.shared.acquire()
        let converter = PCM16Converter(sampleRate: Self.sampleRate)
        listener = AudioIO.shared.listen { [weak self] buffer in
            guard let self else { return }
            let chunk = converter.convert(buffer)
            self.lock.withLock {
                self.samples.append(contentsOf: chunk)
                self.live?(chunk)
            }
        }
    }

    /// The recording as a WAV file, and the number of seconds in it.
    func stop() -> (wav: Data, seconds: Double) {
        lock.withLock { live = nil }
        if let listener {
            AudioIO.shared.unlisten(listener)
            AudioIO.shared.release()
            self.listener = nil
        }
        let taken = lock.withLock { samples }
        return (WAV.file(samples: taken, sampleRate: Int(Self.sampleRate)), Double(taken.count) / Self.sampleRate)
    }
}

/// The two voice routes. Hermes first: it uses the speech providers the user chose in Hermes,
/// live when the provider can stream. The Mac's own speech engines are the fallback, for a user
/// with no Hermes voice.
@MainActor
final class Voice {
    private let hermes: HermesVoice?
    /// The user's own live voice in Hermes, when the host has the `deepgram-live` plugin.
    private let deepgram: DeepgramLiveSettings?
    private let system = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var sampleRate = Double(DeepgramLiveSettings.outputSampleRate)
    /// This voice holds the shared audio engine while it plays.
    private var usingAudio = false
    private var echo = EchoGuard()
    private var speaking: Task<Void, Never>?
    private var reply: LiveReply?
    var log: (String) -> Void = { _ in }

    init(hermes: HermesVoice?, deepgram: DeepgramLiveSettings? = nil) {
        self.hermes = hermes
        self.deepgram = hermes == nil ? nil : deepgram
        AudioIO.shared.onDrained = { [weak self] in MainActor.assumeIsolated { self?.drained() } }
    }

    /// Brah is talking, or about to.
    var isSpeaking: Bool {
        AudioIO.shared.isPlaying || system.isSpeaking || player?.isPlaying == true || (reply?.isOpen ?? false)
    }

    /// The words are Brah's own voice coming back through the microphone.
    func isEcho(_ transcript: String) -> Bool {
        echo.isEcho(transcript)
    }

    var hasLiveTurns: Bool { deepgram != nil }

    /// Turns of a hands-free conversation, from Flux. Nil without the deepgram-live plugin.
    func turns(onTurn: @escaping @MainActor (TurnEvent) -> Void) async -> DeepgramListen? {
        guard let hermes, let deepgram else { return nil }
        do {
            let listen = DeepgramListen(socket: try await hermes.deepgramSocket(deepgram.listenURL(sampleRate: Int(Recorder.sampleRate))))
            listen.onTurn = { event in DispatchQueue.main.async { MainActor.assumeIsolated { onTurn(event) } } }
            return listen
        } catch {
            log("live turns not available: \(error.localizedDescription)")
            return nil
        }
    }

    private func useAudio() {
        guard !usingAudio else { return }
        do {
            try AudioIO.shared.acquire()
            usingAudio = true
        } catch {
            log("audio engine failed: \(error.localizedDescription)")
        }
    }

    private func drained() {
        guard usingAudio, reply == nil || reply?.isOpen == false else { return }
        usingAudio = false
        AudioIO.shared.release()
    }

    var route: String {
        if let deepgram { return "Deepgram Live, \(deepgram.voice)" }
        return hermes == nil ? "Mac voice" : "Hermes voice"
    }

    // MARK: Listening

    /// Live words while the user talks, or nil when there is no live route.
    func listen(to recorder: Recorder, onPartial: @escaping @MainActor (String) -> Void) async -> WordStream? {
        guard let hermes else { return nil }
        do {
            let live: WordStream
            if let deepgram {
                live = DeepgramListen(socket: try await hermes.deepgramSocket(deepgram.listenURL(sampleRate: Int(Recorder.sampleRate))))
            } else {
                live = LiveTranscriber(socket: try await hermes.socket("api/audio/transcribe-stream"), sampleRate: Int(Recorder.sampleRate))
            }
            live.onPartial = { text in DispatchQueue.main.async { MainActor.assumeIsolated { onPartial(text) } } }
            recorder.attach { [live] samples in live.send(samples) }
            return live
        } catch {
            log("live transcription not available: \(error.localizedDescription)")
            return nil
        }
    }

    /// The words of a finished recording: the live result when there is one, else the whole file.
    func words(live: WordStream?, wav: Data) async throws -> String {
        if let live, let words = await live.finish(timeout: 6) {
            log("live transcript")
            return words
        }
        if let hermes {
            do {
                return try await hermes.transcribe(wav: wav)
            } catch {
                log("Hermes transcription failed, using the Mac: \(error.localizedDescription)")
            }
        }
        return try await MacSpeech.transcribe(wav)
    }

    // MARK: Speaking

    /// Start a spoken reply. Feed it pieces with `replyPiece` and close it with `endReply`.
    func beginReply() {
        stop()
        guard let hermes else { return }
        let reply = LiveReply()
        self.reply = reply
        Task {
            do {
                let onEvent: @Sendable (SpeechEvent) -> Void = { [weak self] event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, of: reply) } }
                }
                let socket = if let deepgram {
                    try await hermes.deepgramSocket(deepgram.speakURL())
                } else {
                    try await hermes.socket("api/audio/speak-stream")
                }
                guard self.reply === reply else {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                reply.open(deepgram == nil ? LiveSpeech(socket: socket, onEvent: onEvent) : DeepgramSpeech(socket: socket, onEvent: onEvent))
            } catch {
                log("live speech not available: \(error.localizedDescription)")
                reply.failed = true
                // The answer may already be complete: say it the other way now.
                if self.reply === reply, let text = reply.text {
                    self.reply = nil
                    sayWhole(text)
                }
            }
        }
    }

    func replyPiece(_ piece: String) {
        guard let reply else { return }
        let words = reply.filter.feed(piece)
        echo.spoke(words)
        reply.feed(words)
    }

    /// The answer is complete. `text` is said another way when live speech made no sound.
    func endReply(_ text: String) {
        guard let reply else {
            say(text)
            return
        }
        reply.text = text
        let rest = reply.filter.finish()
        echo.spoke(rest)
        reply.feed(rest)
        reply.finish()
        if reply.failed {
            self.reply = nil
            sayWhole(text)
        }
    }

    private func handle(_ event: SpeechEvent, of reply: LiveReply) {
        guard self.reply === reply else { return }
        switch event {
        case .start(let rate):
            log("speaking live (\(route)) at \(Int(rate)) Hz")
            sampleRate = rate
            useAudio()
        case .pcm(let data):
            useAudio()
            AudioIO.shared.play(data, sampleRate: sampleRate)
        case .fallback:
            log("live speech made no sound, saying it another way")
            self.reply = nil
            if let text = reply.text { sayWhole(text) }
        case .end:
            reply.isOpen = false
            if !AudioIO.shared.isPlaying { drained() }
        }
    }

    /// A whole text. The Hermes live stream first, because it sends raw PCM, which always plays.
    func say(_ text: String) {
        guard hermes != nil else {
            stop()
            sayWithMac(text)
            return
        }
        beginReply()
        replyPiece(text)
        endReply(text)
    }

    /// The last resorts: the Hermes file route, then the Mac. The file can be a format macOS does
    /// not play (Ogg Opus from some providers); then the Mac speaks.
    private func sayWhole(_ text: String) {
        speaking?.cancel()
        speaking = Task {
            if let hermes {
                do {
                    let sound = try await hermes.speak(text)
                    guard !Task.isCancelled else { return }
                    let player = try AVAudioPlayer(data: sound.data)
                    if player.play() {
                        self.player = player
                        log("speaking with Hermes (\(sound.mimeType))")
                        return
                    }
                    log("cannot play \(sound.mimeType), using the Mac voice")
                } catch {
                    guard !Task.isCancelled else { return }
                    log("Hermes speech failed, using the Mac voice: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            sayWithMac(text)
        }
    }

    private func sayWithMac(_ text: String) {
        echo.spoke(text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: SpeechSettings.load()) ?? Self.bestMacVoice
        system.speak(utterance)
    }

    /// The most natural installed voice for the user's language: Premium, then Enhanced. More
    /// can be added in System Settings > Accessibility > Spoken Content > System Voice.
    static let bestMacVoice: AVSpeechSynthesisVoice? = macVoices.first ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())

    /// The installed voices for the user's language, best first.
    static var macVoices: [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            if (lhs.language == language) != (rhs.language == language) { return lhs.language == language }
            return lhs.name < rhs.name
        }
    }

    /// Silence now. A live reply is told to stop, so the server stops making sound.
    func stop() {
        reply?.stop()
        reply = nil
        speaking?.cancel()
        speaking = nil
        player?.stop()
        player = nil
        AudioIO.shared.stopPlayback()
        system.stopSpeaking(at: .immediate)
        if usingAudio {
            usingAudio = false
            AudioIO.shared.release()
        }
    }
}

/// One live reply: text waits here until the socket is open.
@MainActor
private final class LiveReply {
    var filter = SpokenText()
    var text: String?
    var failed = false
    /// More sound may still come.
    var isOpen = true
    private var speech: SpeechStream?
    private var queue: [String] = []
    private var finished = false

    func open(_ speech: SpeechStream) {
        self.speech = speech
        queue.forEach(speech.feed)
        queue = []
        if finished { speech.done() }
    }

    func feed(_ text: String) {
        guard !text.isEmpty else { return }
        if let speech { speech.feed(text) } else { queue.append(text) }
    }

    func finish() {
        finished = true
        speech?.done()
    }

    func stop() {
        speech?.stop()
        speech = nil
        queue = []
    }
}

/// Speech recognition of macOS.
enum MacSpeech {
    enum Failure: LocalizedError {
        case notAllowed, unavailable

        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Brah needs Speech Recognition. Allow it in System Settings > Privacy & Security > Speech Recognition."
            case .unavailable: return "Speech recognition of the Mac is not available now."
            }
        }
    }

    static func transcribe(_ wav: Data) async throws -> String {
        let status = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw Failure.unavailable }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("brah-\(UUID().uuidString).wav")
        try wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { done in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    done.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    finished = true
                    // "No speech detected" arrives as an error.
                    (error as NSError).code == 1110 ? done.resume(returning: "") : done.resume(throwing: error)
                }
            }
        }
    }
}
