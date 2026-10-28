import AppKit

@MainActor
final class ReaderBubble {
    enum Mode { case offer, loading, playing, paused }
    var onToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onShowText: (() -> Void)?
    var onSpeed: ((Float) -> Void)?

    private let panel: NSPanel
    private let wave = ReaderWaveButton(frame: .zero)
    private let more = NSButton(frame: .zero)
    private var mode: Mode = .offer

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        material.layer?.masksToBounds = true
        panel.contentView = material
        wave.target = self
        wave.action = #selector(toggled)
        wave.isBordered = false
        material.addSubview(wave)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Reader controls")
        more.isBordered = false
        more.target = self
        more.action = #selector(showMenu)
        more.toolTip = "Reading speed, show text, or stop"
        material.addSubview(more)
    }

    func show(_ mode: Mode, anchor: CGRect?, fallbackPoint: CGPoint? = nil) {
        self.mode = mode
        wave.mode = mode
        let size = NSSize(width: mode == .offer ? 32 : 104, height: 36)
        more.isHidden = mode == .offer
        wave.frame = NSRect(x: 2, y: 2, width: mode == .offer ? 28 : 70, height: 32)
        more.frame = NSRect(x: 72, y: 4, width: 28, height: 28)
        wave.setAccessibilityLabel(mode == .offer ? "Read selected text" : mode == .paused ? "Resume reading" : "Pause reading")
        wave.toolTip = mode == .offer ? "Read selection · ⌃⌥R" : "Click to pause or resume · Esc to stop"
        let point = fallbackPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor?.origin ?? point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        var origin: CGPoint
        if let anchor {
            let left = anchor.minX - size.width - 12
            origin = CGPoint(x: left >= visible.minX + 8 ? left : anchor.maxX + 12,
                             y: anchor.midY - size.height / 2)
        } else {
            origin = CGPoint(x: point.x + 12, y: point.y - size.height - 10)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        let frame = NSRect(origin: origin, size: size)
        if panel.isVisible, mode != .offer, panel.frame.size == size {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    func update(level: Double, time: TimeInterval) {
        wave.levels.removeFirst()
        wave.levels.append(level)
        wave.time = time
        wave.needsDisplay = true
    }

    func hide() { panel.orderOut(nil) }

    @objc private func toggled() { onToggle?() }

    @objc private func showMenu() {
        let menu = NSMenu()
        let text = menu.addItem(withTitle: "Show reading text…", action: #selector(showText), keyEquivalent: "")
        text.target = self
        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let speeds = NSMenu()
        for rate: Float in [0.75, 1, 1.25, 1.5, 1.75, 2] {
            let item = speeds.addItem(withTitle: "\(rate)×", action: #selector(changeSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = abs(ReaderSettings.load().speed - rate) < 0.01 ? .on : .off
        }
        speed.submenu = speeds
        menu.addItem(speed)
        menu.addItem(.separator())
        let stop = menu.addItem(withTitle: "Stop reading", action: #selector(stopReading), keyEquivalent: "")
        stop.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: more)
    }

    @objc private func showText() { onShowText?() }
    @objc private func stopReading() { onStop?() }
    @objc private func changeSpeed(_ sender: NSMenuItem) {
        if let speed = sender.representedObject as? Float { onSpeed?(speed) }
    }
}

private final class ReaderWaveButton: NSButton {
    var mode: ReaderBubble.Mode = .offer { didSet { needsDisplay = true } }
    var levels = Array(repeating: 0.0, count: 9)
    var time = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.5 : 0.85).setFill()
        switch mode {
        case .offer, .paused:
            let symbol = mode == .offer ? "speaker.wave.2" : "play.fill"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            image?.draw(in: NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16))
        case .loading:
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: 6,
                           startAngle: CGFloat(time * 250), endAngle: CGFloat(time * 250 + 250))
            path.lineWidth = 2
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        case .playing:
            for (i, level) in levels.enumerated() {
                let taper = 0.45 + 0.55 * sin(Double(i + 1) / Double(levels.count + 1) * .pi)
                let height = 3 + CGFloat(level * taper) * 20
                let rect = NSRect(x: bounds.midX - 25 + CGFloat(i) * 6, y: bounds.midY - height / 2,
                                  width: 3, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
}

@MainActor
final class ReaderTextWindow {
    var onSeek: ((Int) -> Void)?
    private var window: NSWindow?
    private let textView = SeekTextView()
    private var highlighted = NSRange(location: 0, length: 0)

    func setText(_ text: String) {
        textView.string = text
        highlighted = NSRange(location: 0, length: 0)
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Read aloud · Click a word to jump"
            window.isReleasedWhenClosed = false
            window.center()
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            textView.isEditable = false
            textView.isRichText = false
            textView.font = .systemFont(ofSize: 18)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 24, height: 24)
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.frame = scroll.bounds
            textView.textContainer?.widthTracksTextView = true
            textView.onSeek = { [weak self] offset in self?.onSeek?(offset) }
            scroll.documentView = textView
            window.contentView?.addSubview(scroll)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func highlight(_ range: NSRange) {
        guard window?.isVisible == true, highlighted != range,
              NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.textStorage?.removeAttribute(.backgroundColor, range: highlighted)
        textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.2), range: range)
        highlighted = range
        if NSEvent.pressedMouseButtons == 0, textView.shouldFollow { textView.scrollRangeToVisible(range) }
    }

    func clear() {
        window?.orderOut(nil)
        setText("")
    }
}

private final class SeekTextView: NSTextView {
    var onSeek: ((Int) -> Void)?
    private var lastManualScroll = 0.0
    var shouldFollow: Bool { ProcessInfo.processInfo.systemUptime - lastManualScroll > 2 }

    override func scrollWheel(with event: NSEvent) {
        lastManualScroll = ProcessInfo.processInfo.systemUptime
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0,
              let layoutManager, let textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: textPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -2).contains(textPoint) else { return }
        onSeek?(layoutManager.characterIndexForGlyph(at: glyph))
    }
}
