import Foundation

/// Pure helper building a WAV file header for 16-bit mono PCM. Unit-testable.
enum WAVHeader {
    static let headerByteCount = 44

    /// Returns the 44-byte canonical RIFF/WAVE header for the given PCM parameters.
    static func make(sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16, dataBytes: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data(capacity: headerByteCount)
        func append(_ s: String) { header.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 4))
        }
        func append16(_ v: UInt16) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 2))
        }

        append("RIFF")
        append32(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append32(16) // PCM fmt chunk size
        append16(1)  // audio format: PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))
        append("data")
        append32(UInt32(dataBytes))
        precondition(header.count == headerByteCount)
        return header
    }

    /// Rewrites the RIFF/data length fields of an existing WAV buffer in place.
    static func finalize(_ wav: inout Data, dataBytes: Int) {
        guard wav.count >= headerByteCount else { return }
        func littleEndianBytes(_ value: UInt32) -> Data {
            var littleEndian = value.littleEndian
            return withUnsafeBytes(of: &littleEndian) { Data($0) }
        }
        wav.replaceSubrange(4..<8, with: littleEndianBytes(UInt32(36 + dataBytes)))
        wav.replaceSubrange(40..<44, with: littleEndianBytes(UInt32(dataBytes)))
    }
}
