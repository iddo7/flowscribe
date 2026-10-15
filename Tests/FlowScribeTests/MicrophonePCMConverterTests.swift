import AVFoundation
import XCTest
@testable import FlowScribe

final class MicrophonePCMConverterTests: XCTestCase {
    func testCommonHardwareFormatsProduceReal16kMonoAudio() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                         sampleRate: rate, channels: channels,
                                                         interleaved: false))
                for frames: AVAudioFrameCount in [256, 1024, 4096, 4800, 8192] {
                    let converter = try MicrophonePCMConverter(inputFormat: format)
                    var pcm = Data()
                    let chunks = Int(rate / Double(frames))
                    for chunk in 0..<chunks {
                        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                        buffer.frameLength = frames
                        let data = try XCTUnwrap(buffer.floatChannelData)
                        for channel in 0..<Int(channels) {
                            for frame in 0..<Int(frames) {
                                let time = Double(chunk * Int(frames) + frame) / rate
                                data[channel][frame] = Float(0.25 * sin(2 * .pi * 440 * time))
                            }
                        }
                        if let result = converter.convert(buffer) { pcm.append(result) }
                    }
                    let expectedBytes = Double(chunks * Int(frames)) / rate * 32_000
                    XCTAssertEqual(Double(pcm.count), expectedBytes, accuracy: 512,
                                   "Missing audio at \(rate) Hz, \(channels) channels, \(frames) frames")
                    XCTAssertTrue(pcm.contains { $0 != 0 }, "The recorded tone must contain a signal")
                    XCTAssertEqual(pcm.count % MemoryLayout<Int16>.size, 0)
                }
            }
        }
    }

    func testEmptyAndRetiredFormatBuffersAreRejected() throws {
        let original = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                  channels: 1, interleaved: false))
        let converter = try MicrophonePCMConverter(inputFormat: original)
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: original, frameCapacity: 1024))
        XCTAssertNil(converter.convert(empty))
        let changed = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                                 channels: 1, interleaved: false))
        let retired = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 1024))
        retired.frameLength = 1024
        XCTAssertNil(converter.convert(retired))
    }

    func testCapturedPlanarBytesSurviveProcessingQueueHandoff() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: 2, interleaved: false))
        let converter = try MicrophonePCMConverter(inputFormat: format)
        let samples = [Float](repeating: 0.25, count: 4_800 * 2)
        let captured = samples.withUnsafeBytes { Data($0) }
        let pcm = try XCTUnwrap(converter.convert(planarSamples: captured, frameCount: 4_800))
        // The resampler buffers a short prefix while priming. Subsequent chunks
        // must deliver the full 100 ms, with both planar channels intact.
        XCTAssertGreaterThan(pcm.count, 0)
        XCTAssertLessThanOrEqual(pcm.count, 3_200)
        XCTAssertTrue(pcm.contains { $0 != 0 })
        let next = try XCTUnwrap(converter.convert(planarSamples: captured, frameCount: 4_800))
        XCTAssertEqual(next.count, 3_200)
        XCTAssertTrue(next.contains { $0 != 0 })
        XCTAssertNil(converter.convert(planarSamples: captured.dropLast(), frameCount: 4_800))
        XCTAssertNil(converter.convert(planarSamples: Data(), frameCount: 0))
    }
}
