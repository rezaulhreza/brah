import AVFoundation

/// One audio engine for the microphone and the voice. With both in one engine, the Mac's voice
/// processing knows what the speakers play and takes it out of the microphone (echo
/// cancellation), so Brah does not hear itself. The engine runs only while something uses it, so
/// the microphone light is off when Brah is idle.
final class AudioIO: @unchecked Sendable {
    static let shared = AudioIO()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
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
                try startLocked(echoCancellation: true)
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
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.deliver(buffer)
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
            engine.stop()
            engine.reset()
            throw error
        }
        player.play()
        running = true
        log("audio engine started, echo cancellation \(echoCancelled ? "on" : "off"), microphone \(input.outputFormat(forBus: 0))")
    }

    private func stopIfUnused() {
        lock.withLock {
            guard users == 0, running else { return }
            engine.inputNode.removeTap(onBus: 0)
            player.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            running = false
            queued = 0
        }
    }

    // MARK: Microphone

    /// Every microphone buffer, on the audio thread, until `unlisten`.
    func listen(_ handler: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { listeners[id] = handler }
        return id
    }

    func unlisten(_ id: UUID) {
        lock.withLock { listeners[id] = nil }
    }

    private func deliver(_ input: AVAudioPCMBuffer) {
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
        lock.withLock { running ? (input ? inputLevels : outputLevels) : [Float](repeating: 0, count: Self.levelCount) }
    }

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
        lock.withLock {
            guard running else { return }
            player.stop()
            player.play()
            queued = 0
        }
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
