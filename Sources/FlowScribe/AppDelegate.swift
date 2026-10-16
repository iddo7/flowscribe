import AppKit

/// Owns the menu bar item, state machine, audio capture, transcription and delivery.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let stateMachine = TranscriptionStateMachine()
    private let hud = HUDController()
    private let capture = AudioCapture()
    private let client = TranscriptionClient()
    private let paste = PasteController()
    private let hotKeys = HotKeyManager()
    private lazy var settingsWindow = SettingsWindowController()

    private var statusItem: NSStatusItem?
    private var capturedTarget: PasteController.Target?
    private var pendingTempFile: URL?
    private var permissionTask: Task<Void, Never>?
    private var permissionRequestID: UUID?
    private var transcriptionTask: Task<Void, Never>?
    private var captureSessionID: UUID?
    private var isHotKeyHeld = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpApplicationMenu()
        setUpMenu()
        capture.onFailure = { [weak self] sessionID, error in
            guard let self, self.captureSessionID == sessionID else { return }
            self.handleCaptureFailure(error)
        }
        capture.onAudioLevels = { [weak self] sessionID, levels in
            guard let self, self.captureSessionID == sessionID,
                  self.stateMachine.state == .recording else { return }
            self.hud.updateAudioLevels(levels)
        }
        hotKeys.onPress = { [weak self] in self?.handleHotKeyPressed() }
        hotKeys.onRelease = { [weak self] in self?.handleHotKeyReleased() }
        hotKeys.onSettings = { [weak self] in self?.settingsTapped() }
        if !hotKeys.register() {
            presentNotice(title: "FlowScribe", body: "Could not register the ⌃⌥Space global shortcut. It may be in use by another app.")
        }
        _ = Permissions.requestAccessibilityIfNeeded()
        updateMenu()
        if !hotKeys.isSettingsShortcutRegistered {
            presentNotice(title: "Settings shortcut unavailable",
                          body: "⌃⌥, is already in use. Reopen FlowScribe from Finder or Spotlight to open Settings.")
        }
        settingsTapped()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsTapped()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
        permissionTask?.cancel()
        permissionRequestID = nil
        transcriptionTask?.cancel()
        captureSessionID = nil
        isHotKeyHeld = false
        capture.discard()
        cleanupPendingFile()
    }

    // MARK: - Menu bar

    private func setUpApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "FlowScribe")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide FlowScribe", action: #selector(hideSettingsTapped), keyEquivalent: "h")
        hide.target = self
        applicationMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        applicationMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAll.target = NSApp
        applicationMenu.addItem(showAll)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FlowScribe", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        applicationMenu.addItem(quit)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Start dictation (hold ⌃⌥Space)", action: #selector(toggleTapped), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit FlowScribe", action: #selector(quitTapped), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func updateMenu() {
        guard let menu = statusItem?.menu else { return }
        let first = menu.items.first
        switch stateMachine.state {
        case .idle:
            first?.title = "Start dictation (hold ⌃⌥Space)"
            first?.isEnabled = true
            statusItem?.button?.title = "🎙"
            statusItem?.button?.appearsDisabled = false
        case .recording:
            first?.title = "Stop & transcribe"
            first?.isEnabled = true
            statusItem?.button?.title = "🔴"
        case .transcribing:
            first?.title = "Transcribing…"
            first?.isEnabled = false
            statusItem?.button?.title = "…"
        }
    }

    @objc private func toggleTapped() { handleMenuToggle() }

    @objc private func settingsTapped() {
        settingsWindow.showWindowNonActivating()
    }

    @objc private func hideSettingsTapped() {
        // NSApplication.hide is disabled for accessory apps; hide our window directly.
        settingsWindow.window?.orderOut(nil)
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    // MARK: - Hold-to-talk hotkey and menu fallback

    private func handleMenuToggle() {
        switch stateMachine.event(forToggle: ()) {
        case .startRecordingRequested?:
            requestStartRecording()
        case .stopRecordingRequested?:
            stopRecordingAndTranscribe()
        default:
            break // transcribing: ignore
        }
    }

    private func handleHotKeyPressed() {
        guard !isHotKeyHeld else { return }
        isHotKeyHeld = true
        guard stateMachine.canStartRecording else { return }
        requestStartRecording()
    }

    private func handleHotKeyReleased() {
        guard isHotKeyHeld else { return }
        isHotKeyHeld = false

        if let task = permissionTask {
            task.cancel()
            permissionTask = nil
            permissionRequestID = nil
            capturedTarget = nil
            return
        }

        if stateMachine.canStop {
            stopRecordingAndTranscribe()
        }
    }

    private func requestStartRecording() {
        guard permissionTask == nil, stateMachine.canStartRecording else { return }
        capturedTarget = PasteController.rememberPasteTarget()
        let requestID = UUID()
        permissionRequestID = requestID
        permissionTask = Task { [weak self] in
            let granted = await Permissions.requestMicrophoneAccess()
            guard let self, self.permissionRequestID == requestID else { return }
            self.permissionTask = nil
            self.permissionRequestID = nil
            guard !Task.isCancelled else { return }
            guard granted else {
                self.capturedTarget = nil
                self.presentNotice(
                    title: "FlowScribe needs microphone access",
                    body: "Grant access in System Settings → Privacy & Security → Microphone.",
                    recovery: .openMicrophoneSettings
                )
                return
            }
            self.beginRecording()
        }
    }

    private func beginRecording() {
        guard stateMachine.handle(.startRecordingRequested) else { return }
        let sessionID = UUID()
        captureSessionID = sessionID
        updateMenu()
        hud.show(state: stateMachine.state, near: capturedTarget?.anchorRect)
        capture.start(sessionID: sessionID) { [weak self] result in
            guard let self, self.captureSessionID == sessionID else { return }
            if case .failure(let error) = result {
                self.handleCaptureFailure(error)
            }
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        captureSessionID = nil
        stateMachine.handle(.resetRequested)
        capture.discard()
        capturedTarget = nil
        hud.hide()
        updateMenu()
        presentNotice(title: "FlowScribe can’t record",
                      body: (error as? LocalizedError)?.errorDescription ?? "Unknown microphone error.")
    }

    private func stopRecordingAndTranscribe() {
        guard let sessionID = captureSessionID,
              stateMachine.handle(.stopRecordingRequested) else { return }
        hud.update(state: stateMachine.state, near: capturedTarget?.anchorRect)
        updateMenu()

        capture.stop(sessionID: sessionID) { [weak self] result in
            guard let self, self.captureSessionID == sessionID else {
                if case .success(let file?) = result { TempFileStore.remove(file) }
                return
            }
            self.captureSessionID = nil
            switch result {
            case .success(let file?):
                self.beginTranscription(file: file)
            case .success(nil):
                self.resetAfterShortRecording()
            case .failure(let error):
                self.stateMachine.handle(.resetRequested)
                self.hud.hide()
                self.updateMenu()
                self.capturedTarget = nil
                self.presentNotice(
                    title: error is AudioCapture.CaptureError ? "FlowScribe received no audio" : "FlowScribe couldn’t save the recording",
                    body: (error as? LocalizedError)?.errorDescription ?? "A local file error occurred."
                )
            }
        }
    }

    private func beginTranscription(file: URL) {
        pendingTempFile = file

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<String, Error>
            do {
                let text = try await self.client.transcribe(fileAt: file)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            TempFileStore.remove(file)
            if self.pendingTempFile == file { self.pendingTempFile = nil }
            self.transcriptionTask = nil
            guard !Task.isCancelled else { return }
            self.finishTranscription(result)
        }
    }

    private func resetAfterShortRecording() {
        stateMachine.handle(.resetRequested)
        let anchor = capturedTarget?.anchorRect
        capturedTarget = nil
        hud.showFailure(near: anchor)
        updateMenu()
        presentNotice(title: "FlowScribe", body: "Recording was too short — nothing to transcribe.")
    }

    private func finishTranscription(_ result: Result<String, Error>) {
        let target = capturedTarget
        stateMachine.handle(.resetRequested)
        capturedTarget = nil
        updateMenu()

        switch result {
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? "Transcription failed."
            var recovery: Notice.Recovery = .none
            if case TranscriptionClient.APIError.Kind.missingAPIKey? = (error as? TranscriptionClient.APIError)?.kind {
                recovery = .openSettings
            }
            hud.showFailure(near: target?.anchorRect)
            presentNotice(title: "Transcription failed", body: message, recovery: recovery)

        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                hud.showFailure(near: target?.anchorRect)
                presentNotice(title: "FlowScribe", body: "The service returned no text.")
                return
            }
            paste.deliver(PasteController.Deliverable(
                text: trimmed,
                targetBundleID: target?.bundleID,
                targetLocalizedName: target?.localizedName
            )) { [weak self] delivery in
                self?.handleDeliveryResult(delivery, near: target?.anchorRect)
            }
        }
    }

    private func handleDeliveryResult(_ delivery: PasteController.DeliveryResult, near anchor: CGRect?) {
        switch delivery {
        case .pasted:
            hud.showSuccess(near: anchor)
        case .clipboardOnly:
            hud.showFailure(near: anchor)
            presentNotice(title: "Transcript copied",
                          body: "Grant FlowScribe Accessibility access to paste automatically. The transcript is on your clipboard — ⌘V where you want it.",
                          recovery: .openAccessibilitySettings)
        case .failed(let message):
            hud.showFailure(near: anchor)
            presentNotice(title: "FlowScribe", body: message)
        }
    }

    private func cleanupPendingFile() {
        if let file = pendingTempFile {
            TempFileStore.remove(file)
            pendingTempFile = nil
        }
    }

    // MARK: - User notices

    private func presentNotice(title: String, body: String, recovery: Notice.Recovery = .none) {
        settingsWindow.showNotice(title: title, body: body)
        let notice = NSUserNotification()
        notice.title = title
        notice.informativeText = body
        NSUserNotificationCenter.default.deliver(notice)

        switch recovery {
        case .none:
            break
        case .openSettings:
            settingsWindow.showWindowNonActivating()
        case .openMicrophoneSettings:
            Permissions.openSettings(for: .microphone)
        case .openAccessibilitySettings:
            Permissions.openSettings(for: .accessibility)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }
}

/// Simple classification used to decide which Settings pane to open after a notice.
enum Notice {
    enum Recovery { case none, openSettings, openMicrophoneSettings, openAccessibilitySettings }
}
