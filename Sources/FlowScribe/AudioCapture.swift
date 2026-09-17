import AppKit
import AVFoundation

/// Captures microphone input via AVAudioEngine, buffers 16-bit mono PCM in memory,
/// and emits a complete WAV on stop. No temporary files while recording; the WAV
/// is written to a unique temp path only when handing off to the API and deleted
/// immediately afterwards.
final class AudioCapture {

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var inputFormat: AVAudioFormat?
    private(set) var outputFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "com.flowscribe.audiocapture")
    private var isTapInstalled = false

    var recordedSeconds: Double {
        queue.sync {
            guard let format = outputFormat else { return 0 }
            let bytesPerSecond = Double(format.sampleRate) * Double(format.channelCount) * 2 // Int16
            guard bytesPerSecond > 0 else { return 0 }
            return Double(pcm.count) / bytesPerSecond
        }
    }

    func start() throws {
        guard Permissions.isMicrophoneTrusted() else {
            throw CaptureError(message: "Microphone access is not authorized. Grant it in System Settings → Privacy & Security → Microphone.")
        }
        inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let inFormat = inputFormat, inFormat.sampleRate > 0 else {
            throw CaptureError(message: "No usable microphone input format.")
        }

        let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: true)
        guard let target else { throw CaptureError(message: "Failed to create 16 kHz Int16 target format.") }
        converter = AVAudioConverter(from: inFormat, to: target)
        outputFormat = target

        queue.sync { pcm.removeAll(keepingCapacity: true) }

        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.enqueue(buffer: buffer)
        }
        isTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapAndStop()
            throw CaptureError(message: "Could not start microphone capture: \(error.localizedDescription)")
        }
    }

    /// Stops capture. Returns a complete WAV file URL in a unique temp location,
    /// or nil when nothing meaningful was captured.
    func stop() throws -> URL? {
        removeTapAndStop()

        var data = Data()
        var rate: Int = 16_000
        queue.sync {
            data = pcm
            pcm.removeAll(keepingCapacity: false)
            rate = Int(outputFormat?.sampleRate ?? 16_000)
        }

        let tooShort = TranscriptionSupport.isTooShort(pcmByteCount: data.count, sampleRate: rate)
        guard !tooShort else { return nil }

        var wav = WAVHeader.make(sampleRate: rate, channels: 1, bitsPerSample: 16, dataBytes: data.count)
        wav.append(data)
        return try TempFileStore.writeWAV(wav)
    }

    /// Discards all buffered audio (used when a toggle cancels a session).
    func discard() {
        removeTapAndStop()
        queue.sync { pcm.removeAll(keepingCapacity: false) }
    }

    private func removeTapAndStop() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
    }

    private func enqueue(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = converter.outputFormat.sampleRate / max(converter.inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio * 2 + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size * Int(out.format.channelCount)
        queue.sync {
            pcm.append(UnsafeRawPointer(channel[0]).assumingMemoryBound(to: UInt8.self), count: bytes)
        }
    }
}

// MARK: - Unique temp WAV files

enum TempFileStore {
    struct FileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes a WAV to a unique temp path. The caller is responsible for deletion.
    static func writeWAV(_ wav: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowscribe-\(UUID().uuidString).wav")
        do {
            try wav.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw FileError(message: "Could not create the temporary recording file.")
        }
    }

    /// Idempotent, best-effort deletion of a temp recording.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Permissions

enum Permissions {
    /// Requests mic permission if undetermined; returns whether access is granted.
    static func isMicrophoneTrusted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// Whether Accessibility (needed for CGEvent paste) is trusted.
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Checks Accessibility and asks macOS to show the consent prompt when needed.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Opens the relevant System Settings pane.
    static func openSettings(for pane: Pane) {
        var url: URL?
        switch pane {
        case .microphone:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    enum Pane { case microphone, accessibility }
}
