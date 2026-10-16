import Foundation

/// Measures the same 16 kHz, mono, signed 16-bit little-endian PCM sent to transcription.
/// Fixed 20 ms windows keep sensitivity independent of hardware callback size.
struct PCMLevelMeter {
    private let samplesPerWindow = 320
    private var sampleCount = 0
    private var sumOfSquares = 0.0

    /// Preserve every completed window, including dips within a large hardware callback.
    mutating func consume(_ pcm: Data) -> [Double] {
        var levels: [Double] = []
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let sample = Double(Int16(bitPattern: bits)) / 32_768
                sumOfSquares += sample * sample
                sampleCount += 1
                if sampleCount == samplesPerWindow {
                    let rms = sqrt(sumOfSquares / Double(samplesPerWindow))
                    // Reserve full height for full-scale audio; ordinary speech needs headroom.
                    let decibels = 20 * log10(max(rms, 0.000_001))
                    let normalized = min(1, max(0, (decibels + 55) / 55))
                    levels.append(pow(normalized, 1.8))
                    sampleCount = 0
                    sumOfSquares = 0
                }
            }
        }
        return levels
    }
}
