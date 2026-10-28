import AppKit
import AVFoundation

@MainActor
final class ReaderController {
    var canRead: () -> Bool = { true }
    var onFailure: ((String) -> Void)?
    private let bubble = ReaderBubble()
    private let textWindow = ReaderTextWindow()
    private let client: SpeechClient
    private let makePlayer: @MainActor (Data) throws -> any ReaderAudioPlaying
    private var monitor: Any?
    private var localMonitor: Any?
    private var selectionWork: DispatchWorkItem?
    private var offerExpiry: DispatchWorkItem?
    private var offer: ReadingAccessibility.Selection?
    private var source: ReadingAccessibility.Selection?
    private var document: ReadingText?
    private var settings = ReaderSettings.load()
    private var generation = UUID()
    private var loadID = UUID()
    private var selectionID = UUID()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchIndex: Int?
    private var cache: [Int: SpeechClip] = [:]
    private var player: (any ReaderAudioPlaying)?
    private var playingClip: SpeechClip?
    private var playingTextOffset = 0
    private var workspaceObserver: NSObjectProtocol?
    private var voiceObserver: NSObjectProtocol?
    private var timer: Timer?
    private var segmentIndex = 0
    private var pendingOffset = 0
    private var wantsPlayback = true
    private var geometryBusy = false
    private var lastGeometryTime = 0.0
    private var mouseDown: CGPoint?
    private var anchor: CGRect?

    var isActive: Bool { document != nil }

    init(client: SpeechClient = SpeechClient(),
         makePlayer: @escaping @MainActor (Data) throws -> any ReaderAudioPlaying = { try ReaderAudioOutput(data: $0) }) {
        self.client = client
        self.makePlayer = makePlayer
        bubble.onToggle = { [weak self] in
            guard let self else { return }
            if self.isActive { self.toggle() }
            else if let offer = self.offer { self.start(offer) }
        }
        bubble.onStop = { [weak self] in self?.stop() }
        bubble.onShowText = { [weak self] in self?.textWindow.show() }
        bubble.onSpeed = { [weak self] speed in
            guard let self else { return }
            self.settings.speed = speed
            var saved = ReaderSettings.load()
            saved.speed = speed
            saved.save()
            self.player?.rate = speed
        }
        textWindow.onSeek = { [weak self] offset in self?.seek(to: offset) }
    }

    func startMonitoring() {
        voiceObserver = NotificationCenter.default.addObserver(forName: ReaderSettings.voiceDidChange,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isActive { self.updateBubble() } else { self.dismissOffer() }
            }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyUp, .scrollWheel]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53, self?.isActive == true { self?.stop(); return nil }
            return event
        }
        // Escape is observed only to dismiss our own reader; events are never consumed in other apps.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.stop() }
        }
    }

    private var escapeMonitor: Any?

    func shutdown() {
        stop()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let voiceObserver { NotificationCenter.default.removeObserver(voiceObserver) }
        voiceObserver = nil
        for token in [monitor, localMonitor, escapeMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(token) }
        monitor = nil
        localMonitor = nil
        escapeMonitor = nil
    }

    func readSelection() {
        if isActive { toggle(); return }
        guard canRead() else { return }
        guard AXIsProcessTrusted() else {
            _ = Permissions.requestAccessibilityIfNeeded()
            onFailure?("Enable Accessibility for FlowScribe to read selected text, then try ⌃⌥R again.")
            return
        }
        captureSelection(explicit: true)
    }

    func stop() {
        generation = UUID()
        selectionID = UUID()
        loadID = UUID()
        selectionWork?.cancel()
        offerExpiry?.cancel()
        loadTask?.cancel()
        prefetchTask?.cancel()
        loadTask = nil
        prefetchTask = nil
        prefetchIndex = nil
        player?.stop()
        player = nil
        playingClip = nil
        timer?.invalidate()
        timer = nil
        document = nil
        source = nil
        offer = nil
        cache.removeAll()
        bubble.hide()
        textWindow.clear()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDown = NSEvent.mouseLocation
            selectionID = UUID()
            selectionWork?.cancel()
            if !isActive { dismissOffer() }
        case .leftMouseUp:
            let point = NSEvent.mouseLocation
            if isActive {
                guard let down = mouseDown, hypot(point.x - down.x, point.y - down.y) < 5,
                      let source, NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processID else { return }
                let session = generation
                ReadingAccessibility.queue.async {
                    let offset = ReadingAccessibility.offset(at: ReadingAccessibility.convert(point), in: source)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == session, let offset else { return }
                        self.seek(to: offset)
                    }
                }
            } else { scheduleSelection() }
        case .keyUp:
            // Releasing the read shortcut must not invalidate its pending AX lookup.
            if event.keyCode == 15, event.modifierFlags.contains([.control, .option]) { return }
            let selectsAll = event.keyCode == 0 && event.modifierFlags.contains(.command)
            if !isActive, event.modifierFlags.contains(.shift) || selectsAll { scheduleSelection() }
            else if !isActive { dismissOffer() }
        case .scrollWheel:
            if !isActive { dismissOffer() }
        default: break
        }
    }

    private func scheduleSelection() {
        selectionWork?.cancel()
        guard ReaderSettings.load().offersSelection, canRead() else { return }
        let work = DispatchWorkItem { [weak self] in self?.captureSelection(explicit: false) }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func dismissOffer() {
        selectionID = UUID()
        offerExpiry?.cancel()
        offer = nil
        bubble.hide()
    }

    private func captureSelection(explicit: Bool) {
        guard !isActive, canRead(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let point = NSEvent.mouseLocation
        let pid = app.processIdentifier
        let requestID = UUID()
        selectionID = requestID
        ReadingAccessibility.queue.async {
            let selection = ReadingAccessibility.selection(processID: pid, point: ReadingAccessibility.convert(point))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionID == requestID, !self.isActive,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let selection {
                    if explicit { self.start(selection) }
                    else if ReadingText.shouldOffer(selection.text, isLink: selection.isLink) {
                        self.offer = selection
                        let offerPoint = selection.anchor.map { CGPoint(x: $0.maxX, y: $0.minY) } ?? point
                        self.bubble.show(.offer, anchor: nil, fallbackPoint: offerPoint)
                        let expiry = DispatchWorkItem { [weak self] in
                            guard self?.isActive == false else { return }
                            self?.dismissOffer()
                        }
                        self.offerExpiry = expiry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: expiry)
                    }
                } else if explicit {
                    self.copySelection(processID: pid, point: point, requestID: requestID)
                }
            }
        }
    }

    /// Explicit-shortcut fallback for apps that support Copy but expose no AX selection.
    /// Passive selection detection never reads or writes the clipboard.
    private func copySelection(processID: pid_t, point: CGPoint, requestID: UUID) {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let before = board.changeCount
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            let changed = board.changeCount != before
            let copyCount = board.changeCount
            let text = changed ? board.string(forType: .string) : nil
            if changed, self?.selectionID == requestID,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
               board.changeCount == copyCount {
                board.clearContents()
                if !saved.isEmpty { board.writeObjects(saved) }
            }
            guard let self, self.selectionID == requestID, !self.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 100_000 else {
                self.onFailure?("Select some text in another app, then press ⌃⌥R. This app may not expose selected text to macOS.")
                return
            }
            self.start(.init(text: text, processID: processID, element: nil, range: nil,
                             markerRange: nil, markerIndex: nil,
                             anchor: CGRect(origin: point, size: CGSize(width: 1, height: 20)), isLink: false))
        }
    }

    func start(_ selection: ReadingAccessibility.Selection) {
        guard canRead() else { return }
        stop()
        settings = ReaderSettings.load()
        source = selection
        document = ReadingText(selection.text)
        anchor = selection.anchor
        textWindow.setText(selection.text)
        wantsPlayback = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        load(segment: 0, offset: 0)
    }

    func toggle() {
        wantsPlayback.toggle()
        if wantsPlayback {
            if let player {
                if !player.play() { fail(SpeechClient.Failure.invalidResponse) }
                else { prefetch(after: segmentIndex) }
            }
        } else { player?.pause() }
        updateBubble()
    }

    func seek(to offset: Int) {
        guard let document, let index = document.segmentIndex(at: offset) else { return }
        let local = document.word(at: offset).location - document.segments[index].range.location
        wantsPlayback = true
        if index == segmentIndex, local >= playingTextOffset,
           let player, let timeline = playingClip?.timeline {
            player.currentTime = min(player.duration, timeline.time(at: max(0, local - playingTextOffset)))
            if !player.play() { fail(SpeechClient.Failure.invalidResponse) }
            updateBubble()
        } else { load(segment: index, offset: max(0, local)) }
    }

    private func load(segment index: Int, offset: Int) {
        guard let document, document.segments.indices.contains(index) else { stop(); return }
        loadTask?.cancel()
        player?.stop()
        player = nil
        playingClip = nil
        segmentIndex = index
        pendingOffset = offset
        let id = UUID()
        loadID = id
        updateBubble()
        if prefetchIndex != index {
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchIndex = nil
        }
        if let clip = cache[index], offset == 0 || clip.timeline != nil {
            play(clip, index: index, offset: offset)
            return
        }
        // Reuse an in-flight prefetched segment rather than charging for it twice.
        if prefetchIndex == index { return }
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchIndex = nil
        let session = generation
        let settings = settings
        loadTask = Task { [weak self, client] in
            do {
                let segment = document.segments[index].text as NSString
                let spokenText = segment.substring(from: offset)
                let clip = try await client.synthesize(spokenText, settings: settings,
                                                       previousText: index > 0 ? document.segments[index - 1].text : nil,
                                                       nextText: index + 1 < document.segments.count ? document.segments[index + 1].text : nil)
                guard let self, !Task.isCancelled, self.generation == session, self.loadID == id else { return }
                self.loadTask = nil
                if offset == 0 { self.cache[index] = clip }
                self.play(clip, index: index, offset: offset, textOffset: offset)
            } catch {
                guard let self, !Task.isCancelled, self.generation == session, self.loadID == id else { return }
                self.fail(error)
            }
        }
    }

    private func play(_ clip: SpeechClip, index: Int, offset: Int, textOffset: Int = 0) {
        do {
            let output = try makePlayer(clip.audio)
            let session = generation
            let id = loadID
            output.onFinished = { [weak self] success in
                guard let self, self.generation == session, self.loadID == id else { return }
                if success, self.player?.isPlaying == true { return }
                if success { self.load(segment: index + 1, offset: 0) }
                else { self.fail(SpeechClient.Failure.invalidResponse) }
            }
            output.rate = settings.speed
            output.currentTime = clip.timeline?.time(at: max(0, offset - textOffset)) ?? 0
            playingClip = clip
            playingTextOffset = textOffset
            player = output
            if let document {
                textWindow.highlight(document.word(at: document.segments[index].range.location + offset))
            }
            if wantsPlayback, !output.play() { throw SpeechClient.Failure.invalidResponse }
            cache = cache.filter { abs($0.key - index) <= 1 }
            updateBubble()
            prefetch(after: index)
        } catch { fail(error) }
    }

    private func prefetch(after index: Int) {
        guard wantsPlayback, let document, index + 1 < document.segments.count,
              cache[index + 1] == nil, prefetchIndex != index + 1 else { return }
        let next = index + 1
        let session = generation
        let settings = settings
        prefetchIndex = next
        prefetchTask = Task { [weak self, client] in
            do {
                let clip = try await client.synthesize(document.segments[next].text, settings: settings,
                                                       previousText: document.segments[index].text,
                                                       nextText: next + 1 < document.segments.count ? document.segments[next + 1].text : nil)
                guard let self, !Task.isCancelled, self.generation == session, self.prefetchIndex == next else { return }
                self.cache[next] = clip
                self.prefetchIndex = nil
                self.prefetchTask = nil
                if self.segmentIndex == next, self.player == nil {
                    if self.pendingOffset > 0, clip.timeline == nil {
                        self.load(segment: next, offset: self.pendingOffset)
                    } else { self.play(clip, index: next, offset: self.pendingOffset) }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == session, self.prefetchIndex == next else { return }
                self.prefetchIndex = nil
                self.prefetchTask = nil
                if self.segmentIndex == next, self.player == nil { self.fail(error) }
                // Otherwise retry only if the listener reaches this segment.
            }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var level = 0.0
        if let player, player.isPlaying {
            level = player.level()
        }
        bubble.update(level: level, time: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : now)
        guard let player, let document, let timeline = playingClip?.timeline else { return }
        let offset = document.segments[segmentIndex].range.location + playingTextOffset + timeline.offset(at: player.currentTime)
        let word = document.word(at: offset)
        textWindow.highlight(word)
        guard !geometryBusy, now - lastGeometryTime > 0.25, let source else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmost != source.processID {
            bubble.hide()
            return
        }
        geometryBusy = true
        lastGeometryTime = now
        let session = generation
        ReadingAccessibility.queue.async {
            let rect = ReadingAccessibility.wordBounds(word, in: source)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryBusy = false
                guard self.generation == session else { return }
                if let rect, let column = source.anchor {
                    self.anchor = CGRect(x: column.minX, y: rect.minY, width: column.width, height: rect.height)
                }
                self.updateBubble()
            }
        }
    }

    private func updateBubble() {
        guard isActive else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source?.processID else {
            bubble.hide()
            return
        }
        bubble.show(!wantsPlayback ? .paused : player == nil ? .loading : .playing, anchor: anchor)
    }

    private func fail(_ error: Error) {
        stop()
        onFailure?((error as? LocalizedError)?.errorDescription ?? "Read aloud failed. Try again.")
    }
}

@MainActor
protocol ReaderAudioPlaying: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var rate: Float { get set }
    var isPlaying: Bool { get }
    var onFinished: ((Bool) -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
    func level() -> Double
}

@MainActor
final class ReaderAudioOutput: NSObject, AVAudioPlayerDelegate, ReaderAudioPlaying {
    let audio: AVAudioPlayer
    var onFinished: ((Bool) -> Void)?

    init(data: Data) throws {
        audio = try AVAudioPlayer(data: data)
        super.init()
        audio.delegate = self
        audio.enableRate = true
        audio.isMeteringEnabled = true
        guard audio.prepareToPlay() else { throw SpeechClient.Failure.invalidResponse }
    }

    var currentTime: TimeInterval {
        get { audio.currentTime }
        set { audio.currentTime = newValue }
    }
    var duration: TimeInterval { audio.duration }
    var rate: Float {
        get { audio.rate }
        set { audio.rate = newValue }
    }
    var isPlaying: Bool { audio.isPlaying }
    func play() -> Bool { audio.play() }
    func pause() { audio.pause() }
    func stop() { audio.stop() }
    func level() -> Double {
        audio.updateMeters()
        return min(1, max(0, (Double(audio.averagePower(forChannel: 0)) + 50) / 50))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinished?(flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinished?(false) }
    }
}
