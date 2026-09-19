import AppKit
import QuartzCore

/// Text-first dictation panel. It never takes keyboard focus from the target App.
final class DictationHUDController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class Surface: NSView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshColors()
        }
        func refreshColors() {
            wantsLayer = true
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            }
            layer?.cornerRadius = 16
            layer?.borderWidth = 1
        }
    }

    private let panel: NSPanel
    private let brand = NSTextField(labelWithString: "Input-sa")
    private let status = NSTextField(labelWithString: "")
    private let style = NSTextField(labelWithString: "")
    private let characterView = NSImageView()
    private let transcript = NSTextView()
    private let level = NSLevelIndicator()
    private let footer = NSTextField(labelWithString: "放開快捷鍵送出 · Esc 取消")
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    var onCancel: (() -> Void)?

    init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 156),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Input-sa 語音輸入")

        let root = Surface(frame: NSRect(x: 0, y: 0, width: 420, height: 156))
        root.refreshColors()
        panel.contentView = root
        brand.font = .systemFont(ofSize: 14, weight: .semibold)
        brand.frame = NSRect(x: 20, y: 124, width: 80, height: 20)
        root.addSubview(brand)
        style.font = .systemFont(ofSize: 11, weight: .medium)
        style.textColor = .secondaryLabelColor
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        style.frame = NSRect(x: 318, y: 125, width: 80, height: 18)
        root.addSubview(style)

        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 110, y: 125, width: 205, height: 20)
        root.addSubview(status)
        characterView.frame = NSRect(x: 20, y: 46, width: 62, height: 76)
        characterView.imageScaling = .scaleProportionallyUpOrDown
        characterView.wantsLayer = true
        characterView.layer?.magnificationFilter = .nearest
        root.addSubview(characterView)
        let scroll = NSScrollView(frame: NSRect(x: 98, y: 53, width: 302, height: 61))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        transcript.frame = NSRect(x: 0, y: 0, width: 290, height: 61)
        transcript.isEditable = false
        transcript.isSelectable = false
        transcript.drawsBackground = false
        transcript.font = .systemFont(ofSize: 15)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainerInset = NSSize(width: 0, height: 5)
        transcript.setAccessibilityLabel("暫時辨識與整理結果")
        scroll.documentView = transcript
        root.addSubview(scroll)

        level.levelIndicatorStyle = .continuousCapacity
        level.minValue = 0
        level.maxValue = 1
        level.warningValue = 1.1
        level.criticalValue = 1.2
        level.frame = NSRect(x: 20, y: 40, width: 380, height: 4)
        level.fillColor = NSColor.systemOrange.withAlphaComponent(0.7)
        root.addSubview(level)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 20, y: 14, width: 338, height: 17)
        root.addSubview(footer)
        let cancel = NSButton(title: "×", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.setAccessibilityLabel("取消錄音或關閉面板")
        cancel.toolTip = "取消 · Esc"
        cancel.frame = NSRect(x: 374, y: 8, width: 30, height: 28)
        root.addSubview(cancel)
    }

    func show(styleName: String, hasLiveTranscript: Bool, on screen: NSScreen?) {
        let character = HUDCharacter.current
        characterView.image = character.image ?? PixelGuanyinRenderer.shared.listeningFrames(frameIndex: 0)
        characterView.setAccessibilityLabel(character.displayName)
        characterView.layer?.removeAnimation(forKey: "float")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let motion = CABasicAnimation(keyPath: "transform.translation.y")
            motion.fromValue = 0
            motion.toValue = 2
            motion.duration = 1.2
            motion.autoreverses = true
            motion.repeatCount = .infinity
            motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            characterView.layer?.add(motion, forKey: "float")
        }
        style.stringValue = styleName
        style.toolTip = styleName
        style.isHidden = false
        brand.isHidden = false
        status.frame = NSRect(x: 110, y: 125, width: 205, height: 20)
        transcript.string = hasLiveTranscript
            ? "正在聆聽…"
            : "正在聆聽，放開後辨識…"
        transcript.textColor = .tertiaryLabelColor
        footer.stringValue = "放開快捷鍵送出 · Esc 取消"
        startedAt = Date()
        elapsedTimer?.invalidate()
        updateTime()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateTime() }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 48))
        panel.orderFront(nil)
    }

    func setText(_ text: String, provisional: Bool = false) {
        transcript.string = text
        transcript.textColor = .labelColor
        transcript.scrollToEndOfDocument(nil)
        if provisional { footer.stringValue = "暫時字幕 · 放開後辨識全文 · Esc 取消" }
    }

    func setStatus(_ text: String, cancellable: Bool = true) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        status.stringValue = text
        status.toolTip = text
        brand.isHidden = true
        style.isHidden = true
        status.frame = NSRect(x: 20, y: 125, width: 380, height: 20)
        footer.stringValue = cancellable ? "Esc 取消" : "稍後自動收起"
        level.doubleValue = 0
    }

    func setAudioLevel(_ value: Float) { level.doubleValue = Double(max(0, min(1, value))) }

    func hide() {
        characterView.layer?.removeAnimation(forKey: "float")
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        panel.orderOut(nil)
    }

    private func updateTime() {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt ?? Date())))
        status.stringValue = String(format: "● 錄音中 · %02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func cancelPressed() { onCancel?() }
}
