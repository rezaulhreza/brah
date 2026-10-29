import AVFoundation
import BruhCore
import Speech

/// Records the microphone as 16 kHz mono, the rate speech providers expect.
final class Recorder {
    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var running = false
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw CocoaError(.featureUnsupported) }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, target: target)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    /// The recording as a WAV file, and the number of seconds in it.
    func stop() -> (wav: Data, seconds: Double) {
        lock.withLock { live = nil }
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        let taken = lock.withLock { samples }
        return (WAV.file(samples: taken, sampleRate: Int(Self.sampleRate)), Double(taken.count) / Self.sampleRate)
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }

        guard let channel = out.int16ChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        lock.withLock {
            samples.append(contentsOf: chunk)
            live?(chunk)
        }
    }
}

/// The two voice routes. Hermes first: it uses the speech providers the user chose in Hermes,
/// live when the provider can stream. The Mac's own speech engines are the fallback, for a user
/// with no Hermes voice.
@MainActor
final class Voice {
    private let hermes: HermesVoice?
    private let system = AVSpeechSynthesizer()
    private let pcm = PCMPlayer()
    private var player: AVAudioPlayer?
    private var speaking: Task<Void, Never>?
    private var reply: LiveReply?
    var log: (String) -> Void = { _ in }

    init(hermes: HermesVoice?) {
        self.hermes = hermes
    }

    var route: String { hermes == nil ? "Mac voice" : "Hermes voice" }

    // MARK: Listening

    /// Live words while the user talks, or nil when there is no live route.
    func listen(to recorder: Recorder, onPartial: @escaping @MainActor (String) -> Void) async -> LiveTranscriber? {
        guard let hermes else { return nil }
        do {
            let live = LiveTranscriber(socket: try await hermes.socket("api/audio/transcribe-stream"), sampleRate: Int(Recorder.sampleRate))
            live.onPartial = { text in DispatchQueue.main.async { MainActor.assumeIsolated { onPartial(text) } } }
            recorder.attach { [live] samples in live.send(samples) }
            return live
        } catch {
            log("live transcription not available: \(error.localizedDescription)")
            return nil
        }
    }

    /// The words of a finished recording: the live result when there is one, else the whole file.
    func words(live: LiveTranscriber?, wav: Data) async throws -> String {
        if let live, let words = await live.finish() {
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
                let socket = try await hermes.socket("api/audio/speak-stream")
                guard self.reply === reply else {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                reply.open(LiveSpeech(socket: socket) { [weak self] event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, of: reply) } }
                })
            } catch {
                log("live speech not available: \(error.localizedDescription)")
                reply.failed = true
            }
        }
    }

    func replyPiece(_ piece: String) {
        guard let reply else { return }
        reply.feed(reply.filter.feed(piece))
    }

    /// The answer is complete. `text` is said another way when live speech made no sound.
    func endReply(_ text: String) {
        guard let reply else {
            say(text)
            return
        }
        reply.text = text
        reply.feed(reply.filter.finish())
        reply.finish()
        if reply.failed {
            self.reply = nil
            say(text)
        }
    }

    private func handle(_ event: LiveSpeech.Event, of reply: LiveReply) {
        guard self.reply === reply else { return }
        switch event {
        case .start(let rate):
            log("speaking live with Hermes at \(Int(rate)) Hz")
            pcm.start(sampleRate: rate)
        case .pcm(let data):
            pcm.play(data)
        case .fallback:
            log("live speech made no sound, saying it another way")
            self.reply = nil
            if let text = reply.text { say(text) }
        case .end:
            break
        }
    }

    /// The whole text at once: Hermes when it can, else the Mac.
    func say(_ text: String) {
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
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.bestMacVoice
            system.speak(utterance)
        }
    }

    /// The most natural installed voice for the user's language: Premium, then Enhanced. More
    /// can be added in System Settings > Accessibility > Spoken Content > System Voice.
    static let bestMacVoice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let ranked = voices.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return (lhs.language == language ? 1 : 0) > (rhs.language == language ? 1 : 0)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }()

    /// Silence now. A live reply is told to stop, so the server stops making sound.
    func stop() {
        reply?.stop()
        reply = nil
        speaking?.cancel()
        speaking = nil
        player?.stop()
        player = nil
        pcm.stop()
        system.stopSpeaking(at: .immediate)
    }
}

/// One live reply: text waits here until the socket is open.
@MainActor
private final class LiveReply {
    var filter = SpokenText()
    var text: String?
    var failed = false
    private var speech: LiveSpeech?
    private var queue: [String] = []
    private var finished = false

    func open(_ speech: LiveSpeech) {
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

/// Plays raw 16-bit mono PCM as it arrives.
@MainActor
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    init() {
        engine.attach(node)
    }

    func start(sampleRate: Double) {
        stop()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return }
        self.format = format
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
        } catch {
            self.format = nil
        }
    }

    func play(_ data: Data) {
        guard let format else { return }
        let count = data.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                channel[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            }
        }
        node.scheduleBuffer(buffer)
    }

    func stop() {
        node.stop()
        engine.stop()
        format = nil
    }
}

/// Speech recognition of macOS.
enum MacSpeech {
    enum Failure: LocalizedError {
        case notAllowed, unavailable

        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Bruh needs Speech Recognition. Allow it in System Settings > Privacy & Security > Speech Recognition."
            case .unavailable: return "Speech recognition of the Mac is not available now."
            }
        }
    }

    static func transcribe(_ wav: Data) async throws -> String {
        let status = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw Failure.unavailable }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bruh-\(UUID().uuidString).wav")
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
