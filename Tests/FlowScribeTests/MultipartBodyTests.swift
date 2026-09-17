import XCTest
@testable import FlowScribe

final class MultipartBodyTests: XCTestCase {
    func testContainsModelFieldAndFilePart() {
        let (body, boundary) = MultipartBody.make(fileData: Data([0x01, 0x02, 0x03]),
                                                  fileName: "audio.wav",
                                                  model: "gpt-transcribe")
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("--\(boundary)"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.range(of: Data([0x01, 0x02, 0x03])) != nil, "raw file bytes must be present verbatim")
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
    }

    func testBoundariesAreUniquePerCall() {
        let (_, b1) = MultipartBody.make(fileData: Data(), model: "m")
        let (_, b2) = MultipartBody.make(fileData: Data(), model: "m")
        XCTAssertNotEqual(b1, b2, "a fresh boundary per request avoids content collisions")
    }

    func testBoundaryNeverCollidesWithFileData() {
        let hostile = Data("Content-Disposition: form-data; name=\"evil\"\r\n".utf8)
        let (body, boundary) = MultipartBody.make(fileData: hostile, model: "m")
        // The only boundary delimiters are the ones framing the parts.
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "--\(boundary)").count - 1, 3)
    }

    func testLanguageFieldIncludedWhenProvided() {
        let (body, boundary) = MultipartBody.make(fileData: Data(), model: "gpt-transcribe", language: "en")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(text.contains("--\(boundary)"))
    }
}
