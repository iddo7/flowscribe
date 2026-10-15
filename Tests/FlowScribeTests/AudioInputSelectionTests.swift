import XCTest
@testable import FlowScribe

final class AudioInputSelectionTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "Microphone")
    private let headset = AudioInputDevice(id: 2, uid: "headset", name: "Microphone")

    func testSystemDefaultFollowsDefaultDeviceChanges() {
        let devices = [builtIn, headset]
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: nil, devices: devices, defaultDeviceID: 2), headset)
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: nil, devices: devices, defaultDeviceID: 1), builtIn)
    }

    func testManualSelectionOverridesSystemDefaultEvenWithDuplicateNames() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "headset", devices: [builtIn, headset],
                                                   defaultDeviceID: 1), headset)
    }

    func testDisconnectedPreferenceFallsBackAndReconnectUsesStableUID() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "headset", devices: [builtIn],
                                                   defaultDeviceID: 1), builtIn)
        let reconnected = AudioInputDevice(id: 99, uid: "headset", name: "Microphone")
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "headset", devices: [builtIn, reconnected],
                                                   defaultDeviceID: 1), reconnected)
    }

    func testPreferredDeviceWorksWithoutSystemDefault() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "headset", devices: [headset],
                                                   defaultDeviceID: nil), headset)
    }

    func testNoUsableDefaultReturnsNilRatherThanChoosingAnArbitraryMicrophone() {
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: nil, devices: [builtIn], defaultDeviceID: nil))
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: "headset", devices: [], defaultDeviceID: 2))
    }
}
