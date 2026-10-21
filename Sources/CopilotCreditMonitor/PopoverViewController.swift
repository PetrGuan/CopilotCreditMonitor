import AppKit
import CreditMonitorCore

@MainActor
final class PopoverViewController: NSViewController, NSTextFieldDelegate {
    static let panelWidth: CGFloat = 360
    private static let contentWidth: CGFloat = panelWidth - 48

    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSaveBudget: ((String, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void)?
    var onPreviewBudget: ((String) -> String?)?
    var onSaveManualUsage: ((String, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void)?
    var onPreviewManualUsage: ((String) -> String?)?
    var onContentSizeChange: ((NSSize) -> Void)?

    private enum Mode { case summary, settings, manual }
    private var mode: Mode = .summary
    private var currentSnapshot: MonitorSnapshot?
    private var isSaving = false
    private var editGeneration = 0

    private let rootStack = NSStackView()
    private let summaryStack = NSStackView()
    private let settingsStack = NSStackView()
    private let statusLabel = label("本机", size: 10, weight: .medium)
    private let amountLabel = label("—", size: 52, weight: .medium)
    private let budgetLabel = label("每周额度 $1,000.00", size: 11, secondary: true)
    private let usedValue = label("—", size: 15, weight: .medium, numeric: true)
    private let percentageValue = label("—", size: 15, weight: .medium, numeric: true)
    private let progress = FrostProgressView()
    private let importLabel = label("正在读取用量…", size: 11, secondary: true)
    private let warningLabel = label("", size: 11)
    private let refreshButton = FrostButton(title: "刷新", symbol: "arrow.clockwise")
    private let settingsButton = FrostButton(title: "", symbol: "slider.horizontal.3")
    private let manualButton = FrostButton(title: "扣除", symbol: "minus.circle")
    private let quitButton = FrostButton(title: "", symbol: "power")

    private let inputCard = FrostCardView()
    private let settingsInput = NSTextField(string: "")
    private let previewValue = label("—", size: 23, weight: .medium, numeric: true)
    private let settingsError = label("", size: 11)
    private let backButton = FrostButton(title: "", symbol: "chevron.left")
    private let cancelButton = FrostButton(title: "取消")
    private let saveButton = FrostButton(title: "保存额度", style: .primary)
    private let editorTitle = label("每周额度", size: 13, weight: .semibold)
    private let inputTitle = label("每周预算", size: 11, secondary: true)
    private let inputHint = label("默认 $1,000.00 / 周", size: 10, secondary: true)
    private let previewTitle = label("保存后，本周剩余", size: 10, secondary: true)
    private let previewHint = label("已用金额保持不变", size: 10, secondary: true)
    private let editorNote = label("额度立即生效，并沿用至后续每周。", size: 10, secondary: true)

    override func loadView() {
        view = FrostMaterialView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 360))
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.detachesHiddenViews = true
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.widthAnchor.constraint(equalToConstant: Self.panelWidth),
        ])
        buildSummary()
        buildSettings()
        rootStack.addArrangedSubview(summaryStack)
        rootStack.addArrangedSubview(settingsStack)
        settingsStack.isHidden = true
        renderSnapshot()
        updateContentSize()
    }

    func update(snapshot: MonitorSnapshot) {
        currentSnapshot = snapshot
        guard isViewLoaded else { return }
        renderSnapshot()
    }

    func prepareForClose() {
        guard isViewLoaded else { return }
        editGeneration += 1
        show(.summary, animated: false)
        settingsInput.stringValue = ""
        settingsError.stringValue = ""
    }

    private func buildSummary() {
        configurePage(summaryStack, spacing: 20)

        let emblem = NSImageView()
        emblem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        emblem.contentTintColor = FrostPalette.accent
        emblem.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emblem.widthAnchor.constraint(equalToConstant: 22),
            emblem.heightAnchor.constraint(equalToConstant: 26),
        ])
        let title = Self.label("Copilot Credit", size: 13, weight: .semibold)
        let heading = row([emblem, title, NSView(), statusLabel], spacing: 9)
        statusLabel.textColor = FrostPalette.accent
        summaryStack.addArrangedSubview(heading)
        summaryStack.setCustomSpacing(24, after: heading)

        let hero = column([
            Self.label("本周剩余", size: 11, secondary: true),
            amountLabel,
            budgetLabel,
        ], spacing: 7)
        amountLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        hero.setCustomSpacing(5, after: amountLabel)
        summaryStack.addArrangedSubview(hero)

        let statsCard = FrostCardView()
        let left = column([Self.label("本周已用", size: 10, secondary: true), usedValue], spacing: 5)
        let rightTitle = Self.label("剩余额度", size: 10, secondary: true)
        rightTitle.alignment = .right
        percentageValue.alignment = .right
        let right = column([rightTitle, percentageValue], spacing: 5)
        let stats = row([left, right], spacing: 20)
        stats.distribution = .fillEqually
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let statsContent = column([progress, stats], spacing: 15)
        pin(statsContent, inside: statsCard, inset: 16)
        summaryStack.addArrangedSubview(statsCard)
        summaryStack.setCustomSpacing(12, after: statsCard)

        importLabel.lineBreakMode = .byTruncatingTail
        summaryStack.addArrangedSubview(importLabel)
        warningLabel.textColor = .systemOrange
        warningLabel.maximumNumberOfLines = 2
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.isHidden = true
        summaryStack.addArrangedSubview(warningLabel)

        let footer = row([refreshButton, NSView(), manualButton, settingsButton, quitButton], spacing: 7)
        refreshButton.widthAnchor.constraint(equalToConstant: 65).isActive = true
        connect(refreshButton, action: #selector(refresh), help: "刷新用量")
        connect(settingsButton, action: #selector(openSettings), help: "额度设置")
        connect(manualButton, action: #selector(openManualUsage), help: "手动扣除其他电脑已用的美元金额")
        manualButton.widthAnchor.constraint(equalToConstant: 65).isActive = true
        manualButton.isEnabled = false
        connect(quitButton, action: #selector(quit), help: "退出 Copilot Credit Monitor")
        let divider = separator()
        summaryStack.addArrangedSubview(divider)
        summaryStack.setCustomSpacing(8, after: divider)
        summaryStack.addArrangedSubview(footer)
        constrainPageContents(summaryStack)
    }

    private func buildSettings() {
        configurePage(settingsStack, spacing: 20)
        let header = row([backButton, editorTitle, NSView()], spacing: 7)
        connect(backButton, action: #selector(cancelSettings), help: "返回余额")
        settingsStack.addArrangedSubview(header)

        settingsInput.isBordered = false
        settingsInput.isBezeled = false
        settingsInput.drawsBackground = false
        settingsInput.focusRingType = .none
        settingsInput.font = .monospacedDigitSystemFont(ofSize: 32, weight: .medium)
        settingsInput.textColor = .labelColor
        settingsInput.placeholderString = "1000.00"
        settingsInput.delegate = self
        settingsInput.setAccessibilityLabel("每周预算，美元")
        settingsInput.setAccessibilityHelp("输入非负金额，最多两位小数")
        settingsInput.translatesAutoresizingMaskIntoConstraints = false
        settingsInput.heightAnchor.constraint(equalToConstant: 43).isActive = true
        let currency = Self.label("USD", size: 10, weight: .semibold, secondary: true)
        currency.setContentHuggingPriority(.required, for: .horizontal)
        let inputRow = row([currency, settingsInput], spacing: 15)
        pin(inputRow, inside: inputCard, inset: 16)
        let form = column([
            inputTitle,
            inputCard,
            inputHint,
        ], spacing: 10)
        settingsStack.addArrangedSubview(form)

        let previewCard = FrostCardView()
        previewValue.textColor = FrostPalette.accent
        let previewContent = column([
            previewTitle,
            previewValue,
            previewHint,
        ], spacing: 7)
        pin(previewContent, inside: previewCard, inset: 16)
        settingsStack.addArrangedSubview(previewCard)
        settingsStack.addArrangedSubview(editorNote)
        settingsError.textColor = .systemOrange
        settingsError.maximumNumberOfLines = 2
        settingsError.lineBreakMode = .byWordWrapping
        settingsError.isHidden = true
        settingsStack.addArrangedSubview(settingsError)

        connect(cancelButton, action: #selector(cancelSettings), help: "取消修改")
        connect(saveButton, action: #selector(saveSettings), help: "保存每周额度")
        saveButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = []
        let footer = row([cancelButton, NSView(), saveButton], spacing: 8)
        settingsStack.addArrangedSubview(footer)
        constrainPageContents(settingsStack)
    }

    private func renderSnapshot() {
        guard let snapshot = currentSnapshot else {
            importLabel.isHidden = false
            return
        }
        setAmount(snapshot.remainingText)
        budgetLabel.stringValue = "每周额度 \(snapshot.budgetText)"
        usedValue.stringValue = snapshot.usedText
        percentageValue.stringValue = snapshot.progressText
        progress.setValue(snapshot.progressValue, description: snapshot.progressText)
        manualButton.isEnabled = !isSaving && snapshot.canAddManualUsage
        importLabel.isHidden = true
        warningLabel.isHidden = snapshot.warningText == nil
        warningLabel.stringValue = snapshot.warningText == nil ? "" : "暂时无法更新，刷新后重试"
        warningLabel.toolTip = snapshot.warningText
        warningLabel.setAccessibilityHelp(snapshot.warningText)
        statusLabel.textColor = .secondaryLabelColor
        switch snapshot.status {
        case .ready:
            statusLabel.stringValue = snapshot.hasManualUsage ? "含手动扣除" : "本机"
            statusLabel.textColor = FrostPalette.accent
        case .partial:
            statusLabel.stringValue = "待补齐"
            statusLabel.textColor = .systemOrange
        case .unavailable:
            statusLabel.stringValue = "暂无用量"
        case .stale:
            statusLabel.stringValue = "待更新"
        case .error:
            statusLabel.stringValue = "无法更新"
            statusLabel.textColor = .systemOrange
        case .bootstrapping:
            statusLabel.stringValue = "读取中"
            importLabel.isHidden = false
            importLabel.stringValue = importProgress(snapshot.statusText)
        }
        if mode == .settings || mode == .manual { updatePreview() }
        updateContentSize()
    }

    private func setAmount(_ text: String) {
        let compact = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
        var size: CGFloat = 52
        while size > 26 {
            let width = (compact as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            ]).width
            if width <= Self.contentWidth { break }
            size -= 2
        }
        let amount = NSMutableAttributedString(string: compact, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        for symbol in ["$", "≤"] {
            let range = (compact as NSString).range(of: symbol)
            if range.location != NSNotFound {
                amount.addAttributes([
                    .font: NSFont.systemFont(ofSize: size * 0.55, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .baselineOffset: size * 0.16,
                ], range: range)
            }
        }
        amountLabel.attributedStringValue = amount
        amountLabel.setAccessibilityLabel("本周剩余 \(text)")
    }

    private func show(_ newMode: Mode, animated: Bool = true) {
        mode = newMode
        summaryStack.isHidden = newMode != .summary
        settingsStack.isHidden = newMode != .settings && newMode != .manual
        saveButton.keyEquivalent = (newMode == .settings || newMode == .manual) ? "\r" : ""
        updateContentSize()
        if animated {
            let incoming = newMode == .summary ? summaryStack : settingsStack
            incoming.wantsLayer = true
            if let layer = incoming.layer,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 0.35
                layer.setValue(5, forKeyPath: "transform.translation.y")
                CATransaction.commit()
                FrostMotion.spring(layer, keyPath: "opacity", to: 1)
                FrostMotion.spring(layer, keyPath: "transform.translation.y", to: 0)
            }
        }
    }

    private func updateContentSize() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.panelWidth, height: ceil(rootStack.fittingSize.height))
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        onContentSizeChange?(size)
    }

    private func updatePreview() {
        let input = settingsInput.stringValue
        if mode == .manual {
            let parsed = try? ManualUsageStore.parseAmountCents(input: input)
            saveButton.isEnabled = !isSaving && parsed != nil && currentSnapshot?.canAddManualUsage == true
            previewValue.stringValue = onPreviewManualUsage?(input) ?? "—"
        } else {
            let parsed = try? BudgetSettingsStore.parseBudgetCents(input: input)
            saveButton.isEnabled = !isSaving && parsed != nil && parsed != currentSnapshot?.budgetCents
            previewValue.stringValue = onPreviewBudget?(input) ?? "—"
        }
        previewValue.font = .monospacedDigitSystemFont(
            ofSize: previewValue.stringValue.count > 16 ? 17 : 23, weight: .medium
        )
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        inputCard.isFocused = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        inputCard.isFocused = false
    }

    func controlTextDidChange(_ notification: Notification) {
        settingsError.isHidden = true
        if !settingsInput.stringValue.isEmpty {
            do {
                if mode == .manual {
                    _ = try ManualUsageStore.parseAmountCents(input: settingsInput.stringValue)
                } else {
                    _ = try BudgetSettingsStore.parseBudgetCents(input: settingsInput.stringValue)
                }
            } catch {
                settingsError.stringValue = mode == .manual
                    ? "请输入大于零的金额，最多两位小数" : "请输入非负金额，最多两位小数"
                settingsError.toolTip = error.localizedDescription
                settingsError.isHidden = false
            }
        }
        updatePreview()
        updateContentSize()
    }

    @objc private func refresh() { onRefresh?() }
    @objc private func quit() { onQuit?() }

    @objc private func openSettings() {
        guard !isSaving else { return }
        editGeneration += 1
        let cents = currentSnapshot?.budgetCents ?? BudgetMath.defaultWeeklyBudgetCents
        settingsInput.stringValue = "\(cents / 100)." + String(format: "%02lld", cents % 100)
        configureEditor(manual: false)
        settingsError.isHidden = true
        show(.settings)
        updatePreview()
        focusInput()
    }

    @objc private func openManualUsage() {
        guard !isSaving, currentSnapshot?.canAddManualUsage == true else { return }
        editGeneration += 1
        settingsInput.stringValue = ""
        configureEditor(manual: true)
        settingsError.isHidden = true
        show(.manual)
        updatePreview()
        focusInput()
    }

    private func configureEditor(manual: Bool) {
        editorTitle.stringValue = manual ? "手动扣除" : "每周额度"
        inputTitle.stringValue = manual ? "其他电脑已用金额" : "每周预算"
        inputHint.stringValue = manual ? "只填写尚未计入的金额，避免重复扣除" : "默认 $1,000.00 / 周"
        previewTitle.stringValue = manual ? "扣除后，本周剩余" : "保存后，本周剩余"
        previewHint.stringValue = manual ? "计入本周已用，不改变每周额度" : "已用金额保持不变"
        editorNote.stringValue = manual ? "仅计入当前周，下周不会重复扣除。" : "额度立即生效，并沿用至后续每周。"
        saveButton.title = manual ? "确认扣除" : "保存额度"
        saveButton.setAccessibilityLabel(manual ? "确认扣除美元金额" : "保存每周额度")
        saveButton.toolTip = manual ? "确认扣除美元金额" : "保存每周额度"
        settingsInput.placeholderString = manual ? "0.00" : "1000.00"
        settingsInput.setAccessibilityLabel(manual ? "扣除金额，美元" : "每周预算，美元")
        settingsInput.setAccessibilityHelp(manual ? "输入大于零的金额，最多两位小数" : "输入非负金额，最多两位小数")
    }

    private func focusInput() {
        view.window?.makeFirstResponder(settingsInput)
        inputCard.isFocused = true
        settingsInput.currentEditor()?.selectedRange = NSRange(
            location: settingsInput.stringValue.utf16.count, length: 0
        )
    }

    @objc private func cancelSettings() {
        guard !isSaving else { return }
        editGeneration += 1
        view.window?.makeFirstResponder(nil)
        inputCard.isFocused = false
        show(.summary)
    }

    @objc private func saveSettings() {
        guard !isSaving, saveButton.isEnabled else { return }
        let save = mode == .manual ? onSaveManualUsage : onSaveBudget
        guard let save else {
            settingsError.stringValue = "设置服务不可用，请重新打开应用"
            settingsError.isHidden = false
            updateContentSize()
            return
        }
        isSaving = true
        let generation = editGeneration
        settingsInput.isEnabled = false
        backButton.isEnabled = false
        cancelButton.isEnabled = false
        saveButton.isEnabled = false
        save(settingsInput.stringValue) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSaving = false
                self.settingsInput.isEnabled = true
                self.backButton.isEnabled = true
                self.cancelButton.isEnabled = true
                self.manualButton.isEnabled = self.currentSnapshot?.canAddManualUsage == true
                guard self.editGeneration == generation else { return }
                switch result {
                case .success:
                    self.show(.summary)
                case .failure(let error):
                    self.settingsError.stringValue = "保存失败：\(error.localizedDescription)"
                    self.settingsError.toolTip = error.localizedDescription
                    self.settingsError.setAccessibilityHelp(error.localizedDescription)
                    self.settingsError.isHidden = false
                    self.updatePreview()
                    self.updateContentSize()
                }
            }
        }
    }

    private func importProgress(_ text: String) -> String {
        guard text.contains(" · ") else { return "正在读取本周用量…" }
        return text.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
            .replacingOccurrences(of: "discovering", with: "发现日志")
            .replacingOccurrences(of: "scanning", with: "读取用量")
            .replacingOccurrences(of: "merging", with: "汇总用量")
            .replacingOccurrences(of: "saving", with: "保存用量")
    }

    private func configurePage(_ stack: NSStackView, spacing: CGFloat) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for child in views {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    private func constrainPageContents(_ stack: NSStackView) {
        for child in stack.arrangedSubviews {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func pin(_ content: NSView, inside card: NSView, inset: CGFloat) {
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
        ])
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func connect(_ button: NSButton, action: Selector, help: String) {
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    private static func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
        secondary: Bool = false, numeric: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = numeric ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}
