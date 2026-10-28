import AppKit

final class UsageDashboardView: NSView {
    override var isFlipped: Bool { true }
    private let store: UsageStore
    private let today = UsageMetricCard("TODAY")
    private let month = UsageMetricCard("THIS MONTH")
    private let lifetime = UsageMetricCard("SINCE TRACKING")
    private let chart = UsageChartView()
    private let speechCost = NSTextField(labelWithString: "")
    private let dictationCost = NSTextField(labelWithString: "")
    private let speechDetail = NSTextField(wrappingLabelWithString: "")
    private let dictationDetail = NSTextField(wrappingLabelWithString: "")
    private let trackingNote = NSTextField(wrappingLabelWithString: "")
    private let uncertainty = NSTextField(wrappingLabelWithString: "")
    private let accountStatus = NSTextField(wrappingLabelWithString: "Not loaded.")
    private let accountDetail = NSTextField(wrappingLabelWithString: "")
    private let quota = NSProgressIndicator()
    private let refreshButton = NSButton(title: "Refresh account", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var didRequestAccount = false

    init(store: UsageStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        buildUI()
        refreshLocal()
        observer = NotificationCenter.default.addObserver(forName: UsageStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.refreshLocal()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func activate() {
        refreshLocal()
        if !didRequestAccount { refreshAccount() }
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let title = NSTextField(labelWithString: "Your usage, at a glance")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        add(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Estimated FlowScribe API usage · USD")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        add(subtitle)
        let metrics = NSStackView(views: [today, month, lifetime])
        metrics.distribution = .fillEqually
        metrics.spacing = 8
        add(metrics)
        let chartTitle = NSTextField(labelWithString: "Last 7 days")
        chartTitle.font = .systemFont(ofSize: 12, weight: .medium)
        add(chartTitle)
        chart.heightAnchor.constraint(equalToConstant: 84).isActive = true
        add(chart)

        let details = NSStackView()
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        for (name, cost, detail) in [("ElevenLabs · Read aloud", speechCost, speechDetail), ("OpenAI · Dictation", dictationCost, dictationDetail)] {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            cost.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            let row = NSStackView(views: [label, NSView(), cost])
            details.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            details.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        add(details)
        for field in [trackingNote, uncertainty] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            add(field)
        }
        let separator = NSBox()
        separator.boxType = .separator
        add(separator)
        let accountTitle = NSTextField(labelWithString: "ElevenLabs account · All apps")
        accountTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        refreshButton.target = self
        refreshButton.action = #selector(refreshAccount)
        let accountHeader = NSStackView(views: [accountTitle, NSView(), refreshButton])
        add(accountHeader)
        accountStatus.font = .systemFont(ofSize: 12)
        accountDetail.font = .systemFont(ofSize: 11)
        accountDetail.textColor = .secondaryLabelColor
        add(accountStatus)
        quota.isIndeterminate = false
        quota.minValue = 0
        quota.maxValue = 1
        quota.isHidden = true
        add(quota)
        add(accountDetail)
        let estimateNote = NSTextField(wrappingLabelWithString: "Estimates use published API rates, not your invoice. Plans, included credits, voice surcharges and taxes can change the amount you pay. Tracking includes samples and prefetched audio. Earlier usage and usage in other apps are not included above.")
        estimateNote.font = .systemFont(ofSize: 11)
        estimateNote.textColor = .secondaryLabelColor
        add(estimateNote)
        let rates = NSButton(title: "Edit estimate rates…", target: self, action: #selector(editRates))
        let openAI = NSButton(title: "OpenAI usage ↗", target: self, action: #selector(openOpenAI))
        let elevenLabs = NSButton(title: "ElevenLabs ↗", target: self, action: #selector(openElevenLabs))
        add(NSStackView(views: [rates, openAI, elevenLabs]))
    }

    private func refreshLocal() {
        let snapshot = store.snapshot()
        let now = Date()
        let calendar = Calendar.current
        let monthly = calendar.dateInterval(of: .month, for: now)!
        let total = snapshot.totals()
        today.amount.stringValue = UsagePricing.formatUSD(snapshot.totals(in: calendar.dateInterval(of: .day, for: now)).estimatedUSD)
        month.amount.stringValue = UsagePricing.formatUSD(snapshot.totals(in: monthly).estimatedUSD)
        lifetime.amount.stringValue = UsagePricing.formatUSD(total.estimatedUSD)
        let speech = snapshot.totals(in: monthly, provider: .elevenLabs)
        let dictation = snapshot.totals(in: monthly, provider: .openAI)
        speechCost.stringValue = UsagePricing.formatUSD(speech.estimatedUSD)
        dictationCost.stringValue = UsagePricing.formatUSD(dictation.estimatedUSD)
        let credits = speech.requestsWithCredits > 0
            ? " · \(speech.reportedCredits.formatted(.number.precision(.fractionLength(0...2)))) reported credits on \(speech.requestsWithCredits) requests" : ""
        speechDetail.stringValue = "This month: \(Int(speech.characters).formatted()) characters · \(speech.requests) requests\(credits)"
        dictationDetail.stringValue = "This month: \(String(format: "%.1f", dictation.audioSeconds / 60)) minutes · \(dictation.requests) requests"
        let date = DateFormatter.localizedString(from: snapshot.startedAt, dateStyle: .medium, timeStyle: .short)
        trackingNote.stringValue = "Tracking started \(date). Only counts and estimates are saved on this Mac."
        var notes: [String] = []
        if total.requests == 0 { notes.append("No confirmed API usage recorded yet.") }
        if total.unpricedRequests > 0 { notes.append("\(total.unpricedRequests) requests have no known rate or duration and are excluded from the dollar totals.") }
        if total.unconfirmedRequests > 0 {
            notes.append("\(total.unconfirmedRequests) in-flight or interrupted requests: possible additional usage ≈\(UsagePricing.formatUSD(total.unconfirmedUSD)). Billing is unconfirmed; these are excluded above.")
        }
        uncertainty.stringValue = notes.joined(separator: " ")
        chart.values = (0..<7).map { index in
            let day = calendar.date(byAdding: .day, value: index - 6, to: now)!
            return (day, snapshot.totals(in: calendar.dateInterval(of: .day, for: day)).estimatedUSD)
        }
        chart.needsDisplay = true
        chart.setAccessibilityLabel("Estimated API usage over the last seven days")
    }

    @objc private func refreshAccount() {
        didRequestAccount = true
        task?.cancel()
        refreshButton.isEnabled = false
        accountStatus.stringValue = "Loading account usage…"
        task = Task { [weak self] in
            do {
                let subscription = try await SpeechClient().subscription()
                guard let self, !Task.isCancelled else { return }
                self.accountStatus.stringValue = "\(subscription.tier.capitalized) · \(subscription.characterCount.formatted()) / \(subscription.characterLimit.formatted()) credits used"
                self.quota.isHidden = subscription.characterLimit <= 0
                self.quota.doubleValue = subscription.characterLimit > 0 ? min(1, max(0, Double(subscription.characterCount) / Double(subscription.characterLimit))) : 0
                var detail: [String] = []
                if let reset = subscription.nextCharacterCountResetUnix, reset.isFinite {
                    detail.append("Credits reset \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: reset), dateStyle: .medium, timeStyle: .none)).")
                }
                if let cents = subscription.nextInvoice?.amountDueCents, cents.isFinite, cents >= 0,
                   let currency = subscription.currency, currency.count == 3 {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .currency
                    formatter.currencyCode = currency.uppercased()
                    if let amount = formatter.string(from: NSNumber(value: cents / 100)) {
                        detail.append("Next invoice: \(amount) \(currency.uppercased()) (account-wide).")
                    }
                }
                detail.append("Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)). These account values are separate from the local estimates.")
                self.accountDetail.stringValue = detail.joined(separator: " ")
                self.refreshButton.isEnabled = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.accountStatus.stringValue = (error as? LocalizedError)?.errorDescription ?? "Account usage is unavailable."
                self.accountDetail.stringValue = "Local tracking works without account access. Refresh after updating your key’s permissions."
                self.quota.isHidden = true
                self.refreshButton.isEnabled = true
            }
        }
    }

    @objc private func editRates() {
        let model = TranscriptionSupport.resolveModel()
        let entries: [(String, UsageProvider, String, Double)] = [
            ("Natural · USD / 1,000 characters", .elevenLabs, "eleven_multilingual_v2", 1000),
            ("Expressive · USD / 1,000 characters", .elevenLabs, "eleven_v3", 1000),
            ("Fast · USD / 1,000 characters", .elevenLabs, "eleven_flash_v2_5", 1000),
            ("Dictation · \(model) · USD / minute", .openAI, model, 60)
        ]
        let alert = NSAlert()
        alert.messageText = "Estimate rates (USD)"
        alert.informativeText = "Published rates checked October 28, 2026. Enter your own effective rates if needed. Changes apply to future requests; earlier estimates stay unchanged. Blank restores the published rate."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var fields: [NSTextField] = []
        for entry in entries {
            let label = NSTextField(labelWithString: entry.0)
            label.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(label)
            let field = NSTextField()
            field.stringValue = UsagePricing.rate(provider: entry.1, model: entry.2, defaults: .standard).map { String(format: "%.6g", $0 * entry.3) } ?? ""
            field.placeholderString = "Unknown rate"
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
            stack.addArrangedSubview(field)
            fields.append(field)
        }
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let values = fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".") }
        guard values.allSatisfy({ $0.isEmpty || Double($0).map { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } == true }) else {
            let invalid = NSAlert()
            invalid.messageText = "Enter valid, non-negative dollar amounts."
            invalid.runModal()
            return
        }
        for (index, entry) in entries.enumerated() {
            let key = UsagePricing.key(entry.1, entry.2)
            if let value = Double(values[index]) { UserDefaults.standard.set(value / entry.3, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        refreshLocal()
    }

    @objc private func openOpenAI() { NSWorkspace.shared.open(URL(string: "https://platform.openai.com/usage")!) }
    @objc private func openElevenLabs() { NSWorkspace.shared.open(URL(string: "https://elevenlabs.io/app/subscription")!) }
}

private final class UsageMetricCard: NSBox {
    let amount = NSTextField(labelWithString: "$0.00")
    init(_ title: String) {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 10
        fillColor = .controlBackgroundColor
        borderColor = .separatorColor
        borderWidth = 0.5
        heightAnchor.constraint(equalToConstant: 78).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .secondaryLabelColor
        amount.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        amount.lineBreakMode = .byClipping
        amount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, amount])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(stack)
        if let contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 9),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -9),
                stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class UsageChartView: NSView {
    var values: [(Date, Double)] = []
    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let maximum = values.map(\.1).max() ?? 0
        let step = bounds.width / CGFloat(values.count)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        for (index, entry) in values.enumerated() {
            let height = maximum > 0 ? max(2, CGFloat(entry.1 / maximum) * (bounds.height - 23)) : 2
            let bar = NSRect(x: CGFloat(index) * step + 8, y: 19, width: max(1, step - 16), height: height)
            (entry.1 > 0 ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            let label = formatter.string(from: entry.0) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
            label.draw(at: NSPoint(x: CGFloat(index) * step + (step - label.size(withAttributes: attributes).width) / 2, y: 0), withAttributes: attributes)
        }
        if maximum == 0 {
            let text = "Your next requests will appear here" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            text.draw(at: NSPoint(x: (bounds.width - text.size(withAttributes: attributes).width) / 2, y: 42), withAttributes: attributes)
        }
    }
}
