import XCTest
@testable import FlowScribe

final class WAVHeaderTests: XCTestCase {
    func testHeaderIsCanonical44Bytes() {
        let header = WAVHeader.make(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 3200)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: header.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: header.subdata(in: 36..<40), encoding: .ascii), "data")
    }

    func testHeaderFieldsFor16kMono16Bit() {
        let header = WAVHeader.make(sampleRate: 16_000, dataBytes: 32_000)
        // Compose little-endian values manually: Data storage alignment is not guaranteed.
        let u32 = { (offset: Int) -> UInt32 in
            let b = [UInt8](header.subdata(in: offset..<offset+4))
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }
        let u16 = { (offset: Int) -> UInt16 in
            let b = [UInt8](header.subdata(in: offset..<offset+2))
            return UInt16(b[0]) | UInt16(b[1]) << 8
        }
        XCTAssertEqual(u32(4), 36 + 32_000)            // RIFF chunk size
        XCTAssertEqual(u16(20), 1)                      // PCM
        XCTAssertEqual(u16(22), 1)                      // mono
        XCTAssertEqual(u32(24), 16_000)                 // sample rate
        XCTAssertEqual(u32(28), 32_000)                 // byte rate = 16000 * 1 * 2
        XCTAssertEqual(u16(32), 2)                      // block align
        XCTAssertEqual(u16(34), 16)                     // bits per sample
        XCTAssertEqual(u32(40), 32_000)                 // data size
    }

    func testFinalizeRewritesLengths() {
        var wav = WAVHeader.make(sampleRate: 16_000, dataBytes: 0)
        wav.append(Data(repeating: 0x7F, count: 1000))
        WAVHeader.finalize(&wav, dataBytes: 1000)
        func le32(_ data: Data, _ offset: Int) -> UInt32 {
            let b = [UInt8](data.subdata(in: offset..<offset+4))
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }
        XCTAssertEqual(le32(wav, 4), UInt32(36 + 1000))
        XCTAssertEqual(le32(wav, 40), 1000)
        XCTAssertEqual(wav.count, 44 + 1000)
    }

    func testFinalizeIgnoresShortBuffer() {
        var tiny = Data(repeating: 0, count: 10)
        WAVHeader.finalize(&tiny, dataBytes: 10)
        XCTAssertEqual(tiny.count, 10)
    }
}
