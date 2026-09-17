import AppKit

/// Delivers the transcript to the app the user was using when they started recording.
/// Strategy: save clipboard, install transcript, reactivate the remembered frontmost
/// app, synthesize Cmd+V (only when Accessibility is trusted), then restore clipboard.
/// If Accessibility is unavailable, falls back to clipboard-only and notifies the user.
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
    /// Delay before synthesizing paste so the target app finishes activating.
    var activationDelay: TimeInterval = 0.15
    /// Gives the target app time to consume the pasteboard before restoration.
    var clipboardRestoreDelay: TimeInterval = 0.35
    /// What we last installed on the clipboard, for change detection.
    private var installedTranscript: String?

    init(accessibilityChecker: @escaping () -> Bool = { Permissions.isAccessibilityTrusted() },
         pasteboard: NSPasteboard = .general) {
        self.accessibilityChecker = accessibilityChecker
        self.pasteboard = pasteboard
    }

    /// Captures the current app and, when Accessibility permits, the focused
    /// caret/input geometry so the HUD can appear next to the paste destination.
    static func rememberPasteTarget(workspace: NSWorkspace = .shared) -> Target {
        let app = workspace.frontmostApplication
        return Target(
            bundleID: app?.bundleIdentifier,
            localizedName: app?.localizedName,
            anchorRect: focusedInputRect()
        )
    }

    private static func focusedInputRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return nil }
        let focused = focusedValue as! AXUIElement

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

    enum DeliveryResult {
        case pasted            // Cmd+V into the remembered app
        case clipboardOnly     // Accessibility not trusted; text is on the clipboard
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
        pasteboard.setString(deliverable.text, forType: .string)
        installedTranscript = deliverable.text

        guard accessibilityChecker() else {
            completion(.clipboardOnly)
            return
        }

        let activate: () -> Void = {
            let byBundleID = deliverable.targetBundleID.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            }
            let byName = deliverable.targetLocalizedName.flatMap { targetName in
                NSWorkspace.shared.runningApplications.first { $0.localizedName == targetName }
            }
            let running = byBundleID ?? byName
            if let running {
                // macOS 13 API: activate(options:) (activate() is 14+).
                running.activate(options: [.activateIgnoringOtherApps])
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) { [weak self] in
            guard let self else { return }
            let ok = self.sendPasteKeystroke()
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.clipboardRestoreDelay) {
                    self.restoreClipboardIfNeeded(savedItems: savedItems)
                    completion(.pasted)
                }
            } else {
                completion(.failed("Could not synthesize the paste keystroke. The transcript is on your clipboard (⌘V to paste manually)."))
            }
        }
        activate()
    }

    /// Synthesizes Command+V via CGEvent. Requires Accessibility trust.
    func sendPasteKeystroke() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Restores prior clipboard contents unless something else already replaced
    /// our transcript (i.e. the current clipboard no longer matches what we wrote).
    private func restoreClipboardIfNeeded(savedItems: [[NSPasteboard.PasteboardType: Data]]) {
        guard let installed = installedTranscript else { return }
        installedTranscript = nil
        if pasteboard.string(forType: .string) != installed { return } // user wrote to it meanwhile
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
