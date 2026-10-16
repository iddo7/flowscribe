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
    private var settings = PillSettings()
    private var panelSize: NSSize {
        NSSize(width: settings[.width], height: settings[.height])
    }
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var processingView: ProcessingView?
    private var resultView: NSImageView?
    private weak var effectView: NSView?
    private var scheduledHide: DispatchWorkItem?
    private var anchorRect: CGRect?
    private var settingsObserver: NSObjectProtocol?

    init() {
        settingsObserver = NotificationCenter.default.addObserver(forName: PillSettings.didChange,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSettings() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func updateAudioLevels(_ levels: [Double]) {
        waveformView?.updateAudioLevels(levels)
    }

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
        showResult(symbol: "exclamationmark", color: .labelColor, near: anchor, duration: 1.05)
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
            glass.tintColor = NSColor.labelColor.withAlphaComponent(0.08)
            glass.contentView = content
            background = glass
        } else {
            let visual = HUDEffectView(frame: content.frame)
            visual.autoresizingMask = [.width, .height]
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = panelSize.height / 2
            visual.layer?.masksToBounds = true
            visual.layer?.borderWidth = 0.5
            visual.borderTint = NSColor.labelColor.withAlphaComponent(0.28)
            visual.addSubview(content)
            background = visual
        }
        effectView = background

        let waveform = WaveformView(frame: content.bounds.insetBy(dx: 14, dy: 7))
        waveform.configure(settings)
        waveform.autoresizingMask = []
        content.addSubview(waveform)
        waveformView = waveform

        let symbolFrame = NSRect(x: (panelSize.width - 18) / 2, y: (panelSize.height - 18) / 2,
                                 width: 18, height: 18)
        let processing = ProcessingView(frame: symbolFrame)
        processing.isHidden = true
        content.addSubview(processing)
        processingView = processing

        let result = NSImageView(frame: symbolFrame)
        result.imageScaling = .scaleProportionallyDown
        result.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        result.isHidden = true
        content.addSubview(result)
        resultView = result

        panel.contentView = background
        self.panel = panel
        return panel
    }

    private func refreshSettings() {
        settings = PillSettings()
        guard let panel else { return }
        panel.setContentSize(panelSize)
        waveformView?.frame = NSRect(origin: .zero, size: panelSize).insetBy(dx: 14, dy: 7)
        waveformView?.configure(settings)
        let symbolFrame = NSRect(x: (panelSize.width - 18) / 2, y: (panelSize.height - 18) / 2,
                                 width: 18, height: 18)
        processingView?.frame = symbolFrame
        resultView?.frame = symbolFrame
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.cornerRadius = panelSize.height / 2
        } else {
            effectView?.layer?.cornerRadius = panelSize.height / 2
        }
        if panel.isVisible { position(panel, near: anchorRect) }
    }

    private func apply(state: AppState) {
        resultView?.isHidden = true
        processingView?.stopAnimating()
        processingView?.isHidden = true

        switch state {
        case .idle:
            waveformView?.stopAnimating()
            waveformView?.isHidden = false
            setTint(.labelColor)
        case .recording:
            waveformView?.isHidden = false
            waveformView?.startAnimating()
            setTint(.labelColor)
        case .transcribing:
            waveformView?.stopAnimating()
            waveformView?.isHidden = true
            processingView?.isHidden = false
            processingView?.startAnimating()
            setTint(.labelColor)
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
        guard let effectView else { return }

        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.tintColor = color.withAlphaComponent(0.14)
        } else if let visual = effectView as? HUDEffectView {
            visual.borderTint = color.withAlphaComponent(0.42)
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

/// The material fallback keeps its layer border in sync with the current appearance.
private final class HUDEffectView: NSVisualEffectView {
    var borderTint: NSColor = .labelColor {
        didSet { updateBorderColor() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorderColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderColor = effectiveAppearance.resolvedCGColor(borderTint)
        CATransaction.commit()
    }
}

/// A scrolling history of measured audio, shared by the HUD and the labeled Settings preview.
final class WaveformView: NSView {
    private var bars: [CALayer] = []
    private var timer: Timer?
    private var settings = PillSettings(defaults: nil)
    private var history = WaveformHistory()
    private var displayedLevels: [Double] = []
    private var lastAudioTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        configure(settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ settings: PillSettings) {
        self.settings = settings
        history.configure(settings)
        if bars.count != Int(settings[.bars]) {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<Int(settings[.bars])).map { _ in
                let bar = CALayer()
                layer?.addSublayer(bar)
                return bar
            }
            displayedLevels = history.levels
        }
        needsLayout = true
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let spacing = bounds.width / CGFloat(bars.count)
        let width = min(3, spacing * 0.55)
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: (CGFloat(index) + 0.5) * spacing, y: bounds.midY)
            bar.bounds.size = NSSize(width: width, height: 3 + CGFloat(displayedLevels[index]) * (bounds.height - 3))
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let foreground = effectiveAppearance.resolvedCGColor(.labelColor)
        bars.forEach { $0.backgroundColor = foreground }
        CATransaction.commit()
    }

    func startAnimating() {
        guard timer == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceFrame() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func updateAudioLevels(_ levels: [Double]) {
        guard timer != nil else { return }
        history.append(levels)
        lastAudioTime = CACurrentMediaTime()
    }

    private func advanceFrame() {
        guard timer != nil else { return }
        let now = CACurrentMediaTime()
        let elapsed = min(0.1, max(0, now - lastFrameTime))
        lastFrameTime = now
        // A stalled or disconnected input must not leave the bars frozen at a loud level.
        if now - lastAudioTime > 0.15 {
            history.reset()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let target = pow(min(1, max(0, history.levels[index])), 1 / settings[.sensitivity])
            // Brief interpolation smooths frames without washing out neighboring syllables.
            displayedLevels[index] += (target - displayedLevels[index]) * (1 - exp(-elapsed / 0.015))
            bar.bounds.size.height = 3 + CGFloat(displayedLevels[index]) * (bounds.height - 3)
        }
        CATransaction.commit()
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        lastAudioTime = 0
        history.reset()
        displayedLevels = history.levels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach {
            $0.removeAllAnimations()
            $0.bounds.size.height = 3
        }
        CATransaction.commit()
    }
}

/// A rotating broken ring that reads as processing rather than captured audio.
private final class ProcessingView: NSView {
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 2.2
        ring.lineCap = .round
        ring.strokeStart = 0.08
        ring.strokeEnd = 0.72
        layer?.addSublayer(ring)
        updateRingGeometry()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateRingGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = effectiveAppearance.resolvedCGColor(.labelColor)
        CATransaction.commit()
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

private extension NSAppearance {
    /// Semantic AppKit colors only resolve correctly while their target appearance is current.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
