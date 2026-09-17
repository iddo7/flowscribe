import XCTest
@testable import FlowScribe

final class StateMachineTests: XCTestCase {
    func testToggleEventsByState() {
        let machine = TranscriptionStateMachine()
        XCTAssertEqual(machine.event(forToggle: ()), .startRecordingRequested)

        machine.handle(.startRecordingRequested)
        XCTAssertEqual(machine.event(forToggle: ()), .stopRecordingRequested)

        machine.handle(.stopRecordingRequested) // now transcribing
        XCTAssertNil(machine.event(forToggle: ()), "toggle during transcribing must be ignored")
    }

    func testValidHappyPath() {
        let machine = TranscriptionStateMachine()
        XCTAssertTrue(machine.handle(.startRecordingRequested))
        XCTAssertEqual(machine.state, .recording)
        XCTAssertTrue(machine.handle(.stopRecordingRequested))
        XCTAssertEqual(machine.state, .transcribing)
        XCTAssertTrue(machine.handle(.transcriptionSucceeded))
        XCTAssertEqual(machine.state, .idle)
    }

    func testFailurePathReturnsToIdle() {
        let machine = TranscriptionStateMachine()
        machine.handle(.startRecordingRequested)
        machine.handle(.stopRecordingRequested)
        XCTAssertTrue(machine.handle(.transcriptionFailed))
        XCTAssertEqual(machine.state, .idle)
    }

    func testResetFromRecordingIsValid() {
        let machine = TranscriptionStateMachine()
        machine.handle(.startRecordingRequested)
        XCTAssertTrue(machine.handle(.resetRequested))
        XCTAssertEqual(machine.state, .idle)
    }

    func testInvalidTransitionsRejected() {
        let machine = TranscriptionStateMachine()
        XCTAssertFalse(machine.handle(.transcriptionSucceeded), "cannot succeed from idle")
        XCTAssertEqual(machine.state, .idle)

        machine.handle(.startRecordingRequested)
        XCTAssertFalse(machine.handle(.startRecordingRequested), "cannot start while recording")
        XCTAssertEqual(machine.state, .recording)
        XCTAssertFalse(machine.handle(.transcriptionSucceeded), "cannot succeed from recording")
        XCTAssertEqual(machine.state, .recording)
    }

    func testTransitionCallbackFiresOnlyOnActualChange() {
        var transitions: [AppState] = []
        let machine = TranscriptionStateMachine { transitions.append($0) }
        machine.handle(.startRecordingRequested)
        machine.handle(.startRecordingRequested) // rejected, no callback
        machine.handle(.stopRecordingRequested)
        machine.handle(.transcriptionFailed)
        XCTAssertEqual(transitions, [.recording, .transcribing, .idle])
    }
}
