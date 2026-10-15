import AVFoundation
import AudioToolbox
import CoreAudio

/// An input-only AUHAL can select a microphone without changing or depending on
/// the system output. AVAudioEngine's input/output unit uses a shared device;
/// assigning an input-only device to it can leave it running without any samples.
final class MicrophoneCaptureEngine: AudioCaptureEngine {
    private var unit: AudioUnit?
    private var inputBuffer: AVAudioPCMBuffer?
    private var onFrames: ((Data, AVAudioFrameCount) -> Void)?
    private let processingQueue = DispatchQueue(label: "com.flowscribe.pcmconversion")
    private let listenerQueue = DispatchQueue(label: "com.flowscribe.inputformat")
    private let stateLock = NSLock()
    private var formatChanged = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceID: AudioDeviceID?
    private(set) var isRunning = false

    var inputFormatIsCurrent: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !formatChanged
    }

    deinit { stop() }

    func start(deviceID: UInt32, onPCM: @escaping (Data) -> Void,
               onConfigurationChange: @escaping () -> Void) throws {
        guard Permissions.isMicrophoneTrusted() else {
            throw AudioCapture.CaptureError(message: "Microphone access is not authorized. Grant it in System Settings → Privacy & Security → Microphone.")
        }
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                        componentSubType: kAudioUnitSubType_HALOutput,
                                                        componentManufacturer: kAudioUnitManufacturer_Apple,
                                                        componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw AudioCapture.CaptureError(message: "Could not find the microphone capture audio unit.")
            }
            var createdUnit: AudioUnit?
            try check(AudioComponentInstanceNew(component, &createdUnit), "open microphone capture")
            guard let unit = createdUnit else {
                throw AudioCapture.CaptureError(message: "Could not open the microphone audio unit.")
            }
            self.unit = unit
            self.deviceID = deviceID

            // AUHAL requires input enabled and output disabled BEFORE selecting
            // the device. Input is bus 1; output is bus 0 (Apple TN2091).
            var enabled: UInt32 = 1
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            enabled = 0
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled)
            var selected = deviceID
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected)

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                            kAudioUnitScope_Input, 1, &hardware, &size), "read microphone format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: hardware.mSampleRate,
                                             channels: hardware.mChannelsPerFrame, interleaved: false) else {
                throw AudioCapture.CaptureError(message: "The microphone has no usable audio format. Choose another input in FlowScribe Settings.")
            }
            // AUHAL converts PCM layout, but sample-rate conversion belongs on
            // the processing queue, using the device's actual sample rate.
            var clientFormat = format.streamDescription.pointee
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat)
            let converter = try MicrophonePCMConverter(inputFormat: format)
            let queue = processingQueue
            onFrames = { samples, frames in
                queue.async {
                    if let pcm = converter.convert(planarSamples: samples, frameCount: frames) { onPCM(pcm) }
                }
            }
            var callback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, _, frames, _ in
                let capture = Unmanaged<MicrophoneCaptureEngine>.fromOpaque(context).takeUnretainedValue()
                return capture.render(flags: flags, timestamp: timestamp, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
            try check(AudioUnitInitialize(unit), "initialize microphone capture")

            var maxFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                            kAudioUnitScope_Global, 0, &maxFrames, &size), "read microphone buffer size")
            guard maxFrames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
                throw AudioCapture.CaptureError(message: "Could not allocate the microphone capture buffer.")
            }
            inputBuffer = buffer
            watchFormatChanges(deviceID: deviceID, onChange: onConfigurationChange)
            try check(AudioOutputUnitStart(unit), "start microphone capture")
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let deviceID {
            for (var address, listener) in listeners {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, listener)
            }
        }
        listeners.removeAll()
        if let unit {
            // Stop hardware callbacks before disposing buffers or their context.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        isRunning = false
        processingQueue.sync {} // Deliver the final frames before capture closes its PCM buffer.
        inputBuffer = nil
        onFrames = nil
        deviceID = nil
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let buffer = inputBuffer, frames > 0 else { return noErr }
        guard frames <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr, let channels = buffer.floatChannelData else { return status }
        let bytesPerChannel = Int(frames) * MemoryLayout<Float>.size
        var samples = Data(capacity: bytesPerChannel * Int(buffer.format.channelCount))
        for channel in 0..<Int(buffer.format.channelCount) {
            samples.append(UnsafeBufferPointer(start: UnsafeRawPointer(channels[channel])
                .assumingMemoryBound(to: UInt8.self), count: bytesPerChannel))
        }
        onFrames?(samples, frames)
        return noErr
    }

    private func watchFormatChanges(deviceID: AudioDeviceID, onChange: @escaping () -> Void) {
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
        ]
        for (selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.stateLock.lock()
                self.formatChanged = true
                self.stateLock.unlock()
                onChange()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, listener) == noErr {
                listeners.append((address, listener))
            }
        }
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                        _ scope: AudioUnitScope, _ bus: AudioUnitElement, _ value: inout T) throws {
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, bus, $0, UInt32(MemoryLayout<T>.size))
        }
        try check(status, "configure microphone (property \(property))")
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioCapture.CaptureError(message: "Could not \(operation) (Core Audio error \(status)). Choose another microphone in FlowScribe Settings.")
        }
    }
}

/// Used serially on the processing queue, never with a different hardware format.
final class MicrophonePCMConverter {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init(inputFormat: AVAudioFormat) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCapture.CaptureError(message: "Could not convert the microphone's audio format.")
        }
        self.target = target
        self.converter = converter
    }

    func convert(planarSamples: Data, frameCount: AVAudioFrameCount) -> Data? {
        let format = converter.inputFormat
        let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
        guard frameCount > 0, planarSamples.count == bytesPerChannel * Int(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        planarSamples.withUnsafeBytes { bytes in
            for channel in 0..<Int(format.channelCount) {
                UnsafeMutableRawPointer(channels[channel]).copyMemory(
                    from: bytes.baseAddress!.advanced(by: channel * bytesPerChannel),
                    byteCount: bytesPerChannel)
            }
        }
        return convert(buffer)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format == converter.inputFormat, buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var offset: AVAudioFrameCount = 0
        converter.convert(to: output, error: &error) { requestedFrames, status in
            let frames = min(requestedFrames, buffer.frameLength - offset)
            guard frames > 0,
                  let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames) else {
                status.pointee = .noDataNow
                return nil
            }
            // The converter may request fewer frames than the hardware callback
            // supplied. Handing it the whole buffer discards the excess frames.
            slice.frameLength = frames
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            for index in 0..<source.count {
                destination[index].mData!.copyMemory(
                    from: source[index].mData!.advanced(by: Int(offset) * bytesPerFrame),
                    byteCount: Int(frames) * bytesPerFrame)
            }
            offset += frames
            status.pointee = .haveData
            return slice
        }
        guard error == nil, output.frameLength > 0, let channels = output.int16ChannelData else { return nil }
        return Data(bytes: channels[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
