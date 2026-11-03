import AppKit

enum ApplicationAccessibility {
    /// Electron's text-input tree is opt-in and is lost when the target restarts.
    /// Request it on each lookup rather than caching readiness by app or PID.
    /// Native apps can reject these attributes; their ordinary AX queries still work.
    @discardableResult
    static func prepare(
        _ application: AXUIElement,
        setTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        setAttribute: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue
    ) -> AXUIElement {
        _ = setTimeout(application, 0.15)
        // https://www.electronjs.org/docs/latest/tutorial/accessibility#macos
        if setAttribute(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            // Chromium-based apps can expose the older accessibility switch instead.
            _ = setAttribute(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return application
    }
}
