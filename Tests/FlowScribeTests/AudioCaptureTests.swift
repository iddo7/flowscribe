import XCTest
@testable import FlowScribe

final class AudioCaptureTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in")
    private let headset = AudioInputDevice(id: 2, uid: "headset", name: "Headset")

    func testAudioLevelsFollowCapturedPCMOnMainQueue() throws {
        let engine = FakeCaptureEngine(pcm: Data(repeating: 0, count: 640))
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engine },
                                   observeDeviceChanges: false)
        let session = UUID()
        let silence = expectation(description: "silent microphone")
        capture.onAudioLevels = { receivedSession, levels in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(receivedSession, session)
            XCTAssertEqual(levels, [0])
            silence.fulfill()
        }
        start(capture, session: session)
        wait(for: [silence], timeout: 3)

        let loud = expectation(description: "loud microphone")
        capture.onAudioLevels = { receivedSession, levels in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(receivedSession, session)
            XCTAssertEqual(levels.count, 1)
            XCTAssertGreaterThan(levels[0], 0.99)
            loud.fulfill()
        }
        engine.onPCM?(Data(repeating: 127, count: 640))
        wait(for: [loud], timeout: 3)
        XCTAssertNil(try stop(capture, session: session))

        let late = expectation(description: "retired microphone must not update the HUD")
        late.isInverted = true
        capture.onAudioLevels = { _, _ in late.fulfill() }
        engine.onPCM?(Data(repeating: 127, count: 640))
        wait(for: [late], timeout: 0.05)
    }

    func testRouteChangeRebuildsEngineAndPreservesAudio() throws {
        let source = DeviceSource(headset)
        let first = FakeCaptureEngine(pcm: Data(repeating: 1, count: 6_000))
        let second = FakeCaptureEngine(pcm: Data(repeating: 2, count: 6_000))
        var engines = [first, second]
        let capture = AudioCapture(resolveDevice: { source.get() }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        source.set(builtIn)
        first.configurationChanged?()
        let wav = try stop(capture, session: session)
        XCTAssertEqual(first.startedDeviceID, headset.id)
        XCTAssertEqual(second.startedDeviceID, builtIn.id)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(wav?.dropFirst(WAVHeader.headerByteCount),
                       Data(repeating: 1, count: 6_000) + Data(repeating: 2, count: 6_000))
    }

    func testSameDeviceFormatChangeAlsoRebuildsEngine() throws {
        let first = FakeCaptureEngine(pcm: Data(repeating: 1, count: 5_000))
        let second = FakeCaptureEngine(pcm: Data(repeating: 2, count: 5_000))
        var engines = [first, second]
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        first.configurationChanged?()
        XCTAssertEqual(try stop(capture, session: session)?.count, WAVHeader.headerByteCount + 10_000)
        XCTAssertEqual(second.startedDeviceID, builtIn.id)
    }

    func testHealthyStartupNotificationDoesNotCreateRestartLoop() throws {
        let engine = FakeCaptureEngine(pcm: Data(repeating: 1, count: 10_000))
        engine.inputFormatIsCurrent = true
        var engineCount = 0
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: {
            engineCount += 1
            return engine
        }, observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        engine.configurationChanged?()
        engine.configurationChanged?()
        XCTAssertNotNil(try stop(capture, session: session))
        XCTAssertEqual(engineCount, 1)
    }

    func testNoAudioIsReportedAsInputFailureRatherThanShortRecording() {
        let engine = FakeCaptureEngine(pcm: Data())
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engine },
                                   observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        let stopped = expectation(description: "no audio")
        capture.stop(sessionID: session) { result in
            switch result {
            case .failure(let error):
                XCTAssertTrue(error is AudioCapture.CaptureError)
                XCTAssertTrue(error.localizedDescription.contains("no audio"))
            case .success:
                XCTFail("A microphone supplying no samples must report an input failure")
            }
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 3)
    }

    func testDefaultOrManualDeviceChangeDoesNotRequireAnEngineNotification() throws {
        let source = DeviceSource(builtIn)
        let first = FakeCaptureEngine(pcm: Data(repeating: 1, count: 5_000))
        let second = FakeCaptureEngine(pcm: Data(repeating: 2, count: 5_000))
        var engines = [first, second]
        let capture = AudioCapture(resolveDevice: { source.get() }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        source.set(headset)
        capture.refreshInputDevice()
        XCTAssertNotNil(try stop(capture, session: session))
        XCTAssertEqual(second.startedDeviceID, headset.id)
    }

    func testUnrelatedInventoryChangeDoesNotInterruptSelectedMicrophone() throws {
        let engine = FakeCaptureEngine(pcm: Data(repeating: 1, count: 10_000))
        var engineCount = 0
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: {
            engineCount += 1
            return engine
        }, observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        capture.refreshInputDevice()
        XCTAssertNotNil(try stop(capture, session: session))
        XCTAssertEqual(engineCount, 1)
    }

    func testStopRequestedDuringStartupFinishesWithoutBlockingMainThread() throws {
        let gate = DispatchSemaphore(value: 0)
        let engine = FakeCaptureEngine(pcm: Data(repeating: 1, count: 10_000))
        engine.beforeStart = {
            XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        }
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engine },
                                   observeDeviceChanges: false)
        let session = UUID()
        let started = expectation(description: "started")
        let stopped = expectation(description: "stopped")
        var events: [String] = []
        var result: Result<URL?, Error>?
        capture.start(sessionID: session) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
            events.append("start")
            started.fulfill()
        }
        capture.stop(sessionID: session) {
            XCTAssertTrue(Thread.isMainThread)
            result = $0
            events.append("stop")
            stopped.fulfill()
        }
        gate.signal()
        wait(for: [started, stopped], timeout: 3)
        let file = try XCTUnwrap(try result?.get())
        defer { TempFileStore.remove(file) }
        XCTAssertEqual(events, ["start", "stop"])
        XCTAssertEqual(try Data(contentsOf: file).count, WAVHeader.headerByteCount + 10_000)
    }

    func testLosingAllInputsReportsFailureAndEndsSession() throws {
        let source = DeviceSource(headset)
        let engine = FakeCaptureEngine(pcm: Data(repeating: 1, count: 10_000))
        let capture = AudioCapture(resolveDevice: { source.get() }, makeEngine: { engine },
                                   observeDeviceChanges: false)
        let session = UUID()
        let failed = expectation(description: "route failure")
        capture.onFailure = { failedSession, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(failedSession, session)
            XCTAssertTrue(error is AudioCapture.CaptureError)
            failed.fulfill()
        }
        start(capture, session: session)
        source.set(nil)
        capture.refreshInputDevice()
        wait(for: [failed], timeout: 3)
        XCTAssertNil(try stop(capture, session: session))
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testFailedStartDoesNotPoisonNextRecording() throws {
        let first = FakeCaptureEngine(pcm: Data())
        first.startError = AudioCapture.CaptureError(message: "Disconnected")
        let second = FakeCaptureEngine(pcm: Data(repeating: 2, count: 10_000))
        var engines = [first, second]
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let failed = expectation(description: "failed start")
        capture.start(sessionID: UUID()) { result in
            if case .success = result { XCTFail("Expected start failure") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        let session = UUID()
        start(capture, session: session)
        first.onPCM?(Data(repeating: 9, count: 10_000))
        let wav = try stop(capture, session: session)
        XCTAssertEqual(wav?.dropFirst(WAVHeader.headerByteCount), Data(repeating: 2, count: 10_000))
    }

    func testFailedRouteRestartEndsSessionAndNextHoldCanRecord() throws {
        let first = FakeCaptureEngine(pcm: Data(repeating: 1, count: 10_000))
        let failing = FakeCaptureEngine(pcm: Data())
        failing.startError = AudioCapture.CaptureError(message: "Route is unavailable")
        let next = FakeCaptureEngine(pcm: Data(repeating: 3, count: 10_000))
        var engines = [first, failing, next]
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let session = UUID()
        let failed = expectation(description: "failed restart")
        capture.onFailure = { failedSession, _ in
            XCTAssertEqual(failedSession, session)
            failed.fulfill()
        }
        start(capture, session: session)
        first.configurationChanged?()
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(failing.stopCount, 1)
        XCTAssertNil(try stop(capture, session: session))
        let nextSession = UUID()
        start(capture, session: nextSession)
        XCTAssertEqual(try stop(capture, session: nextSession)?.dropFirst(WAVHeader.headerByteCount),
                       Data(repeating: 3, count: 10_000))
    }

    func testStaleStopCannotStopNewSession() throws {
        let first = FakeCaptureEngine(pcm: Data(repeating: 1, count: 10_000))
        let second = FakeCaptureEngine(pcm: Data(repeating: 2, count: 10_000))
        var engines = [first, second]
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let oldSession = UUID()
        start(capture, session: oldSession)
        XCTAssertNotNil(try stop(capture, session: oldSession))
        let newSession = UUID()
        start(capture, session: newSession)
        XCTAssertNil(try stop(capture, session: oldSession))
        XCTAssertTrue(second.isRunning)
        first.configurationChanged?()
        XCTAssertNotNil(try stop(capture, session: newSession))
        XCTAssertEqual(second.stopCount, 1)
    }

    func testRetiredEngineCallbacksCannotAffectReplacement() throws {
        let first = FakeCaptureEngine(pcm: Data(repeating: 1, count: 5_000))
        let second = FakeCaptureEngine(pcm: Data(repeating: 2, count: 5_000))
        var engines = [first, second]
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engines.removeFirst() },
                                   observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        first.configurationChanged?()
        // Queue a second event from the old engine after its replacement is scheduled.
        first.configurationChanged?()
        let wav = try stop(capture, session: session)
        first.onPCM?(Data(repeating: 9, count: 10_000))
        XCTAssertEqual(wav?.count, WAVHeader.headerByteCount + 10_000)
        XCTAssertTrue(engines.isEmpty)
    }

    func testClosedBufferRejectsLateAudioAndRetiredStreams() {
        let buffer = RecordingPCMBuffer()
        let first = UUID()
        let second = UUID()
        buffer.activate(streamID: first)
        buffer.append(Data([1]), streamID: first)
        buffer.activate(streamID: second)
        buffer.append(Data([9]), streamID: first)
        buffer.append(Data([2]), streamID: second)
        XCTAssertEqual(buffer.finish(), Data([1, 2]))
        buffer.append(Data([3]), streamID: second)
        XCTAssertTrue(buffer.finish().isEmpty)
    }

    func testStopKeepsSamplesDeliveredWhileHardwareDrains() throws {
        let engine = FakeCaptureEngine(pcm: Data(repeating: 1, count: 5_000))
        engine.onStop = { engine.onPCM?(Data(repeating: 2, count: 5_000)) }
        let capture = AudioCapture(resolveDevice: { self.builtIn }, makeEngine: { engine },
                                   observeDeviceChanges: false)
        let session = UUID()
        start(capture, session: session)
        XCTAssertEqual(try stop(capture, session: session)?.dropFirst(WAVHeader.headerByteCount),
                       Data(repeating: 1, count: 5_000) + Data(repeating: 2, count: 5_000))
        engine.onStop = nil
    }

    private func start(_ capture: AudioCapture, session: UUID) {
        let started = expectation(description: "started")
        capture.start(sessionID: session) { result in
            if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
            started.fulfill()
        }
        wait(for: [started], timeout: 3)
    }

    private func stop(_ capture: AudioCapture, session: UUID) throws -> Data? {
        let stopped = expectation(description: "stopped")
        var result: Result<URL?, Error>?
        capture.stop(sessionID: session) {
            result = $0
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 3)
        guard let file = try XCTUnwrap(result).get() else { return nil }
        defer { TempFileStore.remove(file) }
        return try Data(contentsOf: file)
    }
}

private final class FakeCaptureEngine: AudioCaptureEngine {
    private(set) var isRunning = false
    var inputFormatIsCurrent = false
    private(set) var startedDeviceID: UInt32?
    private(set) var stopCount = 0
    var startError: Error?
    var beforeStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onPCM: ((Data) -> Void)?
    var configurationChanged: (() -> Void)?
    private let pcm: Data

    init(pcm: Data) { self.pcm = pcm }

    func start(deviceID: UInt32, onPCM: @escaping (Data) -> Void,
               onConfigurationChange: @escaping () -> Void) throws {
        XCTAssertFalse(Thread.isMainThread, "Hardware start must not block hotkey delivery")
        beforeStart?()
        startedDeviceID = deviceID
        self.onPCM = onPCM
        configurationChanged = onConfigurationChange
        if let startError { throw startError }
        isRunning = true
        onPCM(pcm)
    }

    func stop() {
        XCTAssertFalse(Thread.isMainThread, "Hardware stop must not block hotkey delivery")
        onStop?()
        isRunning = false
        stopCount += 1
    }
}

private final class DeviceSource {
    private let lock = NSLock()
    private var device: AudioInputDevice?

    init(_ device: AudioInputDevice?) { self.device = device }

    func get() -> AudioInputDevice? {
        lock.lock()
        defer { lock.unlock() }
        return device
    }

    func set(_ device: AudioInputDevice?) {
        lock.lock()
        defer { lock.unlock() }
        self.device = device
    }
}
