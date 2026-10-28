import Foundation

enum ElevenLabsKeyStore {
    static let account = "elevenlabs-api-key"

    static func resolveKey(environment: [String: String] = ProcessInfo.processInfo.environment,
                           keychainReader: () -> String? = { APIKeyStore.readKeychain(account: account) }) -> String? {
        let key = environment["ELEVENLABS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.flatMap { $0.isEmpty ? nil : $0 } ?? keychainReader()
    }
}

enum ReaderVoiceID {
    static func normalized(_ input: String) -> String? {
        let id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
              !id.lowercased().hasPrefix("sk-"), !id.lowercased().hasPrefix("sk_"),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }
}

struct ReaderSettings {
    static let voiceDidChange = Notification.Name("FlowScribeReaderVoiceDidChange")
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
    enum Permission: String { case speech = "Text to Speech", voices = "Voices: Read", account = "User: Read" }
    enum Failure: LocalizedError, Equatable {
        case permission(Permission)
        case missingKey, invalidVoice, network, invalidResponse, http(Int)

        var errorDescription: String? {
            switch self {
            case .permission(let permission): return "Your ElevenLabs key needs the \(permission.rawValue) permission for this request. You can update its permissions on ElevenLabs."
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
    var usageStore: UsageStore = .shared

    func synthesize(_ text: String, settings: ReaderSettings, previousText: String? = nil,
                    nextText: String? = nil) async throws -> SpeechClip {
        try Task.checkCancellation()
        guard let voiceID = ReaderVoiceID.normalized(settings.voiceID) else { throw Failure.invalidVoice }
        var request = try request(path: "v1/text-to-speech/\(voiceID)/with-timestamps?output_format=mp3_44100_128")
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
        let data = try await send(request, generation: (settings.model.rawValue, Double(text.unicodeScalars.count)))
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
            let data = try await send(request(path: path), permission: .voices)
            guard let response = try? decoder.decode(Response.self, from: data) else { throw Failure.invalidResponse }
            voices += response.voices
            guard response.hasMore == true, let next = response.nextPageToken, next != token else { break }
            token = next
        }
        return voices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func subscription() async throws -> ElevenLabsSubscription {
        try Task.checkCancellation()
        let data = try await send(request(path: "v1/user/subscription"), permission: .account)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let subscription = try? decoder.decode(ElevenLabsSubscription.self, from: data) else { throw Failure.invalidResponse }
        return subscription
    }

    private func request(path: String) throws -> URLRequest {
        guard let key = keyReader(), !key.isEmpty else { throw Failure.missingKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/\(path)")!)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func send(_ request: URLRequest, generation: (model: String, characters: Double)? = nil,
                      permission: Permission = .speech) async throws -> Data {
        try Task.checkCancellation()
        let ticket = generation.map { usageStore.begin(provider: .elevenLabs, model: $0.model, units: $0.characters) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if let ticket { usageStore.finish(ticket, status: nil) }
            if Task.isCancelled { throw CancellationError() }
            throw Failure.network
        }
        let http = response as? HTTPURLResponse
        if let ticket {
            let credits = http?.value(forHTTPHeaderField: "character-cost").flatMap(Double.init)
            usageStore.finish(ticket, status: http?.statusCode, reportedCredits: credits)
        }
        try Task.checkCancellation()
        guard let http else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = body["detail"] as? [String: Any], detail["status"] as? String == "missing_permissions" {
                throw Failure.permission(permission)
            }
            throw Failure.http(http.statusCode)
        }
        return data
    }
}

/// Account-wide values, deliberately kept separate from FlowScribe's local usage estimate.
struct ElevenLabsSubscription: Decodable {
    let tier: String
    let characterCount: Int
    let characterLimit: Int
    let nextCharacterCountResetUnix: Double?
    let currency: String?
    let nextInvoice: Invoice?
    struct Invoice: Decodable { let amountDueCents: Double? }
}
