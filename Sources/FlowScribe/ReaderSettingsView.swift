import AppKit

final class ReaderSettingsView: NSView {
    private let key = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    let voices = NSPopUpButton()
    let voiceID = NSTextField()
    private let voiceStatus = NSTextField(wrappingLabelWithString: "")
    private let applyVoiceButton = NSButton(title: "Apply voice", target: nil, action: nil)
    private let models = NSPopUpButton()
    private let speed = NSPopUpButton()
    private let offers = NSButton(checkboxWithTitle: "Show a discreet button beside longer selections", target: nil, action: nil)
    private let loadButton = NSButton(title: "Load my voices", target: nil, action: nil)
    let previewButton = NSButton(title: "Listen to a sample", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var sample: (any ReaderAudioPlaying)?
    private let defaults: UserDefaults
    private let client: SpeechClient
    private let makePlayer: @MainActor (Data) throws -> any ReaderAudioPlaying
    private var availableVoices = [SpeechVoice(voiceId: "JBFqnCBsd6RMkjVDRZzb", name: "George · default")]
    private let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    override var isFlipped: Bool { true }

    init(defaults: UserDefaults = .standard, client: SpeechClient = SpeechClient(),
         makePlayer: @escaping @MainActor (Data) throws -> any ReaderAudioPlaying = { try ReaderAudioOutput(data: $0) }) {
        self.defaults = defaults
        self.client = client
        self.makePlayer = makePlayer
        super.init(frame: .zero)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        let settings = ReaderSettings.load(defaults: defaults)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
        func label(_ text: String, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: secondary ? 11 : 13, weight: secondary ? .regular : .medium)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            return field
        }
        func add(_ view: NSView, fullWidth: Bool = false) {
            stack.addArrangedSubview(view)
            if fullWidth { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        add(label("Read aloud with ElevenLabs"))
        add(label("Select text in another app and press ⌃⌥R. Click the audio bubble to pause or resume; press Esc to stop.", secondary: true), fullWidth: true)
        key.placeholderString = "ElevenLabs API key"
        key.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteKey))
        let keys = NSStackView(views: [key, save, delete])
        keys.spacing = 8
        add(keys, fullWidth: true)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        add(status, fullWidth: true)
        refreshKeyStatus()

        loadButton.target = self
        loadButton.action = #selector(loadVoices)
        voices.target = self
        voices.action = #selector(voiceChanged)
        add(label("Voice"))
        let voiceRow = NSStackView(views: [voices, loadButton])
        voices.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voiceRow.spacing = 8
        add(voiceRow, fullWidth: true)
        voiceID.placeholderString = "Or paste a voice ID from ElevenLabs"
        voiceID.stringValue = settings.voiceID
        voiceID.target = self
        voiceID.action = #selector(applyVoice)
        voiceID.delegate = self
        voiceID.setAccessibilityLabel("ElevenLabs voice ID")
        applyVoiceButton.target = self
        applyVoiceButton.action = #selector(applyVoice)
        let voiceIDRow = NSStackView(views: [voiceID, applyVoiceButton])
        voiceIDRow.spacing = 8
        voiceID.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(voiceIDRow, fullWidth: true)
        voiceStatus.font = .systemFont(ofSize: 11)
        voiceStatus.textColor = .secondaryLabelColor
        add(voiceStatus, fullWidth: true)
        refreshVoiceMenu(selectedID: settings.voiceID)
        voiceStatus.stringValue = "Saved automatically. Start a new reading to use this voice."
        models.addItems(withTitles: ReaderSettings.VoiceModel.allCases.map(\.title))
        models.selectItem(at: ReaderSettings.VoiceModel.allCases.firstIndex(of: settings.model) ?? 0)
        models.target = self
        models.action = #selector(savePreferences)
        add(models, fullWidth: true)
        speed.addItems(withTitles: rates.map { "\($0)×" })
        speed.selectItem(at: rates.firstIndex(of: settings.speed) ?? 1)
        speed.target = self
        speed.action = #selector(savePreferences)
        let speedRow = NSStackView(views: [label("Reading speed"), speed])
        speedRow.spacing = 12
        add(speedRow)
        offers.state = settings.offersSelection ? .on : .off
        offers.target = self
        offers.action = #selector(savePreferences)
        add(offers)
        previewButton.target = self
        previewButton.action = #selector(preview)
        add(previewButton)
        add(label("Click a word in the selected passage to jump when the app exposes word positions. The bubble’s ••• menu also opens a reading view with clickable words.", secondary: true), fullWidth: true)
        add(label("Only requested text and one upcoming segment are sent to ElevenLabs. Your key stays in Keychain; audio and reading text are kept in memory until you stop. Language is detected automatically; accent depends on the voice. Samples use ElevenLabs credits.", secondary: true), fullWidth: true)
    }

    func showNotice(_ message: String) { status.stringValue = message }

    private func refreshKeyStatus() {
        if ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?.isEmpty == false {
            status.stringValue = "Using ELEVENLABS_API_KEY from the environment."
        } else {
            switch APIKeyStore.containsKeychainKey(account: ElevenLabsKeyStore.account) {
            case true?: status.stringValue = "✓ ElevenLabs key saved in Keychain."
            case false?: status.stringValue = "Add your own ElevenLabs API key to start reading."
            case nil: status.stringValue = "Could not check Keychain status."
            }
        }
    }

    @objc private func saveKey() {
        if APIKeyStore.saveKey(key.stringValue, account: ElevenLabsKeyStore.account) {
            key.stringValue = ""
            refreshKeyStatus()
        } else { status.stringValue = "Could not save key. Check the input and try again." }
    }

    @objc private func deleteKey() {
        if APIKeyStore.deleteKey(account: ElevenLabsKeyStore.account) { refreshKeyStatus() }
        else { status.stringValue = "Could not delete the ElevenLabs key." }
    }

    private func refreshVoiceMenu(selectedID: String) {
        voices.removeAllItems()
        for voice in availableVoices {
            voices.addItem(withTitle: voice.name)
            voices.lastItem?.representedObject = voice.voiceId
        }
        if !availableVoices.contains(where: { $0.voiceId == selectedID }) {
            voices.addItem(withTitle: "Custom voice · \(selectedID.prefix(8))…")
            voices.lastItem?.representedObject = selectedID
        }
        if let index = voices.itemArray.firstIndex(where: { $0.representedObject as? String == selectedID }) {
            voices.selectItem(at: index)
        }
    }

    private func stopSample() {
        task?.cancel()
        sample?.stop()
        if sample != nil { status.stringValue = "Previous voice sample stopped." }
        sample = nil
        loadButton.isEnabled = true
    }

    /// Read the field editor too: clicking a button need not end NSTextField editing.
    @discardableResult
    private func saveVoice() -> Bool {
        let input = voiceID.currentEditor()?.string ?? voiceID.stringValue
        guard let id = ReaderVoiceID.normalized(input) else {
            stopSample()
            previewButton.isEnabled = false
            voiceStatus.stringValue = "Paste a valid ElevenLabs voice ID, then click Apply voice. The previous voice is kept until the ID is valid."
            return false
        }
        var settings = ReaderSettings.load(defaults: defaults)
        let changed = settings.voiceID != id
        if changed {
            stopSample()
            settings.voiceID = id
            settings.save(defaults: defaults)
        }
        refreshVoiceMenu(selectedID: id)
        previewButton.isEnabled = true
        voiceStatus.stringValue = "✓ Voice saved. The next sample and new reading will use this ID."
        if changed { NotificationCenter.default.post(name: ReaderSettings.voiceDidChange, object: self) }
        return true
    }

    @objc private func applyVoice() {
        guard saveVoice() else { return }
        // Commit whitespace normalization without abandoning an in-progress paste.
        window?.makeFirstResponder(nil)
        voiceID.stringValue = ReaderSettings.load(defaults: defaults).voiceID
    }

    @objc private func voiceChanged() {
        guard let id = voices.selectedItem?.representedObject as? String else { return }
        window?.makeFirstResponder(nil)
        voiceID.stringValue = id
        saveVoice()
    }

    @objc private func savePreferences() {
        var settings = ReaderSettings.load(defaults: defaults)
        settings.model = ReaderSettings.VoiceModel.allCases[max(0, models.indexOfSelectedItem)]
        settings.speed = rates[max(0, speed.indexOfSelectedItem)]
        settings.offersSelection = offers.state == .on
        settings.save(defaults: defaults)
    }

    @objc private func loadVoices() {
        task?.cancel()
        sample?.stop()
        previewButton.isEnabled = true
        loadButton.isEnabled = false
        status.stringValue = "Loading voices…"
        task = Task { [weak self] in
            do {
                guard let client = self?.client else { return }
                let list = try await client.voices()
                guard let self, !Task.isCancelled else { return }
                let selected = ReaderSettings.load(defaults: self.defaults).voiceID
                self.availableVoices = list
                self.refreshVoiceMenu(selectedID: selected)
                self.status.stringValue = "\(list.count) voices available. Choose a voice or enter its ID."
                self.loadButton.isEnabled = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status.stringValue = (error as? LocalizedError)?.errorDescription ?? "Could not load voices."
                self.loadButton.isEnabled = true
            }
        }
    }

    @objc private func preview() {
        guard saveVoice() else { return }
        savePreferences()
        task?.cancel()
        sample?.stop()
        previewButton.isEnabled = false
        loadButton.isEnabled = true
        status.stringValue = "Preparing a voice sample…"
        let settings = ReaderSettings.load(defaults: defaults)
        task = Task { [weak self] in
            do {
                guard let client = self?.client else { return }
                let clip = try await client.synthesize("Bonjour! Prenez un moment pour écouter. A natural voice brings every sentence to life.", settings: settings)
                guard let self, !Task.isCancelled else { return }
                let player = try self.makePlayer(clip.audio)
                player.rate = settings.speed
                self.sample = player
                guard player.play() else { throw SpeechClient.Failure.invalidResponse }
                self.status.stringValue = "Playing sample · \(self.voices.titleOfSelectedItem ?? "Selected voice")."
                self.previewButton.isEnabled = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status.stringValue = (error as? LocalizedError)?.errorDescription ?? "Could not play sample."
                self.previewButton.isEnabled = true
            }
        }
    }
}

extension ReaderSettingsView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === voiceID else { return }
        saveVoice()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === voiceID else { return }
        saveVoice()
    }
}
