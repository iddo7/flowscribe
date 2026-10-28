import AppKit
import XCTest
@testable import FlowScribe

@MainActor
final class ReaderControllerTests: XCTestCase {
    private func makeReader(responseHasTiming: Bool = true,
                            makePlayer: @escaping @MainActor (Data) throws -> any ReaderAudioPlaying) -> ReaderController {
        _ = NSApplication.shared
        SpeechStubProtocol.handler = { request in
            let text: String
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                text = json["text"] as? String ?? "Hello hello again."
            } else { text = "Hello hello again." }
            var response: [String: Any] = ["audio_base64": Data("fake audio".utf8).base64EncodedString()]
            if responseHasTiming {
                let characters = text.map(String.init)
                response["alignment"] = [
                    "characters": characters,
                    "character_start_times_seconds": characters.indices.map { Double($0) * 0.1 },
                    "character_end_times_seconds": characters.indices.map { Double($0 + 1) * 0.1 }
                ]
            }
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechStubProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config), keyReader: { "fake-key" }, usageStore: UsageStore(defaults: nil))
        return ReaderController(client: client, makePlayer: makePlayer)
    }

    private var selection: ReadingAccessibility.Selection {
        .init(text: "Hello hello again.", processID: -1, element: nil, range: nil,
              markerRange: nil, markerIndex: nil, anchor: nil, isLink: false)
    }

    func testPauseWhileLoadingDoesNotAutoplayWhenAudioArrives() async {
        let ready = expectation(description: "Audio prepared")
        let audio = FakeReadingAudio()
        let reader = makeReader { _ in ready.fulfill(); return audio }
        reader.start(selection)
        reader.toggle() // Pause before the async request starts.
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(reader.isActive)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.playCount, 0)
        reader.toggle()
        XCTAssertTrue(audio.isPlaying)
        reader.stop()
        XCTAssertFalse(reader.isActive)
        XCTAssertFalse(audio.isPlaying)
    }

    func testClickSeekMovesForwardAndBackwardWithoutRegeneration() async {
        let ready = expectation(description: "Audio prepared")
        let audio = FakeReadingAudio()
        var creations = 0
        let reader = makeReader { _ in creations += 1; ready.fulfill(); return audio }
        reader.start(selection)
        await fulfillment(of: [ready], timeout: 2)
        reader.seek(to: 13) // Inside "again".
        XCTAssertEqual(audio.currentTime, 1.2, accuracy: 0.001)
        reader.toggle()
        XCTAssertFalse(audio.isPlaying)
        reader.seek(to: 7) // Inside the second "hello"; seeking resumes.
        XCTAssertEqual(audio.currentTime, 0.6, accuracy: 0.001)
        XCTAssertTrue(audio.isPlaying)
        reader.seek(to: 1)
        XCTAssertEqual(audio.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(creations, 1)
        reader.stop()
    }

    func testStoppingImmediatelyCancelsLoadingWithoutStartingAudioOrShowingAnError() async throws {
        let unexpected = expectation(description: "No audio or error after stop")
        unexpected.isInverted = true
        let reader = makeReader { _ in unexpected.fulfill(); return FakeReadingAudio() }
        reader.onFailure = { _ in unexpected.fulfill() }
        reader.start(selection)
        reader.stop()
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertFalse(reader.isActive)
    }

    func testMissingAlignmentCanStillSeekByGeneratingFromTheClickedWord() async {
        let first = expectation(description: "Initial audio")
        let second = expectation(description: "Audio after seek")
        var creations = 0
        let reader = makeReader(responseHasTiming: false) { _ in
            creations += 1
            if creations == 1 { first.fulfill() } else { second.fulfill() }
            return FakeReadingAudio()
        }
        reader.start(selection)
        await fulfillment(of: [first], timeout: 2)
        reader.seek(to: 13)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertTrue(reader.isActive)
        reader.stop()
    }
}

@MainActor
private final class FakeReadingAudio: ReaderAudioPlaying {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10
    var rate: Float = 1
    var isPlaying = false
    var onFinished: ((Bool) -> Void)?
    var playCount = 0
    func play() -> Bool { isPlaying = true; playCount += 1; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func level() -> Double { 0 }
}
