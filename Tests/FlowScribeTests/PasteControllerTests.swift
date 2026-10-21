import AppKit
import XCTest
@testable import FlowScribe

final class PasteControllerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private let transcript = "A new transcript"
    private var deliverable: PasteController.Deliverable {
        .init(text: transcript, targetBundleID: "test.target", targetLocalizedName: "Target")
    }

    override func setUp() {
        super.setUp()
        // Never modify the user's general clipboard or send real keystrokes.
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testAppScopedFocusWorksWhenSystemWideFocusIsUnavailable() {
        let input = AXUIElementCreateApplication(1234)
        let focused = PasteController.focusedElement(
            for: 1234,
            applicationFocus: { pid in
                XCTAssertEqual(pid, 1234)
                return input
            },
            systemFocus: {
                XCTFail("A working app-scoped query must not depend on system-wide focus")
                return nil
            },
            elementProcessID: { _ in 1234 }
        )
        XCTAssertTrue(focused.map { CFEqual($0, input) } ?? false)
    }

    func testSystemWideFocusRemainsAvailableForAppsWithoutScopedFocus() {
        let input = AXUIElementCreateApplication(1234)
        let focused = PasteController.focusedElement(
            for: 1234, applicationFocus: { _ in nil }, systemFocus: { input },
            elementProcessID: { _ in 1234 }
        )
        XCTAssertTrue(focused.map { CFEqual($0, input) } ?? false)
    }

    func testFocusFromAnotherProcessIsRejected() {
        let otherInput = AXUIElementCreateApplication(5678)
        let focused = PasteController.focusedElement(
            for: 1234, applicationFocus: { _ in otherInput }, systemFocus: { otherInput },
            elementProcessID: { _ in 5678 }
        )
        XCTAssertNil(focused)
    }

    func testInvalidScopedFocusCanFallBackToMatchingSystemFocus() {
        let otherInput = AXUIElementCreateApplication(5678)
        let input = AXUIElementCreateApplication(1234)
        let focused = PasteController.focusedElement(
            for: 1234, applicationFocus: { _ in otherInput }, systemFocus: { input },
            elementProcessID: { CFEqual($0, input) ? 1234 : 5678 }
        )
        XCTAssertTrue(focused.map { CFEqual($0, input) } ?? false)
    }

    func testUnavailableFocusOrProcessIdentityIsRejected() {
        let input = AXUIElementCreateApplication(1234)
        XCTAssertNil(PasteController.focusedElement(
            for: 1234, applicationFocus: { _ in nil }, systemFocus: { nil },
            elementProcessID: { _ in
                XCTFail("Missing elements have no process to query")
                return nil
            }
        ))
        XCTAssertNil(PasteController.focusedElement(
            for: 1234, applicationFocus: { _ in input }, systemFocus: { input },
            elementProcessID: { _ in nil }
        ))
    }

    func testNoFocusedInputKeepsTranscriptInsteadOfRestoringPreviousClipboard() {
        pasteboard.setString("Previous clipboard", forType: .string)
        assertClipboardFallback(reason: .noFocusedInput, focusedInput: false)
    }

    func testNoFocusedInputAlsoWorksWithAnEmptyClipboard() {
        assertClipboardFallback(reason: .noFocusedInput, focusedInput: false)
    }

    func testMissingAccessibilityKeepsTranscriptWithoutActivatingTarget() {
        assertClipboardFallback(reason: .accessibilityUnavailable, accessibility: false,
                                activateTarget: { _ in
            XCTFail("Must not activate another app without Accessibility")
            return false
        })
    }

    func testUnavailableTargetKeepsTranscriptWithoutCheckingAnotherAppsFocus() {
        assertClipboardFallback(reason: .noFocusedInput, activateTarget: { _ in false },
                                focusedInputChecker: { _ in
            XCTFail("Must not inspect an unrelated app's focus")
            return true
        })
    }

    func testFocusedInputPastesTranscriptAndRestoresAllClipboardFormats() {
        let richData = Data([1, 2, 3])
        let item = NSPasteboardItem()
        item.setString("Previous clipboard", forType: .string)
        item.setData(richData, forType: .rtf)
        pasteboard.writeObjects([item])
        var pasteCount = 0
        let controller = makeController(pasteKeystrokeSender: {
            pasteCount += 1
            XCTAssertEqual(self.pasteboard.string(forType: .string), self.transcript)
            return true
        })
        let delivered = expectation(description: "automatically pasted")
        controller.deliver(deliverable) { result in
            guard case .pasted = result else {
                XCTFail("Expected automatic paste")
                delivered.fulfill()
                return
            }
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Previous clipboard")
        XCTAssertEqual(pasteboard.data(forType: .rtf), richData)
    }

    func testFailedKeystrokeKeepsTranscriptForManualPaste() {
        pasteboard.setString("Previous clipboard", forType: .string)
        let controller = makeController(pasteKeystrokeSender: { false })
        let delivered = expectation(description: "keystroke failed")
        controller.deliver(deliverable) { result in
            if case .failed = result {} else { XCTFail("Expected paste failure") }
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), transcript)
    }

    func testUserCopyOfIdenticalTextIsNotOverwrittenByClipboardRestoration() {
        pasteboard.setString("Previous clipboard", forType: .string)
        let controller = makeController(pasteKeystrokeSender: {
            self.pasteboard.clearContents()
            self.pasteboard.setString(self.transcript, forType: .string)
            return true
        })
        let delivered = expectation(description: "user copy preserved")
        controller.deliver(deliverable) { _ in delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), transcript)
    }

    func testClipboardChangeBeforePasteDoesNotSendUnrelatedContent() {
        let controller = makeController(pasteKeystrokeSender: {
            XCTFail("Must not paste content copied after transcription")
            return true
        })
        let delivered = expectation(description: "clipboard changed")
        controller.deliver(deliverable) { result in
            if case .failed = result {} else { XCTFail("Expected clipboard-change failure") }
            delivered.fulfill()
        }
        pasteboard.clearContents()
        pasteboard.setString("User copy", forType: .string)
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "User copy")
    }

    func testOlderPasteCannotRestoreOverANewerClipboardOnlyTranscript() {
        pasteboard.setString("Previous clipboard", forType: .string)
        var hasFocusedInput = true
        let next = PasteController.Deliverable(text: "Newer transcript", targetBundleID: "test.target",
                                              targetLocalizedName: "Target")
        let firstDelivered = expectation(description: "first paste finished")
        let secondDelivered = expectation(description: "second transcript copied")
        var controller: PasteController!
        controller = makeController(focusedInputChecker: { _ in hasFocusedInput }, pasteKeystrokeSender: {
            hasFocusedInput = false
            controller.deliver(next) { result in
                if case .clipboardOnly(.noFocusedInput) = result {} else {
                    XCTFail("Expected newer transcript on clipboard")
                }
                secondDelivered.fulfill()
            }
            return true
        })
        controller.deliver(deliverable) { _ in firstDelivered.fulfill() }
        wait(for: [firstDelivered, secondDelivered], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), next.text)
        controller = nil
    }

    private func assertClipboardFallback(reason: PasteController.ClipboardOnlyReason,
                                         accessibility: Bool = true,
                                         focusedInput: Bool = true,
                                         activateTarget: @escaping (PasteController.Deliverable) -> Bool = { _ in true },
                                         focusedInputChecker: ((PasteController.Deliverable) -> Bool)? = nil,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let controller = PasteController(
            accessibilityChecker: { accessibility }, pasteboard: pasteboard,
            activateTarget: activateTarget,
            focusedInputChecker: focusedInputChecker ?? { _ in focusedInput },
            pasteKeystrokeSender: {
                XCTFail("Clipboard fallback must not synthesize ⌘V", file: file, line: line)
                return true
            }
        )
        controller.activationDelay = 0
        controller.clipboardRestoreDelay = 0
        let delivered = expectation(description: "transcript copied")
        controller.deliver(deliverable) { result in
            switch (result, reason) {
            case (.clipboardOnly(.noFocusedInput), .noFocusedInput),
                 (.clipboardOnly(.accessibilityUnavailable), .accessibilityUnavailable): break
            default: XCTFail("Unexpected delivery result", file: file, line: line)
            }
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), transcript, file: file, line: line)
    }

    private func makeController(
        focusedInputChecker: @escaping (PasteController.Deliverable) -> Bool = { _ in true },
        pasteKeystrokeSender: @escaping () -> Bool = { true }
    ) -> PasteController {
        let controller = PasteController(accessibilityChecker: { true }, pasteboard: pasteboard,
                                         activateTarget: { _ in true },
                                         focusedInputChecker: focusedInputChecker,
                                         pasteKeystrokeSender: pasteKeystrokeSender)
        controller.activationDelay = 0
        controller.clipboardRestoreDelay = 0
        return controller
    }
}
