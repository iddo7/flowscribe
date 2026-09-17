import AppKit
import QuartzCore

enum HUDPosition: String, CaseIterable {
    static let defaultsKey = "hudPosition"

    case nearTyping
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var title: String {
        switch self {
        case .nearTyping: "Near Typing"
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }

    static var selected: HUDPosition {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
                  let position = HUDPosition(rawValue: rawValue) else {
                return .bottomCenter
            }
            return position
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// A compact, non-activating waveform pill with a user-selected screen position.
@MainActor
final class HUDController {
    private let panelSize = NSSize(width: 68, height: 32)
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var processingView: ProcessingView?
    private var resultView: NSImageView?
    private weak var effectView: NSView?
    private var scheduledHide: DispatchWorkItem?
    private var anchorRect: CGRect?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(state: AppState, near anchor: CGRect?) {
        cancelScheduledHide()
        anchorRect = anchor
        let panel = ensurePanel()
        apply(state: state)
        position(panel, near: anchor)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func update(state: AppState, near anchor: CGRect? = nil) {
        cancelScheduledHide()
        guard let panel, panel.isVisible else { return }
        if let anchor {
            anchorRect = anchor
            position(panel, near: anchor)
        }
        apply(state: state)
    }

    func showSuccess(near anchor: CGRect? = nil) {
        showResult(symbol: "checkmark", color: .systemGreen, near: anchor, duration: 0.72)
    }

    func showFailure(near anchor: CGRect? = nil) {
        showResult(symbol: "exclamationmark", color: .white, near: anchor, duration: 1.05)
    }

    func hide() {
        cancelScheduledHide()
        waveformView?.stopAnimating()
        processingView?.stopAnimating()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: panelSize))
        content.autoresizingMask = [.width, .height]

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = panelSize.height / 2
            glass.tintColor = NSColor.white.withAlphaComponent(0.08)
            glass.contentView = content
            background = glass
        } else {
            let visual = NSVisualEffectView(frame: content.frame)
            visual.autoresizingMask = [.width, .height]
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = panelSize.height / 2
            visual.layer?.masksToBounds = true
            visual.layer?.borderWidth = 0.5
            visual.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
            visual.addSubview(content)
            background = visual
        }
        effectView = background

        let waveform = WaveformView(frame: NSRect(x: 15, y: 7, width: 38, height: 18))
        waveform.autoresizingMask = []
        content.addSubview(waveform)
        waveformView = waveform

        let processing = ProcessingView(frame: NSRect(x: 25, y: 7, width: 18, height: 18))
        processing.isHidden = true
        content.addSubview(processing)
        processingView = processing

        let result = NSImageView(frame: NSRect(x: 25, y: 7, width: 18, height: 18))
        result.imageScaling = .scaleProportionallyDown
        result.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        result.isHidden = true
        content.addSubview(result)
        resultView = result

        panel.contentView = background
        self.panel = panel
        return panel
    }

    private func apply(state: AppState) {
        resultView?.isHidden = true
        processingView?.stopAnimating()
        processingView?.isHidden = true

        switch state {
        case .idle:
            waveformView?.stopAnimating()
            waveformView?.isHidden = false
            setTint(.white)
        case .recording:
            waveformView?.isHidden = false
            waveformView?.startAnimating()
            setTint(.white)
        case .transcribing:
            waveformView?.stopAnimating()
            waveformView?.isHidden = true
            processingView?.isHidden = false
            processingView?.startAnimating()
            setTint(.white)
        }
    }

    private func showResult(symbol: String,
                            color: NSColor,
                            near anchor: CGRect?,
                            duration: TimeInterval) {
        cancelScheduledHide()
        let panel = ensurePanel()
        let targetAnchor = anchor ?? anchorRect
        anchorRect = targetAnchor
        position(panel, near: targetAnchor)

        waveformView?.stopAnimating()
        waveformView?.isHidden = true
        processingView?.stopAnimating()
        processingView?.isHidden = true
        resultView?.isHidden = false
        resultView?.contentTintColor = color
        resultView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setTint(color)

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        resultView?.layer?.removeAllAnimations()
        resultView?.wantsLayer = true

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.45, 1.18, 1]
        pop.keyTimes = [0, 0.62, 1]
        pop.duration = 0.3
        pop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        resultView?.layer?.add(pop, forKey: "resultPop")

        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        }
        scheduledHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func setTint(_ color: NSColor) {
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.tintColor = color.withAlphaComponent(0.14)
        } else {
            effectView?.layer?.borderColor = color.withAlphaComponent(0.42).cgColor
        }
    }

    private func position(_ panel: NSPanel, near anchor: CGRect?) {
        guard let screen = screen(containing: anchor) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let position = HUDPosition.selected
        let edgeInset: CGFloat = 28
        var origin: NSPoint

        if position == .nearTyping,
           let anchor,
           anchor.width.isFinite,
           anchor.height.isFinite {
            let gap: CGFloat = 10
            let horizontalCenter = max(anchor.minX, min(anchor.maxX, anchor.midX))
            origin = NSPoint(
                x: horizontalCenter - panelSize.width / 2,
                y: anchor.maxY + gap
            )
            if origin.y + panelSize.height > visible.maxY {
                origin.y = anchor.minY - panelSize.height - gap
            }
        } else {
            let resolvedPosition = position == .nearTyping ? HUDPosition.bottomCenter : position
            let x: CGFloat
            let y: CGFloat

            switch resolvedPosition {
            case .topLeft, .bottomLeft:
                x = visible.minX + edgeInset
            case .topRight, .bottomRight:
                x = visible.maxX - panelSize.width - edgeInset
            default:
                x = visible.midX - panelSize.width / 2
            }

            switch resolvedPosition {
            case .topLeft, .topCenter, .topRight:
                y = visible.maxY - panelSize.height - edgeInset
            default:
                y = visible.minY + edgeInset
            }
            origin = NSPoint(x: x, y: y)
        }

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func screen(containing anchor: CGRect?) -> NSScreen? {
        guard let anchor else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(anchor) }
    }

    private func cancelScheduledHide() {
        scheduledHide?.cancel()
        scheduledHide = nil
    }
}

/// Five white bars with deliberately uneven phases, giving the pill an organic voice meter.
private final class WaveformView: NSView {
    private let bars: [CALayer]

    override init(frame frameRect: NSRect) {
        let heights: [CGFloat] = [7, 12, 17, 11, 7]
        bars = heights.map { height in
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: height)
            bar.cornerRadius = 1.5
            bar.backgroundColor = NSColor.white.cgColor
            return bar
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        let spacing: CGFloat = 6
        let totalWidth = CGFloat(bars.count - 1) * spacing + 3
        let startX = (frameRect.width - totalWidth) / 2 + 1.5
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: startX + CGFloat(index) * spacing, y: frameRect.height / 2)
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func startAnimating() {
        let patterns: [[CGFloat]] = [
            [0.44, 0.92, 0.58, 1, 0.44],
            [0.52, 1, 0.68, 0.4, 0.52],
            [0.38, 0.7, 1, 0.62, 0.38],
            [0.5, 0.88, 0.46, 1, 0.5],
            [0.42, 1, 0.56, 0.78, 0.42],
        ]

        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "voice")
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = patterns[index]
            animation.keyTimes = [0, 0.22, 0.48, 0.74, 1]
            animation.duration = 0.78 + Double(index % 3) * 0.08
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.055
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: 4
            )
            bar.add(animation, forKey: "voice")
        }
    }

    func stopAnimating() {
        bars.forEach { $0.removeAllAnimations() }
    }
}

/// A rotating broken ring that reads as processing rather than captured audio.
private final class ProcessingView: NSView {
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 2.2
        ring.lineCap = .round
        ring.strokeStart = 0.08
        ring.strokeEnd = 0.72
        layer?.addSublayer(ring)
        updateRingGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateRingGeometry()
    }

    private func updateRingGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = CGRect(origin: .zero, size: bounds.size)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.path = CGPath(
            ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2),
            transform: nil
        )
        CATransaction.commit()
    }

    func startAnimating() {
        ring.removeAllAnimations()

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 0.72
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(rotation, forKey: "processingRotation")

        let breathe = CAKeyframeAnimation(keyPath: "strokeEnd")
        breathe.values = [0.58, 0.82, 0.58]
        breathe.keyTimes = [0, 0.5, 1]
        breathe.duration = 0.9
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(breathe, forKey: "processingBreathe")
    }

    func stopAnimating() {
        ring.removeAllAnimations()
    }
}
