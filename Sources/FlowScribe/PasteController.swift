import AppKit

/// Delivers the transcript to the app the user was using when they started recording.
/// Strategy: save clipboard, install transcript, reactivate the remembered frontmost
/// app, synthesize Cmd+V when a text input is focused, then restore clipboard.
/// Without Accessibility or a focused input, keeps the transcript on the clipboard.
final class PasteController {

    struct Target {
        let bundleID: String?
        let localizedName: String?
        /// AppKit global-screen coordinates for the caret or focused input.
        let anchorRect: CGRect?
    }

    struct Deliverable {
        let text: String
        /// Bundle ID (or localizedName fallback) of the frontmost app at recording start.
        let targetBundleID: String?
        let targetLocalizedName: String?
    }

    private let accessibilityChecker: () -> Bool
    private let pasteboard: NSPasteboard
    private let activateTarget: (Deliverable) -> Bool
    private let focusedInputChecker: (Deliverable) -> Bool
    private let pasteKeystrokeSender: () -> Bool
    /// Delay before synthesizing paste so the target app finishes activating.
    var activationDelay: TimeInterval = 0.15
    /// Gives the target app time to consume the pasteboard before restoration.
    var clipboardRestoreDelay: TimeInterval = 0.35

    init(accessibilityChecker: @escaping () -> Bool = { Permissions.isAccessibilityTrusted() },
         pasteboard: NSPasteboard = .general,
         activateTarget: @escaping (Deliverable) -> Bool = { PasteController.activateTarget($0) },
         focusedInputChecker: @escaping (Deliverable) -> Bool = { PasteController.hasFocusedTextInput(for: $0) },
         pasteKeystrokeSender: @escaping () -> Bool = { PasteController.sendPasteKeystroke() }) {
        self.accessibilityChecker = accessibilityChecker
        self.pasteboard = pasteboard
        self.activateTarget = activateTarget
        self.focusedInputChecker = focusedInputChecker
        self.pasteKeystrokeSender = pasteKeystrokeSender
    }

    /// Captures the current app and, when Accessibility permits, the focused
    /// caret/input geometry so the HUD can appear next to the paste destination.
    static func rememberPasteTarget(workspace: NSWorkspace = .shared) -> Target {
        let app = workspace.frontmostApplication
        return Target(
            bundleID: app?.bundleIdentifier,
            localizedName: app?.localizedName,
            anchorRect: app.flatMap { focusedInputRect(for: $0) }
        )
    }

    private static func focusedInputRect(for app: NSRunningApplication) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        guard let focused = focusedElement(for: app.processIdentifier),
              isTextInput(focused) else { return nil }

        if let caretRect = selectedTextBounds(of: focused), isUsable(caretRect) {
            return convertAXToAppKit(caretRect)
        }

        guard let position = pointAttribute(kAXPositionAttribute as CFString, of: focused),
              let size = sizeAttribute(kAXSizeAttribute as CFString, of: focused) else { return nil }
        let elementRect = CGRect(origin: position, size: size)
        guard isUsable(elementRect) else { return nil }
        return convertAXToAppKit(elementRect)
    }

    private static func selectedTextBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success, let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        if rect.width < 2 { rect.size.width = 2 }
        return rect
    }

    private static func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func convertAXToAppKit(_ rect: CGRect) -> CGRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite &&
        rect.width >= 0 && rect.height > 0
    }

    /// Electron can return cannotComplete for system-wide focus while its own
    /// application element still exposes the editor and its geometry. Use the
    /// same app-scoped lookup for both HUD placement and paste validation.
    static func focusedElement(
        for processID: pid_t,
        applicationFocus: (pid_t) -> AXUIElement? = {
            focusedElementAttribute(of: AXUIElementCreateApplication($0))
        },
        systemFocus: () -> AXUIElement? = {
            focusedElementAttribute(of: AXUIElementCreateSystemWide())
        },
        elementProcessID: (AXUIElement) -> pid_t? = {
            var pid: pid_t = 0
            return AXUIElementGetPid($0, &pid) == .success ? pid : nil
        }
    ) -> AXUIElement? {
        if let focused = applicationFocus(processID), elementProcessID(focused) == processID {
            return focused
        }
        guard let focused = systemFocus(), elementProcessID(focused) == processID else { return nil }
        return focused
    }

    private static func focusedElementAttribute(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func activateTarget(_ deliverable: Deliverable) -> Bool {
        let running: NSRunningApplication?
        if let bundleID = deliverable.targetBundleID {
            running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        } else if let name = deliverable.targetLocalizedName {
            running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        } else {
            running = nil
        }
        // macOS 13 API: activate(options:) (activate() is 14+).
        return running?.activate(options: [.activateIgnoringOtherApps]) ?? false
    }

    private static func hasFocusedTextInput(for deliverable: Deliverable) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleID = deliverable.targetBundleID {
            guard app.bundleIdentifier == bundleID else { return false }
        } else {
            guard let name = deliverable.targetLocalizedName,
                  app.localizedName == name else { return false }
        }
        guard let focused = focusedElement(for: app.processIdentifier) else { return false }
        return isTextInput(focused)
    }

    private static func isTextInput(_ focused: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? NSNumber)?.boolValue == false { return false }

        // Geometry alone also matches buttons, windows and web pages. Require
        // a text-input role or writable selected text for custom editors.
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return true
        }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextAttribute as CFString, &settable
        ) == .success && settable.boolValue
    }

    enum ClipboardOnlyReason {
        case accessibilityUnavailable
        case noFocusedInput
    }

    enum DeliveryResult {
        case pasted            // Cmd+V into the remembered app
        case clipboardOnly(ClipboardOnlyReason)
        case failed(String)
    }

    /// Delivers the text. Restores the prior clipboard only after automatic paste.
    func deliver(_ deliverable: Deliverable,
                 completion: @escaping (DeliveryResult) -> Void) {
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            let dict = item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { acc, type in
                if let data = item.data(forType: type) { acc[type] = data }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        pasteboard.clearContents()
        guard pasteboard.setString(deliverable.text, forType: .string) else {
            completion(.failed("Could not copy the transcript to the clipboard."))
            return
        }
        let installedChangeCount = pasteboard.changeCount

        guard accessibilityChecker() else {
            completion(.clipboardOnly(.accessibilityUnavailable))
            return
        }

        guard activateTarget(deliverable) else {
            completion(.clipboardOnly(.noFocusedInput))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) { [weak self] in
            guard let self else { return }
            guard self.pasteboard.changeCount == installedChangeCount else {
                completion(.failed("The clipboard changed before automatic paste. Please transcribe again."))
                return
            }
            // Recheck after activation: focus can change while transcribing.
            guard self.focusedInputChecker(deliverable) else {
                completion(.clipboardOnly(.noFocusedInput))
                return
            }
            let ok = self.pasteKeystrokeSender()
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.clipboardRestoreDelay) {
                    self.restoreClipboardIfNeeded(savedItems: savedItems, installedChangeCount: installedChangeCount)
                    completion(.pasted)
                }
            } else {
                completion(.failed("Could not synthesize the paste keystroke. The transcript is on your clipboard (⌘V to paste manually)."))
            }
        }
    }

    /// Synthesizes Command+V via CGEvent. Requires Accessibility trust.
    private static func sendPasteKeystroke() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// A per-delivery change count also protects newer transcriptions and copies
    /// of identical text from an older delivery's delayed restoration.
    private func restoreClipboardIfNeeded(savedItems: [[NSPasteboard.PasteboardType: Data]],
                                          installedChangeCount: Int) {
        guard pasteboard.changeCount == installedChangeCount else { return }
        guard !savedItems.isEmpty else { return }
        pasteboard.clearContents()
        let restoredItems = savedItems.map { item in
            let newItem = NSPasteboardItem()
            for (type, data) in item {
                newItem.setData(data, forType: type)
            }
            return newItem
        }
        pasteboard.writeObjects(restoredItems)
    }
}
