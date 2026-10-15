import AppKit

/// A short, local-only input check. No upload, transcription, or clipboard changes.
@MainActor
final class MicrophoneTest {
    private let capture = AudioCapture()
    private var sessionID: UUID?
    private var completion: ((Result<Double, Error>) -> Void)?
    private var timer: Timer?

    func start(completion: @escaping (Result<Double, Error>) -> Void) {
        guard sessionID == nil else { return }
        let id = UUID()
        sessionID = id
        self.completion = completion
        capture.onFailure = { [weak self] failedID, error in
            guard let self, self.sessionID == failedID else { return }
            self.finish(.failure(error))
        }
        capture.start(sessionID: id) { [weak self] result in
            guard let self, self.sessionID == id else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success:
                self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.stop(sessionID: id) }
                }
            }
        }
    }

    private func stop(sessionID: UUID) {
        capture.stop(sessionID: sessionID) { [weak self] result in
            guard let self, self.sessionID == sessionID else {
                if case .success(let file?) = result { TempFileStore.remove(file) }
                return
            }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(nil):
                self.finish(.failure(AudioCapture.CaptureError(message: "The microphone supplied less than 0.3 seconds of audio during the two-second test.")))
            case .success(let file?):
                do {
                    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                    let bytes = max(0, (size?.intValue ?? 0) - WAVHeader.headerByteCount)
                    TempFileStore.remove(file)
                    self.finish(.success(Double(bytes) / 32_000))
                } catch {
                    TempFileStore.remove(file)
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<Double, Error>) {
        timer?.invalidate()
        timer = nil
        sessionID = nil
        let callback = completion
        completion = nil
        capture.discard()
        callback?(result)
    }
}
