import XCTest
@testable import FlowScribe

final class APIKeyStoreTests: XCTestCase {
    // NOTE: Keychain mutation is intentionally not exercised in unit tests to
    // avoid touching the developer's real login keychain. The env-resolution
    // logic below is fully hermetic.

    func testEnvironmentKeyWinsAndIsTrimmed() {
        XCTAssertEqual(
            APIKeyStore.resolveKey(
                environment: ["OPENAI_API_KEY": "  sk-test  "],
                keychainReader: { "should-not-be-read" }
            ),
            "sk-test"
        )
    }

    func testBlankEnvironmentValueFallsThroughToKeychain() {
        XCTAssertNil(APIKeyStore.resolveKey(
            environment: ["OPENAI_API_KEY": "   "],
            keychainReader: { nil }
        ))
    }

    func testMissingEnvironmentValueFallsThroughToKeychain() {
        XCTAssertEqual(APIKeyStore.resolveKey(
            environment: [:],
            keychainReader: { "sk-from-keychain" }
        ), "sk-from-keychain")
    }

    func testConstantsAreStable() {
        XCTAssertEqual(APIKeyStore.keychainService, "com.flowscribe.app")
        XCTAssertEqual(APIKeyStore.keychainAccount, "openai-api-key")
        XCTAssertEqual(APIKeyStore.environmentKey, "OPENAI_API_KEY")
        XCTAssertEqual(TranscriptionSupport.modelEnvironmentKey, "OPENAI_TRANSCRIBE_MODEL")
    }
}
