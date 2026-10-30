import AVFoundation

/// The microphone and the voice, shared by everything in Brah. It runs only while something
/// uses it, so the microphone light is off when Brah is idle.
///
/// Echo cancellation comes from `VoiceIO`, Apple's voice processing unit: it knows what the
/// speakers play and takes it out of the microphone, so Brah does not hear itself. When that
/// unit fails, or gives only silence, a plain `AVAudioEngine` without echo cancellation takes
/// over, and the echo check by words keeps Brah from answering its own voice.
final class AudioIO: @unchecked Sendable {
    static let shared = AudioIO()
    static let levelCount = 28

    /// The format of all sound Brah plays: what both backends take.
    private static let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    // The backend: one of the two, while running.
    private var voice: VoiceIO?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// Microphone audio reaches the listeners here, off the real-time thread.
    private let delivery = DispatchQueue(label: "brah.audio.microphone")
    private let lock = NSLock()
    private var listeners: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var converters: [Double: AVAudioConverter] = [:]
    private var users = 0
    private var running = false
    private var stopping: DispatchWorkItem?
    /// Buffers the plain engine still has to play.
    private var queued = 0
    private(set) var echoCancelled = false
    /// Echo cancellation gave only silence once: do not try it again until Brah restarts.
    private var withoutEchoCancellation = ProcessInfo.processInfo.environment["BRAH_NO_ECHO_CANCELLATION"] != nil

    /// The real-time thread writes these, so they have their own lock: it must never wait for
    /// `lock`, which is held while a backend starts.
    private let realTimeLock = NSLock()
    private var inputLevels = [Float](repeating: 0, count: AudioIO.levelCount)
    private var outputLevels = [Float](repeating: 0, count: AudioIO.levelCount)
    private var heardSound = false
    private var soundFrames = 0

    /// Called on the main queue when the last queued sound has played.
    var onDrained: () -> Void = {}
    var log: (String) -> Void = { _ in }
    /// Demo mode: the waveform moves without sound.
    var demoLevels = false

    /// BRAH_AUDIO_DEBUG=1 logs the microphone loudness every two seconds.
    private let debug = ProcessInfo.processInfo.environment["BRAH_AUDIO_DEBUG"] != nil
    private var lastDebug = Date.distantPast

    private init() {}

    /// Sound is queued or playing.
    var isPlaying: Bool {
        if let voice = lock.withLock({ self.voice }) { return voice.isPlaying }
        return lock.withLock { queued > 0 }
    }

    // MARK: Lifetime

    /// Start the microphone and the speaker if they are not running. Pair each call with `release`.
    func acquire() throws {
        try lock.withLock {
            users += 1
            stopping?.cancel()
            stopping = nil
            guard !running else { return }
            if !withoutEchoCancellation {
                do {
                    try startVoiceLocked()
                    return
                } catch {
                    log("echo cancellation did not start (\(error.localizedDescription)); using the microphone without it")
                    withoutEchoCancellation = true
                }
            }
            do {
                try startEngineLocked()
            } catch {
                users -= 1
                throw error
            }
        }
    }

    /// The backend stops a few seconds after its last user, so a quick next use does not wait.
    func release() {
        lock.withLock {
            users = max(0, users - 1)
            guard users == 0, running else { return }
            let work = DispatchWorkItem { [weak self] in self?.stopIfUnused() }
            stopping = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private func startVoiceLocked() throws {
        let unit = VoiceIO()
        unit.onInput = { [weak self] buffer in self?.arrived(buffer) }
        unit.onPlayed = { [weak self] rms in self?.played(rms) }
        unit.onDrained = { [weak self] in self?.onDrained() }
        realTimeLock.withLock {
            heardSound = false
            soundFrames = 0
        }
        try unit.start()
        voice = unit
        echoCancelled = true
        running = true
        log("audio started with echo cancellation (voice processing unit, 48 kHz)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkEchoCancellation() }
    }

    /// A new engine each time: an engine that once had voice processing can stay broken.
    private func startEngineLocked() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playFormat)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.arrived(Self.firstChannel(buffer))
        }
        player.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.played(Self.rms(buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            player.removeTap(onBus: 0)
            throw error
        }
        player.play()
        self.engine = engine
        self.player = player
        echoCancelled = false
        running = true
        log("audio started without echo cancellation, microphone \(input.outputFormat(forBus: 0))")
    }

    /// A room is never at digital zero. Less than half a second of sound in the first 1.5
    /// seconds, or none above the floor, means the voice unit cut the microphone off.
    private func checkEchoCancellation() {
        let (heard, frames) = realTimeLock.withLock { (heardSound, soundFrames) }
        let enough = heard && Double(frames) > VoiceIO.sampleRate * 0.5
        let unit: VoiceIO? = lock.withLock {
            guard running, let voice, !enough else { return nil }
            withoutEchoCancellation = true
            running = false
            self.voice = nil
            return voice
        }
        guard let unit else { return }
        log("echo cancellation gives no sound on this Mac (\(frames) frames, loud: \(heard)); using the microphone without it")
        unit.stop()
        do {
            try lock.withLock { try startEngineLocked() }
        } catch {
            log("the microphone did not start again: \(error.localizedDescription)")
        }
    }

    private func stopIfUnused() {
        let stopped: (VoiceIO?, AVAudioEngine?, AVAudioPlayerNode?)? = lock.withLock {
            guard users == 0, running else { return nil }
            running = false
            defer {
                voice = nil
                engine = nil
                player = nil
            }
            return (voice, engine, player)
        }
        guard let (unit, engine, player) = stopped else { return }
        // Outside the lock: stopping a player runs the completion handlers of queued sound, and
        // those take the lock.
        unit?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        player?.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        lock.withLock { queued = 0 }
    }

    // MARK: Microphone

    /// Every microphone buffer, off the real-time thread, until `unlisten`.
    func listen(_ handler: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { listeners[id] = handler }
        return id
    }

    func unlisten(_ id: UUID) {
        lock.withLock { listeners[id] = nil }
    }

    /// A mono microphone buffer. On the real-time thread for the voice unit: count it, then
    /// hand it on.
    private func arrived(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        // Louder than -100 dB: real sound, not the floor of a cut-off input.
        let loud = (0..<frames).contains { abs(data[$0]) > 1e-5 }
        let level = Self.level(Self.rms(buffer))
        realTimeLock.withLock {
            soundFrames += frames
            if loud { heardSound = true }
            Self.push(level, into: &inputLevels)
        }
        delivery.async { [weak self] in self?.deliver(buffer) }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        if debug, Date().timeIntervalSince(lastDebug) > 2 {
            lastDebug = Date()
            let db = 20 * log10(max(Self.rms(buffer), 1e-7))
            log("microphone \(String(format: "%.0f", db)) dB, echo cancellation \(echoCancelled ? "on" : "off")")
        }
        let handlers = lock.withLock { Array(listeners.values) }
        handlers.forEach { $0(buffer) }
    }

    /// The first channel only. A downmix would mix raw microphones, and the echo, back in.
    private static func firstChannel(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 1, let source = buffer.floatChannelData?[0],
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let target = out.floatChannelData?[0]
        else { return buffer }
        out.frameLength = buffer.frameLength
        target.update(from: source, count: Int(buffer.frameLength))
        return out
    }

    // MARK: Levels

    /// The latest loudness of the microphone or the speakers, oldest first, each 0...1.
    func levels(input: Bool) -> [Float] {
        if demoLevels {
            // A voice-like wave for screenshots, with no microphone.
            let time = Date().timeIntervalSinceReferenceDate
            return (0..<Self.levelCount).map { index in
                let wave = sin(Double(index) * 0.55 + time * 6) * sin(Double(index) * 0.19 + time * 2.1)
                return Float(min(1, max(0.05, 0.4 + 0.45 * wave)))
            }
        }
        guard lock.withLock({ running }) else { return [Float](repeating: 0, count: Self.levelCount) }
        return realTimeLock.withLock { input ? inputLevels : outputLevels }
    }

    private func played(_ rms: Float) {
        let level = Self.level(rms)
        realTimeLock.withLock { Self.push(level, into: &outputLevels) }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    /// -55 dB is silence here, -5 dB is loud.
    private static func level(_ rms: Float) -> Float {
        min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 50))
    }

    private static func push(_ level: Float, into levels: inout [Float]) {
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: Speaker

    /// Raw 16-bit mono PCM at `sampleRate`, queued after what is already playing.
    func play(_ data: Data, sampleRate: Double) {
        let count = data.count / 2
        guard count > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
              let channel = input.floatChannelData?[0]
        else { return }
        input.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                channel[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            }
        }

        let target: (VoiceIO?, AVAudioPlayerNode?, AVAudioPCMBuffer)? = lock.withLock {
            guard running else { return nil }
            let converter = converters[sampleRate] ?? AVAudioConverter(from: source, to: Self.playFormat)
            converters[sampleRate] = converter
            let frames = AVAudioFrameCount(Double(count) * Self.playFormat.sampleRate / sampleRate) + 64
            guard let converter, let out = AVAudioPCMBuffer(pcmFormat: Self.playFormat, frameCapacity: frames) else { return nil }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            if voice == nil { queued += 1 }
            return (voice, player, out)
        }
        guard let (unit, player, out) = target, let samples = out.floatChannelData?[0] else { return }

        if let unit {
            unit.enqueue(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
            return
        }
        player?.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let drained = self.lock.withLock { () -> Bool in
                self.queued = max(0, self.queued - 1)
                return self.queued == 0
            }
            if drained { DispatchQueue.main.async { self.onDrained() } }
        }
    }

    /// Drop everything queued and stop the sound now.
    func stopPlayback() {
        let (unit, player) = lock.withLock { (voice, self.player) }
        unit?.flush()
        // Outside the lock: player.stop() calls the completion handlers of the queued buffers
        // at once, and they take the lock.
        player?.stop()
        player?.play()
        lock.withLock { queued = 0 }
    }
}

/// Microphone buffers as 16-bit mono samples at one rate, the form speech services take. The
/// converter follows the format of the buffers, which changes when voice processing switches.
final class PCM16Converter {
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private let target: AVAudioFormat
    let sampleRate: Double

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        if source != buffer.format {
            source = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
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
        guard let channel = out.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
