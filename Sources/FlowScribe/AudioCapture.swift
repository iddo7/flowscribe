import AppKit
import AVFoundation
import AudioToolbox

/// Engine operations never run on the UI thread or inside an engine notification.
/// A session keeps its PCM across route changes; every route gets a fresh engine/converter.
final class AudioCapture {
    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let queue = DispatchQueue(label: "com.flowscribe.audiocapture")
    private let resolveDevice: () -> AudioInputDevice?
    private let makeEngine: () -> AudioCaptureEngine
    private var observers: [NSObjectProtocol] = []
    private var sessionID: UUID?
    private var streamID: UUID?
    private var device: AudioInputDevice?
    private var engine: AudioCaptureEngine?
    private var buffer: RecordingPCMBuffer?

    /// Delivered on the main queue, with the session identity to ignore stale failures.
    var onFailure: ((UUID, Error) -> Void)?

    /// Normalized microphone level, delivered on the main queue for the active stream only.
    var onAudioLevel: ((UUID, Double) -> Void)?

    init(resolveDevice: @escaping () -> AudioInputDevice? = { AudioInputDevices.shared.selectedDevice() },
         makeEngine: @escaping () -> AudioCaptureEngine = { MicrophoneCaptureEngine() },
         observeDeviceChanges: Bool = true) {
        self.resolveDevice = resolveDevice
        self.makeEngine = makeEngine
        if observeDeviceChanges {
            _ = AudioInputDevices.shared
            for name in [AudioInputDevices.didChange, AudioInputSelection.didChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.refreshInputDevice()
                })
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start(sessionID: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.discardOnQueue()
            self.sessionID = sessionID
            self.buffer = RecordingPCMBuffer()
            do {
                try self.startEngine()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.discardOnQueue()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop(sessionID: UUID, completion: @escaping (Result<URL?, Error>) -> Void) {
        queue.async {
            guard self.sessionID == sessionID else {
                DispatchQueue.main.async { completion(.success(nil)) }
                return
            }
            self.stopEngine()
            let data = self.buffer?.finish() ?? Data()
            self.buffer = nil
            self.sessionID = nil
            let result: Result<URL?, Error>
            do {
                if data.isEmpty {
                    throw CaptureError(message: "The microphone supplied no audio. Open FlowScribe Settings and use Test microphone to check the selected input.")
                } else if TranscriptionSupport.isTooShort(pcmByteCount: data.count, sampleRate: 16_000) {
                    result = .success(nil)
                } else {
                    var wav = WAVHeader.make(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: data.count)
                    wav.append(data)
                    result = .success(try TempFileStore.writeWAV(wav))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func discard() {
        queue.async { self.discardOnQueue() }
    }

    func refreshInputDevice() {
        queue.async { self.refreshRoute() }
    }

    private func startEngine() throws {
        guard let selected = resolveDevice() else {
            throw CaptureError(message: "No microphone is available. Connect a microphone or choose another input in FlowScribe Settings.")
        }
        guard let buffer, let sessionID else { return }
        let streamID = UUID()
        let engine = makeEngine()
        self.streamID = streamID
        self.engine = engine
        self.device = selected
        buffer.activate(streamID: streamID)
        try engine.start(deviceID: selected.id, onPCM: { [weak self] data in
            guard let level = buffer.append(data, streamID: streamID) else { return }
            DispatchQueue.main.async { [weak self] in
                guard buffer.isActive(streamID: streamID) else { return }
                self?.onAudioLevel?(sessionID, level)
            }
        }, onConfigurationChange: { [weak self] in
            // Queue teardown away from the hardware notification callback.
            self?.queue.async { [weak self] in
                guard let self, self.streamID == streamID else { return }
                self.refreshRoute(force: true)
            }
        })
    }

    private func refreshRoute(force: Bool = false) {
        guard let sessionID else { return }
        let selected = resolveDevice()
        // Initializing an engine can itself post a configuration notification.
        // Rebuilding a healthy, unchanged engine here would cause a restart loop.
        guard selected != device || engine?.isRunning != true ||
                (force && engine?.inputFormatIsCurrent != true) else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            discardOnQueue()
            DispatchQueue.main.async { [weak self] in self?.onFailure?(sessionID, error) }
        }
    }

    private func stopEngine() {
        // Invalidate queued notifications before stopping/releasing this engine.
        streamID = nil
        // Stop also drains already captured samples before retiring their stream.
        engine?.stop()
        buffer?.activate(streamID: nil)
        engine = nil
        device = nil
    }

    private func discardOnQueue() {
        stopEngine()
        _ = buffer?.finish()
        buffer = nil
        sessionID = nil
    }
}

/// Injectable hardware boundary, so route changes and late callbacks can be tested without a microphone.
protocol AudioCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var inputFormatIsCurrent: Bool { get }
    func start(deviceID: UInt32, onPCM: @escaping (Data) -> Void,
               onConfigurationChange: @escaping () -> Void) throws
    func stop()
}

/// The hardware callback never synchronously dispatches to the queue that stops it.
/// Closing the buffer also rejects late callbacks from retired sessions.
final class RecordingPCMBuffer {
    private let lock = NSLock()
    private var pcm = Data()
    private var isClosed = false
    private var streamID: UUID?
    private var levelMeter = PCMLevelMeter()

    func activate(streamID: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        self.streamID = streamID
        levelMeter = PCMLevelMeter()
    }

    func isActive(streamID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && self.streamID == streamID
    }

    @discardableResult
    func append(_ data: Data, streamID: UUID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, self.streamID == streamID else { return nil }
        pcm.append(data)
        return levelMeter.consume(data)
    }

    func finish() -> Data {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        let result = pcm
        pcm.removeAll(keepingCapacity: false)
        return result
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
