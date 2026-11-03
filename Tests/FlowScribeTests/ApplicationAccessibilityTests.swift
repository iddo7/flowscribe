import AppKit
import XCTest
@testable import FlowScribe

final class ApplicationAccessibilityTests: XCTestCase {
    func testElectronTreeIsRequestedBeforeQueryingFocusWithABoundedTimeout() {
        let app = AXUIElementCreateApplication(1234)
        var operations: [String] = []
        let prepared = ApplicationAccessibility.prepare(app, setTimeout: { element, timeout in
            XCTAssertTrue(CFEqual(element, app))
            XCTAssertEqual(timeout, 0.15)
            operations.append("timeout")
            return .success
        }, setAttribute: { element, attribute, value in
            XCTAssertTrue(CFEqual(element, app))
            XCTAssertTrue(CFEqual(value, kCFBooleanTrue))
            operations.append(attribute as String)
            return .success
        })
        XCTAssertTrue(CFEqual(prepared, app))
        XCTAssertEqual(operations, ["timeout", "AXManualAccessibility"])
    }

    func testChromiumSwitchIsUsedWhenManualAccessibilityIsUnsupported() {
        var attributes: [String] = []
        ApplicationAccessibility.prepare(AXUIElementCreateApplication(1234), setTimeout: { _, _ in .success },
                                         setAttribute: { _, attribute, _ in
            attributes.append(attribute as String)
            return attribute as String == "AXManualAccessibility" ? .attributeUnsupported : .success
        })
        XCTAssertEqual(attributes, ["AXManualAccessibility", "AXEnhancedUserInterface"])
    }

    func testNativeAppsRemainQueryableWhenBothSwitchesAreUnsupported() {
        let app = AXUIElementCreateApplication(1234)
        let prepared = ApplicationAccessibility.prepare(app, setTimeout: { _, _ in .success },
                                                        setAttribute: { _, _, _ in .attributeUnsupported })
        XCTAssertTrue(CFEqual(prepared, app))
    }

    func testAccessibilityReadinessIsNotCachedAcrossLookupsOrAppRestarts() {
        var preparedPIDs: [pid_t] = []
        // Repeat the same process too: an app can reset its tree without relaunching.
        for pid: pid_t in [1234, 1234, 5678] {
            ApplicationAccessibility.prepare(AXUIElementCreateApplication(pid), setTimeout: { _, _ in .success },
                                             setAttribute: { element, _, _ in
                var actualPID: pid_t = 0
                XCTAssertEqual(AXUIElementGetPid(element, &actualPID), .success)
                preparedPIDs.append(actualPID)
                return .success
            })
        }
        XCTAssertEqual(preparedPIDs, [1234, 1234, 5678])
    }
}
