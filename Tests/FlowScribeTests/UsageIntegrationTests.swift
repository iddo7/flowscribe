import XCTest
@testable import FlowScribe

final class UsageIntegrationTests: XCTestCase {
    private func session(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> URLSession {
        UsageStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageStubProtocol.self]
        return URLSession(configuration: config)
    }

    func testSpeechCreditsAndConfirmedUsageAreRecordedEvenIfAudioCannotBeDecoded() async {
        let store = UsageStore(defaults: nil)
        let client = SpeechClient(session: session { _ in (200, ["character-cost": "3"], Data("invalid response".utf8)) },
                                  keyReader: { "fake-key" }, usageStore: store)
        do {
            _ = try await client.synthesize("é👋", settings: .init(voiceID: "test", model: .natural, speed: 1, offersSelection: false))
            XCTFail("Expected decoding failure")
        } catch { XCTAssertEqual(error as? SpeechClient.Failure, .invalidResponse) }
        let totals = store.snapshot().totals()
        XCTAssertEqual(totals.requests, 1)
        XCTAssertEqual(totals.characters, 2) // Scalar count, neither UTF-16 units nor bytes.
        XCTAssertEqual(totals.reportedCredits, 3)
    }

    func testNetworkFailureRecordsUnconfirmedBillingInsteadOfZeroCost() async {
        let store = UsageStore(defaults: nil)
        let client = SpeechClient(session: session { _ in throw URLError(.networkConnectionLost) },
                                  keyReader: { "fake-key" }, usageStore: store)
        do {
            _ = try await client.synthesize("Hello", settings: .init(voiceID: "test", model: .natural, speed: 1, offersSelection: false))
            XCTFail("Expected network failure")
        } catch { XCTAssertEqual(error as? SpeechClient.Failure, .network) }
        XCTAssertEqual(store.snapshot().totals().unconfirmedRequests, 1)
        XCTAssertEqual(store.snapshot().totals().requests, 0)
    }

    func testSubscriptionPermissionFailureDoesNotSuggestInvalidKeyOrRecordPaidUsage() async {
        let store = UsageStore(defaults: nil)
        let client = SpeechClient(session: session { _ in
            (401, [:], Data(#"{"detail":{"status":"missing_permissions","message":"private server content"}}"#.utf8))
        }, keyReader: { "fake-key" }, usageStore: store)
        do {
            _ = try await client.subscription()
            XCTFail("Expected permission error")
        } catch {
            XCTAssertEqual(error as? SpeechClient.Failure, .permission(.account))
            XCTAssertTrue(error.localizedDescription.contains("User: Read"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
        XCTAssertTrue(store.snapshot().buckets.isEmpty)
    }

    func testSubscriptionDecodesAccountValuesWithoutMixingThemIntoLocalTotals() async throws {
        let store = UsageStore(defaults: nil)
        let client = SpeechClient(session: session { request in
            XCTAssertEqual(request.url?.path, "/v1/user/subscription")
            return (200, [:], Data(#"{"tier":"starter","character_count":1234,"character_limit":30000,"currency":"usd","next_invoice":{"amount_due_cents":500},"next_character_count_reset_unix":1800000000}"#.utf8))
        }, keyReader: { "fake-key" }, usageStore: store)
        let subscription = try await client.subscription()
        XCTAssertEqual(subscription.characterCount, 1234)
        XCTAssertEqual(subscription.nextInvoice?.amountDueCents, 500)
        XCTAssertTrue(store.snapshot().buckets.isEmpty)
    }

    func testDictationMeasuresUploadedAudioAndExcludesHTTPRejections() async throws {
        let store = UsageStore(defaults: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-test-\(UUID()).wav")
        var wav = WAVHeader.make(sampleRate: 16_000, dataBytes: 32_000)
        wav.append(Data(repeating: 0, count: 32_000))
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let environment = ["OPENAI_API_KEY": "fake-key", "OPENAI_TRANSCRIBE_MODEL": "gpt-transcribe"]
        let success = TranscriptionClient(session: session { _ in (200, [:], Data(#"{"text":"Hello"}"#.utf8)) }, environment: environment, usageStore: store)
        _ = try await success.transcribe(fileAt: url)
        XCTAssertEqual(store.snapshot().totals().audioSeconds, 1)
        XCTAssertEqual(store.snapshot().totals().estimatedUSD, 0.0045 / 60, accuracy: 0.0000001)
        let rejected = TranscriptionClient(session: session { _ in (401, [:], Data("{}".utf8)) }, environment: environment, usageStore: store)
        do { _ = try await rejected.transcribe(fileAt: url); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(store.snapshot().totals().requests, 1)
        XCTAssertEqual(store.snapshot().totals().unconfirmedRequests, 0)
    }
}

private final class UsageStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
