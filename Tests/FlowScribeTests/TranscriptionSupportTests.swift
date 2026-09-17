import XCTest
@testable import FlowScribe

final class TranscriptionSupportTests: XCTestCase {
    // MARK: Model resolution

    func testDefaultModelIsGptTranscribe() {
        XCTAssertEqual(TranscriptionSupport.resolveModel(environment: [:]), "gpt-transcribe")
    }

    func testEnvironmentModelOverridesDefault() {
        XCTAssertEqual(TranscriptionSupport.resolveModel(environment: ["OPENAI_TRANSCRIBE_MODEL": "whisper-1"]),
                       "whisper-1")
    }

    func testBlankModelFallsBackToDefault() {
        XCTAssertEqual(TranscriptionSupport.resolveModel(environment: ["OPENAI_TRANSCRIBE_MODEL": "   "]),
                       "gpt-transcribe")
        XCTAssertEqual(TranscriptionSupport.resolveModel(environment: ["OPENAI_TRANSCRIBE_MODEL": ""]),
                       "gpt-transcribe")
    }

    func testModelOverrideIsTrimmed() {
        XCTAssertEqual(TranscriptionSupport.resolveModel(environment: ["OPENAI_TRANSCRIBE_MODEL": "  whisper-1 \n"]),
                       "whisper-1")
    }

    // MARK: Too-short detection

    func testSilenceOrTinyInputIsTooShort() {
        XCTAssertTrue(TranscriptionSupport.isTooShort(pcmByteCount: 0, sampleRate: 16_000))
        XCTAssertTrue(TranscriptionSupport.isTooShort(pcmByteCount: 100, sampleRate: 16_000))
    }

    func testHealthyInputIsNotTooShort() {
        // 1 second of 16 kHz mono 16-bit = 32000 bytes
        XCTAssertFalse(TranscriptionSupport.isTooShort(pcmByteCount: 32_000, sampleRate: 16_000))
        // Exactly at the 0.3 s threshold = 9600 bytes
        XCTAssertFalse(TranscriptionSupport.isTooShort(pcmByteCount: 9_600, sampleRate: 16_000))
        // Just under the threshold
        XCTAssertTrue(TranscriptionSupport.isTooShort(pcmByteCount: 9_599, sampleRate: 16_000))
    }

    func testDegenerateParametersAreTooShort() {
        XCTAssertTrue(TranscriptionSupport.isTooShort(pcmByteCount: 32_000, sampleRate: 0))
        XCTAssertTrue(TranscriptionSupport.isTooShort(pcmByteCount: 32_000, sampleRate: -1))
    }

    // MARK: Response parsing

    func testParsesTextFromTranscriptionResponse() {
        let json = #"{"text":"Hello, world."}"#.data(using: .utf8)!
        XCTAssertEqual(TranscriptionSupport.parseText(from: json), "Hello, world.")
    }

    func testParseRejectsMissingTextField() {
        let json = #"{"error":{"message":"nope"}}"#.data(using: .utf8)!
        XCTAssertNil(TranscriptionSupport.parseText(from: json))
    }

    func testParseRejectsNonJSON() {
        XCTAssertNil(TranscriptionSupport.parseText(from: Data("not json".utf8)))
        XCTAssertNil(TranscriptionSupport.parseText(from: Data()))
    }
}
