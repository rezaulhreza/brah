import AVFoundation

/// One audio engine for the microphone and the voice. With both in one engine, the Mac's voice
/// processing knows what the speakers play and takes it out of the microphone (echo
/// cancellation), so Brah does not hear itself. The engine runs only while something uses it, so
/// the microphone light is off when Brah is idle.
final class AudioIO: @unchecked Sendable {
    static let shared = AudioIO()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    /// Pulls the microphone when voice processing is on.
    private var sink: AVAudioSinkNode?
    /// Microphone audio reaches the listeners here, off the real-time thread.
    private let delivery = DispatchQueue(label: "brah.audio.microphone")
    /// Any sample that is not zero has come from the microphone since voice processing started.
    /// It has its own lock: the real-time audio thread sets it, and must never wait for `lock`,
    /// which is held while the engine starts.
    private let soundLock = NSLock()
    private var heardSound = false
    /// Frames from the sink since voice processing started: a stalled sink delivers almost none.
    private var soundFrames = 0
    /// Voice processing gave only silence once: do not try it again until Brah restarts.
    private var restartWithoutEchoCancellation = false
    /// Set when the engine starts: the output node's own format. With voice processing, the
    /// player must feed the output node directly, not the mixer, or the engine does not start.
    private var playFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let lock = NSLock()
    private var listeners: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var converters: [Double: AVAudioConverter] = [:]
    private var users = 0
    private var running = false
    private var stopping: DispatchWorkItem?
    private var queued = 0
    private(set) var echoCancelled = false
    private var inputLevels = [Float](repeating: 0, count: AudioIO.levelCount)
    private var outputLevels = [Float](repeating: 0, count: AudioIO.levelCount)
    static let levelCount = 28
    /// Called on the main queue when the last queued sound has played.
    var onDrained: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private init() {
        engine.attach(player)
    }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// Sound is queued or playing.
    var isPlaying: Bool { lock.withLock { queued > 0 } }

    // MARK: Lifetime

    /// Start the engine if it is not running. Pair each call with `release`.
    func acquire() throws {
        try lock.withLock {
            users += 1
            stopping?.cancel()
            stopping = nil
            guard !running else { return }
            do {
                // BRAH_NO_ECHO_CANCELLATION=1 starts without voice processing, to find audio faults.
                try startLocked(echoCancellation: !restartWithoutEchoCancellation
                                && ProcessInfo.processInfo.environment["BRAH_NO_ECHO_CANCELLATION"] == nil)
            } catch {
                log("audio engine with echo cancellation failed (\(error.localizedDescription)), trying without")
                do {
                    try startLocked(echoCancellation: false)
                } catch {
                    users -= 1
                    throw error
                }
            }
        }
    }

    /// The engine stops a few seconds after its last user, so a quick next use does not wait.
    func release() {
        lock.withLock {
            users = max(0, users - 1)
            guard users == 0, running else { return }
            let work = DispatchWorkItem { [weak self] in self?.stopIfUnused() }
            stopping = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private func startLocked(echoCancellation: Bool) throws {
        let input = engine.inputNode
        echoCancelled = false
        do {
            try input.setVoiceProcessingEnabled(echoCancellation)
            if echoCancellation {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                echoCancelled = true
            }
        } catch {
            log("echo cancellation not available: \(error.localizedDescription)")
        }
        let output = engine.outputNode.inputFormat(forBus: 0)
        if output.sampleRate > 0, output.channelCount > 0,
           let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: output.channelCount) {
            playFormat = format
            converters = [:]
        }
        engine.connect(player, to: engine.outputNode, format: playFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        if echoCancelled {
            // With voice processing, newer macOS gives a tap on the input no audio at all. A sink
            // node pulls it. The sink runs on the real-time audio thread, so it only copies the
            // cleaned first channel and hands it on.
            let sink = AVAudioSinkNode { [weak self] _, frames, list in
                self?.receive(list, frames: frames, sampleRate: inputFormat.sampleRate)
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: sink, format: inputFormat)
            self.sink = sink
        } else {
            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                self?.deliver(buffer)
            }
        }
        // What the speakers play, as it plays, for the waveform.
        player.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(buffer)
            self.lock.withLock { Self.push(level, into: &self.outputLevels) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Leave nothing behind: a second tap on a node is a crash.
            input.removeTap(onBus: 0)
            player.removeTap(onBus: 0)
            removeSink()
            engine.stop()
            engine.reset()
            throw error
        }
        player.play()
        running = true
        log("audio engine started, echo cancellation \(echoCancelled ? "on" : "off"), microphone \(input.outputFormat(forBus: 0))")
        if echoCancelled {
            soundLock.withLock {
                heardSound = false
                soundFrames = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkEchoCancellation() }
        }
    }

    /// Some macOS versions start voice processing but give only silence. A room is never at
    /// digital zero, so no sound at all means the microphone is cut off: start again without
    /// echo cancellation. The echo check by words still keeps Brah from answering itself.
    private func checkEchoCancellation() {
        // Half a second of sound in the first 1.5 seconds, and some of it above the floor.
        let (heard, frames) = soundLock.withLock { (heardSound, soundFrames) }
        let enough = heard && Double(frames) > engine.inputNode.outputFormat(forBus: 0).sampleRate * 0.5
        let silent = lock.withLock { running && echoCancelled && !enough }
        guard silent else { return }
        log("echo cancellation gives no sound on this Mac (\(frames) frames, loud: \(heard)); using the microphone without it")
        lock.withLock {
            restartWithoutEchoCancellation = true
            running = false
        }
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        removeSink()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        // An engine that had voice processing stays broken after it is switched off: start
        // again with a new one.
        lock.withLock {
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            engine.attach(player)
            converters = [:]
        }
        do {
            try lock.withLock { try startLocked(echoCancellation: false) }
        } catch {
            log("the microphone did not start again: \(error.localizedDescription)")
        }
    }

    private func stopIfUnused() {
        let stop = lock.withLock { () -> Bool in
            guard users == 0, running else { return false }
            running = false
            return true
        }
        guard stop else { return }
        // Outside the lock: stopping the player runs the completion handlers of queued sound,
        // and those take the lock.
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        removeSink()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        lock.withLock { queued = 0 }
    }

    private func removeSink() {
        guard let sink else { return }
        engine.disconnectNodeInput(sink)
        engine.detach(sink)
        self.sink = nil
    }

    // MARK: Microphone

    /// From the sink, on the real-time audio thread: copy the first channel, the cleaned voice,
    /// and hand it to the listeners on their own queue.
    private func receive(_ list: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount, sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard frames > 0, let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames),
              let target = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frames
        target.update(from: first, count: Int(frames))
        // Louder than -100 dB: real sound, not the floor of a cut-off input.
        let loud = (0..<Int(frames)).contains { abs(first[$0]) > 1e-5 }
        soundLock.withLock {
            soundFrames += Int(frames)
            if loud { heardSound = true }
        }
        if debugChannels {
            let levels = buffers.map { channel -> Float in
                guard let data = channel.mData?.assumingMemoryBound(to: Float.self) else { return -140 }
                var sum: Float = 0
                for index in 0..<Int(frames) { sum += data[index] * data[index] }
                return 20 * log10(max((sum / Float(frames)).squareRoot(), 1e-7))
            }
            delivery.async { [weak self] in self?.logChannels(levels) }
        }
        delivery.async { [weak self] in self?.deliver(buffer) }
    }

    private func logChannels(_ levels: [Float]) {
        guard Date().timeIntervalSince(lastDebug) > 2 else { return }
        lastDebug = Date()
        log("microphone channels (dB): \(levels.map { String(format: "%.0f", $0) }.joined(separator: " "))")
    }

    /// Every microphone buffer, on the audio thread, until `unlisten`.
    func listen(_ handler: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { listeners[id] = handler }
        return id
    }

    func unlisten(_ id: UUID) {
        lock.withLock { listeners[id] = nil }
    }

    /// BRAH_AUDIO_DEBUG=1 logs the loudness of every microphone channel every two seconds.
    private let debugChannels = ProcessInfo.processInfo.environment["BRAH_AUDIO_DEBUG"] != nil
    private var lastDebug = Date.distantPast

    private func deliver(_ input: AVAudioPCMBuffer) {
        if debugChannels, sink == nil, Date().timeIntervalSince(lastDebug) > 2, let data = input.floatChannelData {
            lastDebug = Date()
            let levels = (0..<Int(input.format.channelCount)).map { channel -> String in
                var sum: Float = 0
                for index in 0..<Int(input.frameLength) { sum += data[channel][index] * data[channel][index] }
                let rms = (sum / Float(max(1, input.frameLength))).squareRoot()
                return String(format: "%.0f", 20 * log10(max(rms, 1e-7)))
            }
            log("microphone channels (dB): \(levels.joined(separator: " "))")
        }
        let buffer = Self.firstChannel(input)
        let level = Self.level(buffer)
        let handlers = lock.withLock { () -> [(AVAudioPCMBuffer) -> Void] in
            Self.push(level, into: &inputLevels)
            return Array(listeners.values)
        }
        handlers.forEach { $0(buffer) }
    }

    /// With voice processing the microphone has several channels; the first is the cleaned voice.
    /// A downmix would mix the raw microphones, and the echo, back in.
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
        return lock.withLock { running ? (input ? inputLevels : outputLevels) : [Float](repeating: 0, count: Self.levelCount) }
    }

    /// Demo mode: the waveform moves without sound.
    var demoLevels = false

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // -55 dB is silence here, -5 dB is loud.
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 50))
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

        let output: AVAudioPCMBuffer? = lock.withLock {
            guard running, let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: playFormat.sampleRate, channels: 1, interleaved: false)
            else { return nil }
            let converter = converters[sampleRate] ?? AVAudioConverter(from: source, to: mono)
            converters[sampleRate] = converter
            let frames = AVAudioFrameCount(Double(count) * playFormat.sampleRate / sampleRate) + 64
            guard let converter,
                  let resampled = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames),
                  let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames)
            else { return nil }
            var fed = false
            converter.convert(to: resampled, error: nil) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            // The same voice in every output channel.
            out.frameLength = resampled.frameLength
            if let from = resampled.floatChannelData?[0], let channels = out.floatChannelData {
                for channel in 0..<Int(playFormat.channelCount) {
                    channels[channel].update(from: from, count: Int(resampled.frameLength))
                }
            }
            queued += 1
            return out
        }
        guard let output else { return }
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
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
        guard lock.withLock({ running }) else { return }
        // Outside the lock: player.stop() calls the completion handlers of the queued buffers
        // at once, and they take the lock. Under the lock this was a deadlock.
        player.stop()
        player.play()
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
