import AppKit

/// AX work runs on a serial queue, with bounded per-app messaging timeouts.
/// Never changes the user's selection, scroll position, or focused element.
enum ReadingAccessibility {
    static let queue = DispatchQueue(label: "com.flowscribe.reader.accessibility", qos: .userInitiated)

    struct Selection {
        let text: String
        let processID: pid_t
        let element: AXUIElement?
        let range: CFRange?
        let markerRange: CFTypeRef?
        let markerIndex: Int?
        let anchor: CGRect?
        let isLink: Bool
    }

    static func selection(processID: pid_t, point: CGPoint) -> Selection? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var candidates: [AXUIElement] = []
        if let focused = element(attribute(app, kAXFocusedUIElementAttribute)) { candidates.append(focused) }
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        if let hit { candidates.append(hit) }
        // Browser selections are often on the web area, above the focused static text.
        var visited: [AXUIElement] = []
        for candidate in candidates {
            var current: AXUIElement? = candidate
            for _ in 0..<10 {
                guard let item = current, !visited.contains(where: { CFEqual($0, item) }) else { break }
                visited.append(item)
                guard attribute(item, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { break }
                let markerRange = attribute(item, "AXSelectedTextMarkerRange")
                let selected = attribute(item, kAXSelectedTextAttribute) as? String
                    ?? markerRange.flatMap { parameter(item, "AXStringForTextMarkerRange", $0) as? String }
                if let text = selected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard text.count <= 100_000 else { return nil }
                    let markerSource = documentElement(above: item) ?? item
                    let source = markerRange == nil ? item : markerSource
                    let range = CFEqual(source, item) ? cfRange(attribute(item, kAXSelectedTextRangeAttribute)) : nil
                    let index = markerRange.flatMap { selectionStartIndex($0, in: source) }
                    let rawBounds = range.flatMap { bounds(item, range: $0) }
                        ?? markerRange.flatMap { rect(parameter(source, "AXBoundsForTextMarkerRange", $0)) }
                    return Selection(text: text, processID: processID, element: source, range: range,
                                     markerRange: markerRange, markerIndex: index,
                                     anchor: rawBounds.flatMap(convert),
                                     isLink: isLink(item) || hit.map { isLink($0) } == true)
                }
                current = element(attribute(item, kAXParentAttribute))
            }
        }
        return nil
    }

    static func wordBounds(_ word: NSRange, in selection: Selection) -> CGRect? {
        guard let element = selection.element,
              NSMaxRange(word) <= (selection.text as NSString).length else { return nil }
        let expected = (selection.text as NSString).substring(with: word)
        if let base = selection.range {
            let range = CFRange(location: base.location + word.location, length: word.length)
            if string(element, range: range) == expected,
               let rect = bounds(element, range: range).flatMap(convert) { return rect }
        }
        if let marker = markerRange(word, in: selection) {
            guard parameter(element, "AXStringForTextMarkerRange", marker) as? String == expected else { return nil }
            return rect(parameter(element, "AXBoundsForTextMarkerRange", marker)).flatMap(convert)
        }
        return nil
    }

    /// Exact source-relative indices avoid matching the wrong occurrence of a repeated word.
    static func offset(at point: CGPoint, in selection: Selection) -> Int? {
        guard let source = selection.element,
              let pointValue = value(point) else { return nil }
        let relative: Int?
        if let base = selection.range,
           let clicked = cfRange(parameter(source, kAXRangeForPositionParameterizedAttribute, pointValue)) {
            relative = clicked.location - base.location
        } else if let base = selection.markerIndex,
                  let marker = parameter(source, "AXTextMarkerForPosition", pointValue),
                  let index = documentOffset(of: marker, in: source) {
            relative = index - base
        } else { relative = nil }
        guard let offset = relative, offset >= 0, offset < (selection.text as NSString).length else { return nil }
        let word = ReadingText(selection.text).word(at: offset)
        // RangeForPosition can return the nearest character even outside the text.
        guard let wordRect = wordBounds(word, in: selection),
              wordRect.insetBy(dx: -2, dy: -2).contains(convert(point)) else { return nil }
        let app = AXUIElementCreateApplication(selection.processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        if let hit, isLink(hit) { return nil } // A normal link click keeps its normal behavior.
        return word.location
    }

    private static func markerRange(_ range: NSRange, in selection: Selection) -> CFTypeRef? {
        guard let element = selection.element, let base = selection.markerIndex,
              let start = parameter(element, "AXTextMarkerForIndex", NSNumber(value: base + range.location)),
              let end = parameter(element, "AXTextMarkerForIndex", NSNumber(value: base + NSMaxRange(range))) else { return nil }
        return makeMarkerRange(start, end)
    }

    private static func selectionStartIndex(_ range: CFTypeRef, in source: AXUIElement) -> Int? {
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        let markers = range as! AXTextMarkerRange
        let first = AXTextMarkerRangeCopyStartMarker(markers)
        let last = AXTextMarkerRangeCopyEndMarker(markers)
        guard let a = documentOffset(of: first, in: source),
              let b = documentOffset(of: last, in: source) else { return nil }
        return min(a, b) // Backward selections can expose reversed marker endpoints.
    }

    private static func makeMarkerRange(_ start: CFTypeRef, _ end: CFTypeRef) -> CFTypeRef? {
        guard CFGetTypeID(start) == AXTextMarkerGetTypeID(), CFGetTypeID(end) == AXTextMarkerGetTypeID() else { return nil }
        return AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
    }

    /// Chromium's IndexForTextMarker can be leaf-relative, whereas TextMarkerForIndex
    /// is document-relative. Measure the prefix so inline formatting/repeated words
    /// cannot silently shift the audio to another paragraph.
    private static func documentOffset(of marker: CFTypeRef, in source: AXUIElement) -> Int? {
        guard let beginning = attribute(source, "AXStartTextMarker"),
              let prefix = makeMarkerRange(beginning, marker),
              let string = parameter(source, "AXStringForTextMarkerRange", prefix) as? String else { return nil }
        return string.utf16.count
    }

    private static func documentElement(above item: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = item
        for _ in 0..<12 {
            guard let element = current else { break }
            if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" { return element }
            current = self.element(attribute(element, kAXParentAttribute))
        }
        return nil
    }

    private static func isLink(_ item: AXUIElement) -> Bool {
        var current: AXUIElement? = item
        for _ in 0..<3 {
            guard let element = current else { break }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXLink" { return true }
            if role == "AXWebArea" || role == kAXTextAreaRole { break }
            current = self.element(attribute(element, kAXParentAttribute))
        }
        return false
    }

    private static func bounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        return rect(parameter(element, kAXBoundsForRangeParameterizedAttribute, value))
    }

    private static func string(_ element: AXUIElement, range: CFRange) -> String? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        return parameter(element, kAXStringForRangeParameterizedAttribute, value) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private static func parameter(_ element: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &result) == .success ? result : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func cfRange(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
        return range
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }
        return rect
    }

    private static func value(_ point: CGPoint) -> AXValue? {
        var point = point
        return AXValueCreate(.cgPoint, &point)
    }

    static func convert(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }

    private static func convert(_ rect: CGRect) -> CGRect? {
        CGRect(x: rect.minX, y: CGDisplayBounds(CGMainDisplayID()).height - rect.maxY,
               width: max(2, rect.width), height: rect.height)
    }
}
