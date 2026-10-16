import Foundation

/// Measures the same 16 kHz, mono, signed 16-bit little-endian PCM sent to transcription.
/// Fixed 20 ms windows keep sensitivity independent of hardware callback size.
struct PCMLevelMeter {
    private let samplesPerWindow = 320
    private var sampleCount = 0
    private var sumOfSquares = 0.0

    /// Returns the strongest completed window, or nil until a full window is captured.
    mutating func consume(_ pcm: Data) -> Double? {
        var level: Double?
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let sample = Double(Int16(bitPattern: bits)) / 32_768
                sumOfSquares += sample * sample
                sampleCount += 1
                if sampleCount == samplesPerWindow {
                    let rms = sqrt(sumOfSquares / Double(samplesPerWindow))
                    // A fixed dB range leaves quiet rooms still and makes ordinary speech readable.
                    let decibels = 20 * log10(max(rms, 0.000_001))
                    let normalized = min(1, max(0, (decibels + 55) / 45))
                    level = max(level ?? 0, normalized)
                    sampleCount = 0
                    sumOfSquares = 0
                }
            }
        }
        return level
    }
}
