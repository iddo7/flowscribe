import AppKit

/// A labeled sample preview lets users tune the pill without opening the microphone.
final class PillSettingsView: NSView {
    private var settings = PillSettings()
    private var sliders: [PillSettings.Field: NSSlider] = [:]
    private var valueLabels: [PillSettings.Field: NSTextField] = [:]
    private let previewPill = NSVisualEffectView()
    private let waveform = WaveformView(frame: .zero)
    private var previewWidth: NSLayoutConstraint!
    private var previewHeight: NSLayoutConstraint!
    private var previewTimer: Timer?
    private var previewIndex = 0

    // A repeatable example of syllables and pauses, clearly labeled as sample audio.
    private let sampleLevels: [Double] = [
        0, 0, 0, 0.04, 0.12, 0.3, 0.55, 0.72, 0.48, 0.25, 0.08, 0.02,
        0.1, 0.24, 0.5, 0.68, 0.44, 0.18, 0.06, 0, 0, 0.04, 0.2, 0.48,
        0.8, 0.6, 0.3, 0.1, 0.03, 0.14, 0.38, 0.64, 0.42, 0.2, 0.04, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        refreshControls()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Recording pill")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Tune the waveform to your voice. Settings are saved on this Mac across app updates and apply while recording.")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor

        let previewArea = NSView()
        previewArea.translatesAutoresizingMaskIntoConstraints = false
        previewArea.heightAnchor.constraint(equalToConstant: 86).isActive = true
        previewPill.material = .hudWindow
        previewPill.blendingMode = .withinWindow
        previewPill.state = .active
        previewPill.wantsLayer = true
        previewPill.layer?.masksToBounds = true
        previewPill.translatesAutoresizingMaskIntoConstraints = false
        waveform.translatesAutoresizingMaskIntoConstraints = false
        previewArea.addSubview(previewPill)
        previewPill.addSubview(waveform)
        previewWidth = previewPill.widthAnchor.constraint(equalToConstant: settings[.width])
        previewHeight = previewPill.heightAnchor.constraint(equalToConstant: settings[.height])
        NSLayoutConstraint.activate([
            previewPill.centerXAnchor.constraint(equalTo: previewArea.centerXAnchor),
            previewPill.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor),
            previewWidth, previewHeight,
            waveform.leadingAnchor.constraint(equalTo: previewPill.leadingAnchor, constant: 14),
            waveform.trailingAnchor.constraint(equalTo: previewPill.trailingAnchor, constant: -14),
            waveform.topAnchor.constraint(equalTo: previewPill.topAnchor, constant: 7),
            waveform.bottomAnchor.constraint(equalTo: previewPill.bottomAnchor, constant: -7),
        ])
        let previewLabel = NSTextField(labelWithString: "Sample preview · no microphone")
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.alignment = .center

        var rows: [NSView] = []
        for (index, field) in PillSettings.Field.allCases.enumerated() {
            let label = NSTextField(labelWithString: field.title)
            label.widthAnchor.constraint(equalToConstant: 126).isActive = true
            let slider = NSSlider(value: settings[field], minValue: field.range.lowerBound,
                                  maxValue: field.range.upperBound, target: self, action: #selector(sliderChanged(_:)))
            slider.tag = index
            slider.isContinuous = true
            slider.setAccessibilityLabel(field.title)
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 54).isActive = true
            let row = NSStackView(views: [label, slider, value])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            rows.append(row)
            sliders[field] = slider
            valueLabels[field] = value
        }

        let help = NSTextField(wrappingLabelWithString: "Lower sensitivity if the bars look too flat. Faster scrolling shows a shorter slice of audio; more bars reveal finer detail. These settings only change the display.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Restore defaults", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        let resetRow = NSStackView(views: [NSView(), reset])
        resetRow.orientation = .horizontal

        let stack = NSStackView(views: [title, description, previewArea, previewLabel] + rows + [help, resetRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
        ])
        for view in [description, previewArea, previewLabel] + rows + [help, resetRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let field = PillSettings.Field.allCases[sender.tag]
        settings[field] = sender.doubleValue
        settings.save()
        refreshControls()
    }

    @objc private func resetTapped() {
        settings = PillSettings(defaults: nil)
        settings.save()
        refreshControls()
    }

    private func refreshControls() {
        for field in PillSettings.Field.allCases {
            sliders[field]?.doubleValue = settings[field]
            valueLabels[field]?.stringValue = field.formatted(settings[field])
        }
        previewWidth.constant = settings[.width]
        previewHeight.constant = settings[.height]
        previewPill.layer?.cornerRadius = settings[.height] / 2
        waveform.configure(settings)
    }

    func startPreview() {
        guard previewTimer == nil else { return }
        waveform.startAnimating()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else {
                    self.stopPreview()
                    return
                }
                self.waveform.updateAudioLevels([self.sampleLevels[self.previewIndex]])
                self.previewIndex = (self.previewIndex + 1) % self.sampleLevels.count
            }
        }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewIndex = 0
        waveform.stopAnimating()
    }
}
