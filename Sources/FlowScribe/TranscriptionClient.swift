import Foundation

/// Posts audio to the OpenAI transcription endpoint and returns plain text.
/// Never logs the API key, request body, or transcript.
final class TranscriptionClient {
    struct APIError: LocalizedError, Equatable {
        let kind: Kind
        let detail: String?

        enum Kind: Equatable {
            case missingAPIKey
            case http(Int)   // status code
            case transport   // network failure
            case emptyAudio
            case oversizedAudio
            case unsupportedFormat
            case localFile
            case badResponse
        }

        var errorDescription: String? {
            switch kind {
            case .missingAPIKey:
                return "No OpenAI API key found. Set OPENAI_API_KEY in your environment or save one in FlowScribe Settings."
            case .http(let code):
                let base = "Transcription request failed (HTTP \(code))."
                if let detail { return base + " " + detail }
                return base
            case .transport:
                return "Network error reaching the transcription service. Check your connection."
            case .emptyAudio:
                return "The audio file is empty. Nothing was uploaded."
            case .oversizedAudio:
                return "The audio file exceeds OpenAI's \(TranscriptionClient.maximumFileSizeMB) MB upload limit."
            case .unsupportedFormat:
                return "Unsupported audio format. Use one of: \(TranscriptionAudioFormat.supportedExtensions)."
            case .localFile:
                return "Could not read the audio file. Check that it is a readable local file."
            case .badResponse:
                return "Unexpected response from the transcription service."
            }
        }
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let maximumFileSizeMB = 25

    private let session: URLSession
    private let environment: [String: String]
    private let usageStore: UsageStore?

    init(session: URLSession = .shared, environment: [String: String] = ProcessInfo.processInfo.environment,
         usageStore: UsageStore? = .shared) {
        self.session = session
        self.environment = environment
        self.usageStore = usageStore
    }

    func transcribe(fileAt url: URL, format: TranscriptionAudioFormat? = nil) async throws -> String {
        guard let format = format ?? TranscriptionAudioFormat(rawValue: url.pathExtension.lowercased()) else {
            throw APIError(kind: .unsupportedFormat, detail: nil)
        }
        let audio = try await Task.detached(priority: .userInitiated) {
            try Self.readAudio(at: url)
        }.value

        guard let key = APIKeyStore.resolveKey(environment: environment) else {
            throw APIError(kind: .missingAPIKey, detail: nil)
        }

        let model = TranscriptionSupport.resolveModel(environment: environment)
        let (body, boundary) = MultipartBody.make(
            fileData: audio,
            fileName: "audio.\(format.rawValue)",
            mimeType: format.mimeType,
            model: model
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("FlowScribe/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        request.httpBody = body

        try Task.checkCancellation()
        let ticket = usageStore?.begin(provider: .openAI, model: model, units: WAVHeader.duration(of: audio))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let ticket { usageStore?.finish(ticket, status: nil) }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw APIError(kind: .transport, detail: Self.userFacingDetail(error))
        }
        if let ticket { usageStore?.finish(ticket, status: (response as? HTTPURLResponse)?.statusCode) }
        try Task.checkCancellation()
        // Never log data contents (contains the transcript) or headers (contain the key).
        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .badResponse, detail: nil)
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            let detail = Self.userFacingAPIFailure(status: http.statusCode, data: data, key: key)
            throw APIError(kind: .http(http.statusCode), detail: detail)
        }
        guard let text = TranscriptionSupport.parseText(from: data) else {
            throw APIError(kind: .badResponse, detail: nil)
        }
        return text
    }

    private static func readAudio(at url: URL) throws -> Data {
        let maximumFileSize = maximumFileSizeMB * 1_000_000
        let file = url.resolvingSymlinksInPath()
        do {
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard metadata.isRegularFile == true else { throw APIError(kind: .localFile, detail: nil) }
            guard let size = metadata.fileSize, size <= maximumFileSize else {
                throw APIError(kind: .oversizedAudio, detail: nil)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maximumFileSize + 1), !data.isEmpty else {
                throw APIError(kind: .emptyAudio, detail: nil)
            }
            guard data.count <= maximumFileSize else { throw APIError(kind: .oversizedAudio, detail: nil) }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(kind: .localFile, detail: nil)
        }
    }

    /// Maps low-level transport errors to short, user-safe messages (no URLs/keys).
    private static func userFacingDetail(_ error: Error) -> String? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return "The request timed out."
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "You appear to be offline."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Could not reach the server."
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "Insecure transport blocked."
            default:
                break
            }
        }
        return nil
    }

    /// Extracts a brief, user-safe message from an error response body if present.
    private static func userFacingAPIFailure(status: Int, data: Data?, key: String) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObject = object["error"] as? [String: Any],
              let message = errorObject["message"] as? String else { return nil }
        switch status {
        case 401: return "Check your API key."
        case 403: return "The key is not allowed to use this model."
        case 429: return "Rate limit reached; try again shortly."
        default:
            let short = message.replacingOccurrences(of: key, with: "[redacted]").prefix(160)
            return short.isEmpty ? nil : String(short)
        }
    }
}
