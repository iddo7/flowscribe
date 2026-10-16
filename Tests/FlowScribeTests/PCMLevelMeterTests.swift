import XCTest
@testable import FlowScribe

final class PCMLevelMeterTests: XCTestCase {
    func testSilenceAndRoomNoiseStayAtRest() {
        for sample: Int16 in [0, 1, -1, 32, -32] {
            var meter = PCMLevelMeter()
            XCTAssertEqual(meter.consume(pcm(sample)), [0])
        }
    }

    func testSpeechHasHeadroomAndLouderAudioProducesHigherLevels() throws {
        var meter = PCMLevelMeter()
        let quiet = try XCTUnwrap(meter.consume(pcm(200)).first)
        let speech = try XCTUnwrap(meter.consume(pcm(2_000)).first)
        let loud = try XCTUnwrap(meter.consume(pcm(8_000)).first)
        let veryLoud = try XCTUnwrap(meter.consume(pcm(20_000)).first)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(speech, quiet)
        XCTAssertGreaterThan(loud, speech)
        XCTAssertGreaterThan(veryLoud, loud)
        XCTAssertLessThan(loud, 0.7, "Speech peaks must not flatten the waveform")
        XCTAssertLessThan(veryLoud, 0.9)
        XCTAssertEqual(meter.consume(pcm(0)), [0])
    }

    func testSignedSamplesAndFullScaleStayFiniteAndBounded() throws {
        for sample: Int16 in [200, 2_000, 8_000] {
            var positive = PCMLevelMeter()
            var negative = PCMLevelMeter()
            XCTAssertEqual(positive.consume(pcm(sample)), negative.consume(pcm(-sample)))
        }
        for sample in [Int16.min, Int16.max] {
            var meter = PCMLevelMeter()
            let level = try XCTUnwrap(meter.consume(pcm(sample)).first)
            XCTAssertEqual(level, 1, accuracy: 0.000_01)
            XCTAssertLessThanOrEqual(level, 1)
        }
    }

    func testWindowSurvivesSmallHardwareBuffers() {
        var whole = PCMLevelMeter()
        let expected = whole.consume(pcm(1_000))
        var split = PCMLevelMeter()
        XCTAssertTrue(split.consume(Data()).isEmpty)
        for _ in 0..<9 {
            XCTAssertTrue(split.consume(pcm(1_000, count: 32)).isEmpty)
        }
        XCTAssertEqual(split.consume(pcm(1_000, count: 32)), expected)
    }

    func testLargeCallbackPreservesBothPeaksAndDips() {
        var meter = PCMLevelMeter()
        let levels = meter.consume(pcm(0) + pcm(Int16.min) + pcm(0) + pcm(2_000))
        XCTAssertEqual(levels.count, 4)
        XCTAssertEqual(Array(levels.prefix(3)), [0, 1, 0])
        XCTAssertGreaterThan(levels[3], 0)
        XCTAssertLessThan(levels[3], 1)
    }

    func testRetiredStreamsCannotUpdateMeterOrLeavePartialAudio() {
        let buffer = RecordingPCMBuffer()
        let first = UUID()
        let second = UUID()
        buffer.activate(streamID: first)
        XCTAssertTrue(buffer.append(pcm(8_000, count: 160), streamID: first).isEmpty)
        buffer.activate(streamID: second)
        XCTAssertFalse(buffer.isActive(streamID: first))
        XCTAssertTrue(buffer.isActive(streamID: second))
        XCTAssertTrue(buffer.append(pcm(8_000), streamID: first).isEmpty)
        XCTAssertTrue(buffer.append(pcm(0, count: 160), streamID: second).isEmpty)
        XCTAssertEqual(buffer.append(pcm(0, count: 160), streamID: second), [0])
        _ = buffer.finish()
        XCTAssertFalse(buffer.isActive(streamID: second))
        XCTAssertTrue(buffer.append(pcm(8_000), streamID: second).isEmpty)
    }

    private func pcm(_ sample: Int16, count: Int = 320) -> Data {
        let bits = UInt16(bitPattern: sample)
        return Data((0..<count).flatMap { _ in [UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)] })
    }
}
