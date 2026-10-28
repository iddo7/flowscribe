import AppKit
import XCTest
@testable import FlowScribe

@MainActor
final class ReaderSettingsViewTests: XCTestCase {
    private func preferences() -> (UserDefaults, () -> Void) {
        let name = "FlowScribe.VoiceSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func client(_ handler: @escaping (URLRequest) -> Void = { _ in XCTFail("Unexpected request") }) -> SpeechClient {
        VoiceSettingsStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSettingsStubProtocol.self]
        return SpeechClient(session: URLSession(configuration: config), keyReader: { "fake-key" }, usageStore: UsageStore(defaults: nil))
    }

    func testPastingVoiceIDImmediatelySavesItAndUpdatesTheSelectedMenuItem() {
        _ = NSApplication.shared
        let (defaults, cleanup) = preferences()
        defer { cleanup() }
        let view = ReaderSettingsView(defaults: defaults, client: client())
        view.voiceID.stringValue = "  newFrenchVoice123456  "
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.voiceID))
        XCTAssertEqual(ReaderSettings.load(defaults: defaults).voiceID, "newFrenchVoice123456")
        XCTAssertEqual(view.voices.selectedItem?.representedObject as? String, "newFrenchVoice123456")
        XCTAssertTrue(view.voices.titleOfSelectedItem?.contains("Custom voice") == true)
        XCTAssertFalse(view.voices.titleOfSelectedItem?.contains("George") == true)
        XCTAssertTrue(view.previewButton.isEnabled)
    }

    func testPreviewUsesUncommittedFieldEditorVoiceInsteadOfThePreviousVoice() async throws {
        _ = NSApplication.shared
        let (defaults, cleanup) = preferences()
        defer { cleanup() }
        let played = expectation(description: "Preview with new ID")
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v1/text-to-speech/newFrenchVoice123456/with-timestamps")
        }
        let view = ReaderSettingsView(defaults: defaults, client: client, makePlayer: { _ in
            played.fulfill()
            return FakeVoiceSample()
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view.voiceID))
        let editor = try XCTUnwrap(view.voiceID.currentEditor())
        editor.string = "newFrenchVoice123456" // No end-editing notification before the click.
        view.previewButton.performClick(nil)
        await fulfillment(of: [played], timeout: 2)
        XCTAssertEqual(ReaderSettings.load(defaults: defaults).voiceID, "newFrenchVoice123456")
        XCTAssertEqual(view.voices.selectedItem?.representedObject as? String, "newFrenchVoice123456")
        window.makeFirstResponder(nil)
    }

    func testChangingTheIDStopsAudioFromTheOldVoice() async {
        _ = NSApplication.shared
        let (defaults, cleanup) = preferences()
        defer { cleanup() }
        let ready = expectation(description: "Original sample prepared")
        let sample = FakeVoiceSample()
        let view = ReaderSettingsView(defaults: defaults, client: client { _ in }, makePlayer: { _ in
            ready.fulfill()
            return sample
        })
        view.previewButton.performClick(nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(sample.isPlaying)
        view.voiceID.stringValue = "anotherFrenchVoice"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.voiceID))
        XCTAssertFalse(sample.isPlaying)
        XCTAssertEqual(ReaderSettings.load(defaults: defaults).voiceID, "anotherFrenchVoice")
    }

    func testInvalidPastesKeepTheSavedVoiceAndCannotPreviewTheOldVoiceSilently() {
        _ = NSApplication.shared
        let (defaults, cleanup) = preferences()
        defer { cleanup() }
        let view = ReaderSettingsView(defaults: defaults, client: client())
        let original = ReaderSettings.load(defaults: defaults).voiceID
        for invalid in ["", "https://elevenlabs.io/app/voice-library", "sk_fake-api-key", "sk-fake-api-key", "voice/name"] {
            view.voiceID.stringValue = invalid
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.voiceID))
            XCTAssertEqual(ReaderSettings.load(defaults: defaults).voiceID, original)
            XCTAssertEqual(view.voices.selectedItem?.representedObject as? String, original)
            XCTAssertFalse(view.previewButton.isEnabled)
        }
    }
}

@MainActor
private final class FakeVoiceSample: ReaderAudioPlaying {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 5
    var rate: Float = 1
    var isPlaying = false
    var onFinished: ((Bool) -> Void)?
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func level() -> Double { 0 }
}

private final class VoiceSettingsStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"audio_base64":"YXVkaW8="}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
