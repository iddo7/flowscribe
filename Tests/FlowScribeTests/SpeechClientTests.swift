import XCTest
@testable import FlowScribe

final class SpeechClientTests: XCTestCase {
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> SpeechClient {
        SpeechStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechStubProtocol.self]
        return SpeechClient(session: URLSession(configuration: config), keyReader: { "test-key" })
    }

    func testSynthesisSendsLiteralTextAndDecodesAudioAndTiming() async throws {
        let client = client { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/text-to-speech/testVoice/with-timestamps")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
            let body = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: Any]
            XCTAssertEqual(body["text"] as? String, "Hi")
            XCTAssertEqual(body["model_id"] as? String, "eleven_multilingual_v2")
            XCTAssertEqual(body["previous_text"] as? String, "Before.")
            XCTAssertEqual(body["next_text"] as? String, "After.")
            return (200, Data(#"{"audio_base64":"YXVkaW8=","alignment":{"characters":["H","i"],"character_start_times_seconds":[0,0.2],"character_end_times_seconds":[0.2,0.4]}}"#.utf8))
        }
        let clip = try await client.synthesize("Hi", settings: settings(), previousText: "Before.", nextText: "After.")
        XCTAssertEqual(clip.audio, Data("audio".utf8))
        XCTAssertEqual(clip.timeline?.time(at: 1), 0.2)
    }

    func testExpressiveModelOmitsUnsupportedStitchingParameters() async throws {
        let client = client { request in
            let body = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: Any]
            XCTAssertEqual(body["model_id"] as? String, "eleven_v3")
            XCTAssertNil(body["previous_text"])
            XCTAssertNil(body["next_text"])
            return (200, Data(#"{"audio_base64":"YXVkaW8="}"#.utf8))
        }
        var settings = settings()
        settings.model = .expressive
        _ = try await client.synthesize("Hi", settings: settings, previousText: "Before.", nextText: "After.")
    }

    func testVoiceListHandlesPaginationAndSorting() async throws {
        let client = client { request in
            if request.url?.query?.contains("next_page_token") == true {
                return (200, Data(#"{"voices":[{"voice_id":"a","name":"Alice"}],"has_more":false}"#.utf8))
            }
            return (200, Data(#"{"voices":[{"voice_id":"z","name":"Zoe"}],"has_more":true,"next_page_token":"next"}"#.utf8))
        }
        let voices = try await client.voices()
        XCTAssertEqual(voices.map(\.name), ["Alice", "Zoe"])
        XCTAssertEqual(voices.first?.voiceId, "a")
    }

    func testHTTPFailuresDoNotExposeServerTextOrKeys() async {
        for status in [401, 403, 429, 500] {
            let client = client { _ in (status, Data("private selected text or key".utf8)) }
            do {
                _ = try await client.synthesize("Hi", settings: settings())
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? SpeechClient.Failure, .http(status))
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
        }
    }

    func testMissingKeyMakesNoNetworkRequest() async {
        var client = client { _ in XCTFail("Must not send request"); return (500, Data()) }
        client.keyReader = { nil }
        do {
            _ = try await client.synthesize("Hi", settings: settings())
            XCTFail("Expected missing key")
        } catch { XCTAssertEqual(error as? SpeechClient.Failure, .missingKey) }
    }

    func testInvalidResponseIsRejected() async {
        let client = client { _ in (200, Data(#"{"audio_base64":"!!!"}"#.utf8)) }
        do {
            _ = try await client.synthesize("Hi", settings: settings())
            XCTFail("Expected invalid response")
        } catch { XCTAssertEqual(error as? SpeechClient.Failure, .invalidResponse) }
    }

    private func settings() -> ReaderSettings {
        ReaderSettings(voiceID: "testVoice", model: .natural, speed: 1, offersSelection: true)
    }

    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

final class SpeechStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
