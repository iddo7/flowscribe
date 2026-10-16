import XCTest
@testable import FlowScribe

final class PCMLevelMeterTests: XCTestCase {
    func testSilenceAndRoomNoiseStayAtRest() {
        for sample: Int16 in [0, 1, -1, 32, -32] {
            var meter = PCMLevelMeter()
            XCTAssertEqual(meter.consume(pcm(sample)), 0)
        }
    }

    func testLouderAudioProducesHigherLevels() throws {
        var meter = PCMLevelMeter()
        let quiet = try XCTUnwrap(meter.consume(pcm(200)))
        let speech = try XCTUnwrap(meter.consume(pcm(2_000)))
        let loud = try XCTUnwrap(meter.consume(pcm(8_000)))
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(speech, quiet)
        XCTAssertGreaterThan(loud, speech)
        XCTAssertLessThanOrEqual(loud, 1)
        XCTAssertEqual(meter.consume(pcm(0)), 0, "Silence must not retain the previous signal")
    }

    func testSignedSamplesAndFullScaleStayFiniteAndBounded() throws {
        for sample: Int16 in [200, 2_000, 8_000] {
            var positive = PCMLevelMeter()
            var negative = PCMLevelMeter()
            XCTAssertEqual(positive.consume(pcm(sample)), negative.consume(pcm(-sample)))
        }
        for sample in [Int16.min, Int16.max] {
            var meter = PCMLevelMeter()
            XCTAssertEqual(try XCTUnwrap(meter.consume(pcm(sample))), 1)
        }
    }

    func testWindowSurvivesSmallHardwareBuffers() throws {
        var whole = PCMLevelMeter()
        let expected = try XCTUnwrap(whole.consume(pcm(1_000)))
        var split = PCMLevelMeter()
        XCTAssertNil(split.consume(Data()))
        for _ in 0..<9 {
            XCTAssertNil(split.consume(pcm(1_000, count: 32)))
        }
        XCTAssertEqual(try XCTUnwrap(split.consume(pcm(1_000, count: 32))), expected, accuracy: 0.000_001)
    }

    func testShortSignalIsNotLostInsideALargeCallback() throws {
        var meter = PCMLevelMeter()
        XCTAssertEqual(try XCTUnwrap(meter.consume(pcm(0) + pcm(Int16.max) + pcm(0))), 1)
    }

    func testRetiredStreamsCannotUpdateMeterOrLeavePartialAudio() throws {
        let buffer = RecordingPCMBuffer()
        let first = UUID()
        let second = UUID()
        buffer.activate(streamID: first)
        XCTAssertNil(buffer.append(pcm(8_000, count: 160), streamID: first))
        buffer.activate(streamID: second)
        XCTAssertFalse(buffer.isActive(streamID: first))
        XCTAssertTrue(buffer.isActive(streamID: second))
        XCTAssertNil(buffer.append(pcm(8_000), streamID: first))
        XCTAssertNil(buffer.append(pcm(0, count: 160), streamID: second))
        XCTAssertEqual(buffer.append(pcm(0, count: 160), streamID: second), 0)
        _ = buffer.finish()
        XCTAssertFalse(buffer.isActive(streamID: second))
        XCTAssertNil(buffer.append(pcm(8_000), streamID: second))
    }

    private func pcm(_ sample: Int16, count: Int = 320) -> Data {
        let bits = UInt16(bitPattern: sample)
        return Data((0..<count).flatMap { _ in [UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)] })
    }
}
