import Foundation

enum ElevenLabsKeyStore {
    static let account = "elevenlabs-api-key"

    static func resolveKey(environment: [String: String] = ProcessInfo.processInfo.environment,
                           keychainReader: () -> String? = { APIKeyStore.readKeychain(account: account) }) -> String? {
        let key = environment["ELEVENLABS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.flatMap { $0.isEmpty ? nil : $0 } ?? keychainReader()
    }
}

struct ReaderSettings {
    enum VoiceModel: String, CaseIterable {
        case natural = "eleven_multilingual_v2"
        case expressive = "eleven_v3"
        case fast = "eleven_flash_v2_5"

        var title: String {
            switch self {
            case .natural: return "Natural · Multilingual v2"
            case .expressive: return "Expressive · Eleven v3"
            case .fast: return "Fast · Flash v2.5"
            }
        }
    }

    var voiceID: String
    var model: VoiceModel
    var speed: Float
    var offersSelection: Bool

    static func load(defaults: UserDefaults = .standard) -> ReaderSettings {
        let speed = defaults.float(forKey: "reader.speed")
        return ReaderSettings(
            voiceID: defaults.string(forKey: "reader.voiceID") ?? "JBFqnCBsd6RMkjVDRZzb",
            model: VoiceModel(rawValue: defaults.string(forKey: "reader.model") ?? "") ?? .natural,
            speed: speed.isFinite && speed >= 0.6 && speed <= 2 ? speed : 1,
            offersSelection: defaults.object(forKey: "reader.offersSelection") as? Bool ?? true
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(voiceID, forKey: "reader.voiceID")
        defaults.set(model.rawValue, forKey: "reader.model")
        defaults.set(speed, forKey: "reader.speed")
        defaults.set(offersSelection, forKey: "reader.offersSelection")
    }
}

struct SpeechClip {
    let audio: Data
    let timeline: SpeechTimeline?
}

struct SpeechVoice: Decodable {
    let voiceId: String
    let name: String
}

struct SpeechClient {
    enum Failure: LocalizedError, Equatable {
        case missingKey, invalidVoice, network, invalidResponse, http(Int)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add an ElevenLabs API key in Settings → Read aloud."
            case .invalidVoice: return "Choose a voice in Settings → Read aloud."
            case .network: return "Could not reach ElevenLabs. Check your connection and try again."
            case .invalidResponse: return "ElevenLabs returned audio that could not be played. Try another voice or model."
            case .http(401): return "ElevenLabs rejected the API key. Update it in Settings → Read aloud."
            case .http(403): return "Your ElevenLabs key or plan does not have access to this voice or model."
            case .http(429): return "ElevenLabs usage or rate limit reached. Check your plan and try again later."
            case .http(let code): return "ElevenLabs request failed (HTTP \(code)). Try again."
            }
        }
    }

    private static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    var session: URLSession = privateSession
    var keyReader: () -> String? = { ElevenLabsKeyStore.resolveKey() }

    func synthesize(_ text: String, settings: ReaderSettings, previousText: String? = nil,
                    nextText: String? = nil) async throws -> SpeechClip {
        try Task.checkCancellation()
        guard !settings.voiceID.isEmpty,
              settings.voiceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw Failure.invalidVoice }
        var request = try request(path: "v1/text-to-speech/\(settings.voiceID)/with-timestamps?output_format=mp3_44100_128")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "text": text,
            "model_id": settings.model.rawValue,
            "voice_settings": ["stability": settings.model == .expressive ? 0.5 : 0.4,
                               "similarity_boost": 0.75]
        ]
        if settings.model != .expressive {
            body["previous_text"] = previousText
            body["next_text"] = nextText
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        struct Response: Decodable {
            let audioBase64: String
            let alignment: SpeechAlignment?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: data),
              let audio = Data(base64Encoded: response.audioBase64), !audio.isEmpty else {
            throw Failure.invalidResponse
        }
        return SpeechClip(audio: audio, timeline: response.alignment?.timeline(for: text))
    }

    func voices() async throws -> [SpeechVoice] {
        try Task.checkCancellation()
        struct Response: Decodable {
            let voices: [SpeechVoice]
            let hasMore: Bool?
            let nextPageToken: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var voices: [SpeechVoice] = []
        var token: String?
        for _ in 0..<20 {
            var path = "v2/voices?page_size=100"
            if let token { path += "&next_page_token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            let data = try await send(request(path: path))
            guard let response = try? decoder.decode(Response.self, from: data) else { throw Failure.invalidResponse }
            voices += response.voices
            guard response.hasMore == true, let next = response.nextPageToken, next != token else { break }
            token = next
        }
        return voices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func request(path: String) throws -> URLRequest {
        guard let key = keyReader(), !key.isEmpty else { throw Failure.missingKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/\(path)")!)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        return data
    }
}
