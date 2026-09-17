import AppKit

/// Small non-activating settings window: save / delete the Keychain API key.
/// Shows only masked status; never displays or logs the stored key.
final class SettingsWindowController: NSWindowController {
    private let statusField = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField(frame: .zero)
    private let saveButton = NSButton(title: "Save key", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete key", target: nil, action: nil)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    var onKeyChanged: (() -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "FlowScribe Settings"
        window.isReleasedWhenClosed = false // keep the controller's window alive across reopens
        window.center()
        self.init(window: window)
        buildUI()
        refreshStatus()
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

        let explanation = NSTextField(labelWithString: "The key is stored in your login Keychain (service com.flowscribe.app, account openai-api-key). An OPENAI_API_KEY environment variable takes precedence.")
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
        ])
    }

    func refreshStatus() {
        if APIKeyStore.resolveKey(environment: [:]) != nil {
            statusField.stringValue = "✓ A key is saved in Keychain."
        } else {
            statusField.stringValue = "No key saved in Keychain."
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

    func showWindowNonActivating() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
