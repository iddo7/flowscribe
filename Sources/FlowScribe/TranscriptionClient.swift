import Foundation

/// Posts a WAV to the OpenAI transcription endpoint and returns plain text.
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
                return "Recording was too short or silent; nothing sent."
            case .localFile:
                return "Could not read the temporary recording file."
            case .badResponse:
                return "Unexpected response from the transcription service."
            }
        }
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private let session: URLSession
    private let environment: [String: String]

    init(session: URLSession = .shared, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.session = session
        self.environment = environment
    }

    func transcribe(fileAt url: URL) async throws -> String {
        let wav: Data
        do {
            wav = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        } catch {
            throw APIError(kind: .localFile, detail: nil)
        }
        guard !wav.isEmpty else { throw APIError(kind: .emptyAudio, detail: nil) }

        guard let key = APIKeyStore.resolveKey(environment: environment) else {
            throw APIError(kind: .missingAPIKey, detail: nil)
        }

        let model = TranscriptionSupport.resolveModel(environment: environment)
        let (body, boundary) = MultipartBody.make(fileData: wav, model: model)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("FlowScribe/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError(kind: .transport, detail: Self.userFacingDetail(error))
        }
        // Never log data contents (contains the transcript) or headers (contain the key).
        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .badResponse, detail: nil)
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            let detail = Self.userFacingAPIFailure(status: http.statusCode, data: data)
            throw APIError(kind: .http(http.statusCode), detail: detail)
        }
        guard let text = TranscriptionSupport.parseText(from: data) else {
            throw APIError(kind: .badResponse, detail: nil)
        }
        return text
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
    private static func userFacingAPIFailure(status: Int, data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObject = object["error"] as? [String: Any],
              let message = errorObject["message"] as? String else { return nil }
        let short = message.prefix(160)
        switch status {
        case 401: return "Check your API key."
        case 403: return "The key is not allowed to use this model."
        case 429: return "Rate limit reached; try again shortly."
        default: return short.isEmpty ? nil : String(short)
        }
    }
}
