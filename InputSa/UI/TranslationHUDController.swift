import AppKit

/// Translation stays in a non-activating panel so choosing a language cannot
/// change the destination app or its insertion point. The recording pipeline
/// owns stopping, transcribing, translating, and cancellation.
final class TranslationHUDController: NSWindowController {
    enum Phase {
        case recording
        case transcribing
        case awaitingLanguage
        case translating
        case finished
    }

    var onLanguageSelected: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Ends recording only. Translation requires a later language selection.
    var onFinish: (() -> Void)?

    private static let panelSize = NSSize(width: 520, height: 388)
    private var statusLabel = NSTextField(labelWithString: "翻譯錄音中")
    private var statusDot = NSTextField(labelWithString: "●")
    private var instructionLabel = NSTextField(labelWithString: "")
    private var previewText = NSTextView()
    private var previewScroll = NSScrollView()
    private var levelView = TranslationLevelView()
    private var languageButtons: [TranslationHUDButton] = []
    private var finishButton = TranslationHUDButton(title: "結束錄音")
    private var cancelButton = TranslationHUDButton(title: "取消")
    private var phase: Phase = .recording
    private var selectedLanguage: String?

    init() {
        let panel = TranslationHUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Input-sa 語音翻譯")
        super.init(window: panel)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(near cursor: NSRect, on screen: NSScreen?) {
        selectedLanguage = nil
        setPhase(.recording)
        setText("")
        setAudioLevel(0)
        updateSelection()
        guard let panel = window else { return }
        let targetScreen = screen ?? NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: cursor.midX, y: cursor.midY))
        } ?? NSScreen.main
        let visible = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setContentSize(Self.panelSize)
        panel.setFrameOrigin(NSPoint(
            x: max(visible.minX + 12, visible.midX - Self.panelSize.width / 2),
            y: max(visible.minY + 12, min(visible.minY + 54, visible.maxY - Self.panelSize.height - 12))))
        panel.orderFront(nil)
    }

    func setStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.setAccessibilityValue(message)
    }

    /// Called only with actual transcript/result text. No synthetic live captions.
    func setText(_ text: String) {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        previewText.string = isEmpty ? "辨識完成後會顯示文字" : text
        previewText.textColor = isEmpty ? .secondaryLabelColor : .labelColor
        previewText.scrollToBeginningOfDocument(nil)
    }

    func setAudioLevel(_ level: Float) {
        guard phase == .recording else { return }
        levelView.level = level.isFinite ? max(0, min(1, level)) : 0
    }

    func setPhase(_ phase: Phase) {
        self.phase = phase
        languageButtons.forEach { $0.isEnabled = phase == .awaitingLanguage }
        finishButton.isEnabled = phase == .recording
        // Cancellation remains available while a transcription/translation is
        // in flight; the pipeline invalidates that session's eventual result.
        cancelButton.isEnabled = true
        statusDot.textColor = phase == .recording ? .systemRed : .secondaryLabelColor
        levelView.isProcessing = phase != .recording
        if phase != .recording { levelView.level = 0 }

        switch phase {
        case .recording:
            selectedLanguage = nil
            setStatus("翻譯錄音中")
            instructionLabel.stringValue = "再按一下快捷鍵或點「結束錄音」，先顯示原文"
        case .transcribing:
            selectedLanguage = nil
            setStatus("正在辨識原文…")
            instructionLabel.stringValue = "辨識完成後，確認原文再選擇翻譯語言"
        case .awaitingLanguage:
            selectedLanguage = nil
            setStatus("原文已就緒，請選擇語言")
            instructionLabel.stringValue = "確認原文後，點選語言翻譯並送出"
        case .translating:
            setStatus("翻譯中…")
            instructionLabel.stringValue = "正在翻譯，請稍候"
        case .finished:
            setStatus("翻譯完成")
            instructionLabel.stringValue = "翻譯已完成"
        }
        updateSelection()
    }

    func hide() {
        window?.orderOut(nil)
        levelView.level = 0
        // Release transcript contents once the session leaves the screen.
        setText("")
    }

    private func buildContent() {
        let root = TranslationHUDSurface(frame: NSRect(origin: .zero, size: Self.panelSize))
        let title = label("Input-sa", size: 18, weight: .semibold,
                          frame: NSRect(x: 24, y: 343, width: 88, height: 24))
        root.addSubview(title)
        root.addSubview(label("語音翻譯", size: 13, weight: .medium,
                              frame: NSRect(x: 118, y: 346, width: 100, height: 19),
                              color: .secondaryLabelColor))

        levelView.frame = NSRect(x: 410, y: 343, width: 86, height: 22)
        levelView.setAccessibilityElement(false)
        root.addSubview(levelView)
        statusDot.frame = NSRect(x: 25, y: 316, width: 14, height: 18)
        statusDot.font = .systemFont(ofSize: 10)
        statusDot.textColor = .systemRed
        statusDot.setAccessibilityElement(false)
        root.addSubview(statusDot)
        statusLabel.frame = NSRect(x: 43, y: 315, width: 453, height: 20)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("翻譯狀態")
        root.addSubview(statusLabel)

        let previewWell = TranslationHUDSurface(frame: NSRect(x: 24, y: 211, width: 472, height: 88))
        previewWell.isInset = true
        previewWell.cornerRadius = 12
        configurePreview(in: previewWell)
        root.addSubview(previewWell)
        root.addSubview(label("翻譯成", size: 12, weight: .medium,
                              frame: NSRect(x: 24, y: 184, width: 120, height: 18),
                              color: .secondaryLabelColor))

        for (index, language) in TranslationLanguage.targets.enumerated() {
            let button = TranslationHUDButton(title: language.label)
            button.frame = NSRect(x: 24 + CGFloat(index % 4) * 120,
                                  y: 141 - CGFloat(index / 4) * 40,
                                  width: 112, height: 32)
            button.tag = index
            button.target = self
            button.action = #selector(languageClicked(_:))
            button.setAccessibilityLabel("翻譯成\(language.promptName)，\(language.label)")
            button.setAccessibilityHelp("確認原文後，翻譯成\(language.promptName)並送出")
            button.toolTip = "將原文翻譯成\(language.promptName)並送出"
            languageButtons.append(button)
            root.addSubview(button)
        }

        instructionLabel = label("", size: 11, weight: .regular,
                                 frame: NSRect(x: 24, y: 75, width: 472, height: 17),
                                 color: .secondaryLabelColor)
        root.addSubview(instructionLabel)
        cancelButton.frame = NSRect(x: 24, y: 22, width: 72, height: 34)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.setAccessibilityLabel("取消語音翻譯")
        root.addSubview(cancelButton)

        finishButton.frame = NSRect(x: 362, y: 22, width: 134, height: 34)
        finishButton.isPrimary = true
        finishButton.target = self
        finishButton.action = #selector(finishClicked)
        finishButton.setAccessibilityLabel("結束錄音並顯示原文")
        root.addSubview(finishButton)
        window?.contentView = root
        setPhase(.recording)
        setText("")
    }

    private func configurePreview(in well: NSView) {
        let previewWidth: CGFloat = 448
        previewText = NSTextView(frame: NSRect(x: 0, y: 0, width: previewWidth, height: 64))
        previewText.isEditable = false
        previewText.isSelectable = false
        previewText.drawsBackground = false
        previewText.font = .systemFont(ofSize: 15)
        previewText.textContainerInset = NSSize(width: 0, height: 2)
        previewText.textContainer?.lineFragmentPadding = 0
        previewText.textContainer?.widthTracksTextView = true
        previewText.textContainer?.containerSize = NSSize(width: previewWidth, height: .greatestFiniteMagnitude)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.setAccessibilityLabel("辨識與翻譯文字預覽")
        previewScroll.frame = NSRect(x: 12, y: 12, width: previewWidth, height: 64)
        previewScroll.borderType = .noBorder
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.documentView = previewText
        well.addSubview(previewScroll)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       frame: NSRect, color: NSColor = .labelColor) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.frame = frame
        result.font = .systemFont(ofSize: size, weight: weight)
        result.textColor = color
        return result
    }

    private func updateSelection() {
        for (index, button) in languageButtons.enumerated() {
            button.isChosen = TranslationLanguage.targets[index].promptName == selectedLanguage
            button.setAccessibilityValue(button.isChosen ? "已選取" : "未選取")
        }
    }

    @objc private func languageClicked(_ sender: NSButton) {
        guard phase == .awaitingLanguage, TranslationLanguage.targets.indices.contains(sender.tag) else { return }
        let language = TranslationLanguage.targets[sender.tag].promptName
        selectedLanguage = language
        updateSelection()
        onLanguageSelected?(language)
    }

    @objc private func finishClicked() {
        guard phase == .recording else { return }
        onFinish?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

private final class TranslationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum TranslationHUDColors {
    static let surface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.98, blue: 0.965, alpha: 1)
    }
    static let gold = NSColor(srgbRed: 0.93, green: 0.76, blue: 0.38, alpha: 1)
    static let inkOnGold = NSColor(srgbRed: 0.15, green: 0.12, blue: 0.06, alpha: 1)
}

private final class TranslationHUDSurface: NSView {
    var isInset = false
    var cornerRadius: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        (isInset ? NSColor.labelColor.withAlphaComponent(0.045) : TranslationHUDColors.surface).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Draws the whole button itself, keeping its entire rectangle clickable even
/// when the title is short. Native NSButton still handles mouse/accessibility.
private final class TranslationHUDButton: NSButton {
    var isChosen = false { didSet { needsDisplay = true } }
    var isPrimary = false { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 12, weight: .medium)
        focusRingType = .none
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isChosen || isPrimary
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        let fill: NSColor = highlighted ? TranslationHUDColors.gold : .labelColor.withAlphaComponent(0.06)
        fill.withAlphaComponent(highlighted ? opacity : (isEnabled ? 0.06 : 0.035)).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        path.fill()
        if isHighlighted && isEnabled {
            NSColor.black.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        if isChosen {
            TranslationHUDColors.inkOnGold.withAlphaComponent(0.28 * opacity).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let text = isChosen ? "✓ \(title)" : title
        let color = highlighted ? TranslationHUDColors.inkOnGold : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color.withAlphaComponent(opacity),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                          y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class TranslationLevelView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var isProcessing = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (isProcessing ? NSColor.tertiaryLabelColor : TranslationHUDColors.gold).setFill()
        let count = 17
        let stride = bounds.width / CGFloat(count)
        for index in 0..<count {
            let envelope = 0.35 + 0.65 * abs(sin(CGFloat(index) * 0.9))
            let height = 3 + CGFloat(level) * (bounds.height - 3) * envelope
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * stride, y: (bounds.height - height) / 2,
                                            width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
