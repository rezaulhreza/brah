import AVFoundation
import AudioToolbox

/// Echo cancellation on Apple's VoiceProcessingIO unit. One unit records the microphone and plays
/// Brah's voice, so it knows what the speakers play and takes it out of the microphone.
/// `AVAudioEngine` voice processing gives only silence on newer macOS; this lower-level unit is
/// the one FaceTime-style apps use.
///
/// Both callbacks run on the real-time audio thread. They copy samples and hand them on, and
/// take only `queueLock`, for a few instructions.
final class VoiceIO: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private static let maxFrames = 4096

    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Each microphone buffer, cleaned of Brah's own voice. On the real-time thread.
    var onInput: (AVAudioPCMBuffer) -> Void = { _ in }
    /// The loudness (RMS) of each piece of sound as it plays. On the real-time thread.
    var onPlayed: (Float) -> Void = { _ in }
    /// The last queued sound has played. On the main queue.
    var onDrained: () -> Void = {}

    private var unit: AudioUnit?
    private let microphone = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let queueLock = NSLock()
    private var queue: [Float] = []
    private var read = 0
    private var playing = false

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "Voice processing failed at \(step) (\(status))" }
    }

    deinit {
        stop()
        microphone.deallocate()
    }

    var isPlaying: Bool { queueLock.withLock { read < queue.count } }

    func start() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure(step: "find", status: -1) }
        var made: AudioUnit?
        try check(AudioComponentInstanceNew(component, &made), "create")
        guard let unit = made else { throw Failure(step: "create", status: -1) }
        self.unit = unit

        do {
            var on: UInt32 = 1
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, "microphone on")
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, "speaker on")

            // The same plain format both ways: 48 kHz mono float.
            var stream = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                     mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                     mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &stream, "microphone format")
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &stream, "speaker format")

            let me = Unmanaged.passUnretained(self).toOpaque()
            var input = AURenderCallbackStruct(inputProc: voiceInput, inputProcRefCon: me)
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &input, "microphone callback")
            var render = AURenderCallbackStruct(inputProc: voiceRender, inputProcRefCon: me)
            try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, "speaker callback")

            // Do not turn other apps down while Brah listens. Not every macOS has this; that is fine.
            var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
            _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                                     &ducking, UInt32(MemoryLayout.size(ofValue: ducking)))

            try check(AudioUnitInitialize(unit), "initialise")
            try check(AudioOutputUnitStart(unit), "start")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        flush()
    }

    /// Queue sound to play after what is already queued: 48 kHz mono float samples.
    func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        queueLock.withLock {
            if read > 0 && read >= queue.count {
                queue.removeAll(keepingCapacity: true)
                read = 0
            }
            queue.append(contentsOf: samples)
        }
    }

    /// Drop everything queued: silence from the next callback on.
    func flush() {
        queueLock.withLock {
            queue.removeAll(keepingCapacity: true)
            read = 0
            playing = false
        }
    }

    // MARK: Real-time callbacks

    fileprivate func microphoneArrived(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                       _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit, Int(frames) <= Self.maxFrames else { return noErr }
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                         mData: UnsafeMutableRawPointer(microphone)))
        let status = AudioUnitRender(unit, flags, time, 1, frames, &list)
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let target = buffer.floatChannelData?[0]
        else { return status }
        buffer.frameLength = frames
        target.update(from: microphone, count: Int(frames))
        onInput(buffer)
        return noErr
    }

    fileprivate func speakerNeeds(_ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let count = Int(frames)

        let drained: Bool = queueLock.withLock {
            let take = min(count, queue.count - read)
            if take > 0 {
                queue.withUnsafeBufferPointer { source in out.update(from: source.baseAddress! + read, count: take) }
                read += take
                playing = true
            }
            if take < count {
                (out + max(0, take)).update(repeating: 0, count: count - max(0, take))
            }
            guard playing, read >= queue.count else { return false }
            playing = false
            return true
        }
        for buffer in buffers.dropFirst() {
            buffer.mData?.assumingMemoryBound(to: Float.self).update(from: out, count: count)
        }

        var sum: Float = 0
        for index in 0..<count { sum += out[index] * out[index] }
        onPlayed((sum / Float(max(1, count))).squareRoot())
        if drained {
            DispatchQueue.main.async { [weak self] in self?.onDrained() }
        }
        return noErr
    }

    // MARK: Helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
                        _ value: inout T, _ step: String) throws {
        try check(AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)), step)
    }
}

private func voiceInput(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                        _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<VoiceIO>.fromOpaque(refCon).takeUnretainedValue().microphoneArrived(flags, time, frames)
}

private func voiceRender(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                         _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<VoiceIO>.fromOpaque(refCon).takeUnretainedValue().speakerNeeds(frames, data)
}
