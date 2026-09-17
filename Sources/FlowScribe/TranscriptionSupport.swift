import Foundation

/// Pure multipart/form-data builder for the OpenAI transcription API. Unit-testable.
enum MultipartBody {
    /// Builds a multipart body for POST https://api.openai.com/v1/audio/transcriptions.
    /// - Returns: (body, boundary) — caller must set Content-Type and Content-Length.
    static func make(fileData: Data,
                     fileName: String = "audio.wav",
                     mimeType: String = "audio/wav",
                     model: String,
                     language: String? = nil) -> (body: Data, boundary: String) {
        let boundary = "flowscribe.boundary.\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        field("model", model)
        if let language, !language.isEmpty {
            field("language", language)
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")
        return (body, boundary)
    }
}

extension Data {
    mutating func appendString(_ s: String) {
        append(Data(s.utf8))
    }
}

/// Pure helpers for request validation and response parsing. Unit-testable.
enum TranscriptionSupport {
    static let defaultModel = "gpt-transcribe"
    static let modelEnvironmentKey = "OPENAI_TRANSCRIBE_MODEL"

    /// Minimum recording duration before calling the API (seconds).
    static let minimumRecordingSeconds: Double = 0.3

    /// True when captured PCM is too short to be worth sending.
    static func isTooShort(pcmByteCount: Int, sampleRate: Int, bytesPerFrame: Int = 2) -> Bool {
        guard sampleRate > 0, bytesPerFrame > 0 else { return true }
        let seconds = Double(pcmByteCount) / (Double(sampleRate) * Double(bytesPerFrame))
        return seconds < minimumRecordingSeconds
    }

    /// Resolves the model: environment override wins over the default.
    static func resolveModel(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let override = environment[modelEnvironmentKey] ?? ""
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// Extracts `text` from a transcription JSON response.
    static func parseText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        return text
    }
}
