import AppKit

/// Settings for the Keychain API key, microphone, and recording pill.
/// Shows only masked status; never displays or logs the stored key.
final class SettingsWindowController: NSWindowController {
    private let statusField = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField(frame: .zero)
    private let saveButton = NSButton(title: "Save key", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete key", target: nil, action: nil)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputStatusField = NSTextField(wrappingLabelWithString: "")
    private var inputObserver: NSObjectProtocol?
    private let microphoneTestButton = NSButton(title: "Test microphone", target: nil, action: nil)
    private let microphoneTest = MicrophoneTest()
    private let noticeField = NSTextField(wrappingLabelWithString: "No errors reported. Microphone testing is local; no audio is uploaded.")

    var onKeyChanged: (() -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 465),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "FlowScribe Settings"
        window.isReleasedWhenClosed = false // keep the controller's window alive across reopens
        window.center()
        self.init(window: window)
        buildUI()
        refreshStatus()
        refreshInputs()
        inputObserver = NotificationCenter.default.addObserver(forName: AudioInputDevices.didChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshInputs()
        }
    }

    deinit {
        if let inputObserver { NotificationCenter.default.removeObserver(inputObserver) }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        keyField.placeholderString = "sk-…"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.bezelStyle = .rounded
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let positionLabel = NSTextField(labelWithString: "Pill position")
        positionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        positionLabel.translatesAutoresizingMaskIntoConstraints = false

        positionPopup.addItems(withTitles: HUDPosition.allCases.map(\.title))
        positionPopup.selectItem(withTitle: HUDPosition.selected.title)
        positionPopup.target = self
        positionPopup.action = #selector(positionChanged)
        positionPopup.translatesAutoresizingMaskIntoConstraints = false

        let inputLabel = NSTextField(labelWithString: "Microphone")
        inputLabel.font = .systemFont(ofSize: 13, weight: .medium)
        inputLabel.translatesAutoresizingMaskIntoConstraints = false
        inputPopup.target = self
        inputPopup.action = #selector(inputChanged)
        inputPopup.translatesAutoresizingMaskIntoConstraints = false
        inputStatusField.font = .systemFont(ofSize: 11)
        inputStatusField.textColor = .secondaryLabelColor
        inputStatusField.translatesAutoresizingMaskIntoConstraints = false

        microphoneTestButton.target = self
        microphoneTestButton.action = #selector(testMicrophoneTapped)
        microphoneTestButton.bezelStyle = .rounded
        microphoneTestButton.translatesAutoresizingMaskIntoConstraints = false
        let noticeLabel = NSTextField(labelWithString: "Latest message")
        noticeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeField.font = .systemFont(ofSize: 12)
        noticeField.textColor = .secondaryLabelColor
        noticeField.isSelectable = true
        noticeField.translatesAutoresizingMaskIntoConstraints = false
        let shortcuts = NSTextField(wrappingLabelWithString: "⌘H hides Settings; ⌘W closes it. Reopen with ⌃⌥, or launch FlowScribe from Finder or Spotlight.")
        shortcuts.font = .systemFont(ofSize: 11)
        shortcuts.textColor = .secondaryLabelColor
        shortcuts.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString: "The key is stored in your login Keychain (service com.flowscribe.app, account openai-api-key). An OPENAI_API_KEY environment variable takes precedence.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.lineBreakMode = .byWordWrapping
        explanation.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(explanation)
        content.addSubview(keyField)
        content.addSubview(saveButton)
        content.addSubview(deleteButton)
        content.addSubview(statusField)
        content.addSubview(separator)
        content.addSubview(positionLabel)
        content.addSubview(positionPopup)
        content.addSubview(inputLabel)
        content.addSubview(inputPopup)
        content.addSubview(inputStatusField)
        content.addSubview(microphoneTestButton)
        content.addSubview(noticeLabel)
        content.addSubview(noticeField)
        content.addSubview(shortcuts)

        NSLayoutConstraint.activate([
            explanation.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            keyField.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            keyField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            keyField.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            keyField.heightAnchor.constraint(equalToConstant: 24),

            saveButton.centerYAnchor.constraint(equalTo: keyField.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),

            deleteButton.centerYAnchor.constraint(equalTo: keyField.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            statusField.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 12),
            statusField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            positionLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            positionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            positionPopup.centerYAnchor.constraint(equalTo: positionLabel.centerYAnchor),
            positionPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            positionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            inputLabel.topAnchor.constraint(equalTo: positionPopup.bottomAnchor, constant: 20),
            inputLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            inputPopup.centerYAnchor.constraint(equalTo: inputLabel.centerYAnchor),
            inputPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 130),
            inputPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            inputStatusField.topAnchor.constraint(equalTo: inputPopup.bottomAnchor, constant: 8),
            inputStatusField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            inputStatusField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            microphoneTestButton.topAnchor.constraint(equalTo: inputStatusField.bottomAnchor, constant: 12),
            microphoneTestButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            noticeLabel.topAnchor.constraint(equalTo: microphoneTestButton.bottomAnchor, constant: 16),
            noticeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            noticeField.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 6),
            noticeField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            noticeField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            noticeField.bottomAnchor.constraint(lessThanOrEqualTo: shortcuts.topAnchor, constant: -12),
            shortcuts.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            shortcuts.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            shortcuts.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    func refreshStatus() {
        switch APIKeyStore.containsKeychainKey() {
        case true?:
            statusField.stringValue = "✓ A key is saved in Keychain."
        case false?:
            statusField.stringValue = "No key saved in Keychain."
        case nil:
            statusField.stringValue = "Could not check Keychain status."
        }
    }

    @objc private func saveTapped() {
        let key = keyField.stringValue
        let ok = APIKeyStore.saveKey(key)
        statusField.stringValue = ok
            ? "✓ Key saved to Keychain."
            : "Could not save key (empty input or Keychain error)."
        if ok { keyField.stringValue = "" ; onKeyChanged?() }
    }

    @objc private func deleteTapped() {
        let ok = APIKeyStore.deleteKey()
        statusField.stringValue = ok
            ? "Key deleted from Keychain."
            : "Could not delete key."
        if ok { onKeyChanged?() }
    }

    @objc private func positionChanged() {
        guard let title = positionPopup.selectedItem?.title,
              let position = HUDPosition.allCases.first(where: { $0.title == title }) else { return }
        HUDPosition.selected = position
    }

    private func refreshInputs() {
        let inventory = AudioInputDevices.shared
        let devices = inventory.available()
        let preferredUID = AudioInputSelection.selectedUID
        let defaultDeviceID = inventory.defaultDeviceID()
        let defaultDevice = devices.first { $0.id == defaultDeviceID }
        inputPopup.removeAllItems()
        inputPopup.addItem(withTitle: "System Default")
        for device in devices {
            // Use UIDs rather than labels: microphones can have identical names.
            inputPopup.menu?.addItem(NSMenuItem(title: device.name, action: nil, keyEquivalent: ""))
            inputPopup.lastItem?.representedObject = device.uid
        }
        if let preferredUID {
            if let item = inputPopup.itemArray.first(where: { $0.representedObject as? String == preferredUID }) {
                inputPopup.select(item)
                inputStatusField.stringValue = "Uses this microphone independently of your Mac’s default input."
            } else {
                inputPopup.addItem(withTitle: "Selected microphone (disconnected)")
                inputPopup.lastItem?.representedObject = preferredUID
                inputPopup.select(inputPopup.lastItem)
                inputStatusField.stringValue = "Using \(defaultDevice?.name ?? "no available input") until the selected microphone reconnects."
            }
        } else {
            inputPopup.selectItem(at: 0)
            inputStatusField.stringValue = defaultDevice.map { "Follows your Mac’s input: \($0.name)." }
                ?? "No microphone is currently available."
        }
    }

    @objc private func inputChanged() {
        AudioInputSelection.selectedUID = inputPopup.selectedItem?.representedObject as? String
        refreshInputs()
    }

    func showNotice(title: String, body: String) {
        noticeField.stringValue = "\(title): \(body)"
        noticeField.textColor = .labelColor
    }

    @objc private func testMicrophoneTapped() {
        microphoneTestButton.isEnabled = false
        showNotice(title: "Microphone test", body: "Checking input for two seconds. No audio will be uploaded.")
        Task { [weak self] in
            let granted = await Permissions.requestMicrophoneAccess()
            guard let self else { return }
            guard granted else {
                self.microphoneTestButton.isEnabled = true
                self.showNotice(title: "Microphone access denied", body: "Grant access in System Settings → Privacy & Security → Microphone.")
                return
            }
            self.microphoneTest.start { [weak self] result in
                guard let self else { return }
                self.microphoneTestButton.isEnabled = true
                switch result {
                case .success(let seconds):
                    self.showNotice(title: "Microphone is working", body: String(format: "Received %.1f seconds of audio. Nothing was uploaded.", seconds))
                case .failure(let error):
                    self.showNotice(title: "Microphone test failed", body: error.localizedDescription)
                }
            }
        }
    }

    func showWindowNonActivating() {
        refreshInputs()
        NSApp.unhide(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
