import AppKit
import QuartzCore

/// Floating voice recording / processing HUD.
/// Liquid-glass panel (NSGlassEffectView .clear) with a pixel-art deity.
/// All characters share one idle motion (float, or belly bounce for 彌勒) —
/// per-character particle effects were removed in favor of a live audio
/// waveform that reacts to the user's actual voice while recording.
final class VoiceHUDController: NSWindowController {

    enum State {
        case recording
        case processing(String)   // e.g. "轉錄中…", "翻譯中…"
    }

    // MARK: - Layout constants
    private enum Layout {
        static let size      = CGSize(width: 230, height: 150)
        /// Box the sprite is aspect-fitted into.
        static let iconBox   = NSRect(x: 79, y: 42, width: 72, height: 88)
        static let cornerRadius: CGFloat = 20
        /// Legacy detailed Guanyin artwork (guanyin_hud.png) fallback anchors.
        static let legacyEarLeft  = CGPoint(x: 0.32, y: 0.77)
        static let legacyEarRight = CGPoint(x: 0.68, y: 0.77)
    }

    // MARK: - UI
    private var contentRoot:   NSView!
    private var iconView:      NSImageView!
    private var statusLabel:   NSTextField!
    private var waveform:      WaveformView!
    private var gradientBorder: CAGradientLayer!
    private var elapsedTimer:  Timer?
    private var elapsed       = 0
    private var loadedCharacter: HUDCharacter?
    private var usesBounce    = false   // maitreya: belly bounce instead of float

    private let redDot = "● "
    /// Recording-state caption prefix (before the mm:ss timer). Defaults to
    /// "錄音中"; the 劃詞問答 flow sets "問題錄音中" before showing. Reset on hide.
    var recordingCaption = "錄音中"

    // MARK: - Init
    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup
    private func setupUI() {
        let bounds = NSRect(origin: .zero, size: Layout.size)

        contentRoot = NSView(frame: bounds)
        contentRoot.wantsLayer = true

        iconView = NSImageView(frame: Layout.iconBox)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.magnificationFilter = .nearest
        // Center anchor so squash/bounce animations scale around the middle.
        if let l = iconView.layer {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.position = CGPoint(x: Layout.iconBox.midX, y: Layout.iconBox.midY)
        }
        contentRoot.addSubview(iconView)

        statusLabel = NSTextField(labelWithString: "錄音中 00:00")
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 0, y: 14, width: Layout.size.width, height: 18)
        contentRoot.addSubview(statusLabel)

        let waveformFrame = NSRect(x: 0, y: 32, width: Layout.size.width, height: 10)
        waveform = WaveformView(frame: waveformFrame)
        contentRoot.addSubview(waveform)

        window?.contentView = makeGlassContainer(bounds: bounds, content: contentRoot)
        gradientBorder = makeGradientBorder(bounds: bounds)
        contentRoot.layer?.addSublayer(gradientBorder)
        reloadCharacterIfNeeded()
    }

    /// Liquid-glass container. macOS 26+: NSGlassEffectView with the .clear style —
    /// Apple's actual Liquid Glass material (the .regular default renders as a milky
    /// frosted panel, which was the "white slab" complaint). No hand-drawn sheen
    /// overlays on top: the system material supplies its own refraction highlights.
    private func makeGlassContainer(bounds: NSRect, content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = Layout.cornerRadius
            glass.style = .clear
            glass.contentView = content
            return glass
        }
        let v = NSVisualEffectView(frame: bounds)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = Layout.cornerRadius
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.addSubview(content)
        return v
    }

    // MARK: - Animated gradient border
    /// A conic (angular) gradient masked to a stroke along the panel's rounded-rect
    /// edge, colors continuously "flowing" around the ring. The mask's own geometry
    /// never moves — only `endPoint` is keyframe-animated around the gradient's
    /// center, which rotates the *color mapping* without rotating the gradient
    /// layer's `transform` (rotating `transform` would rotate the whole masked
    /// rounded-rect as a rigid image, visibly misaligning its corners with the
    /// actual glass panel edge since the panel isn't square).
    private func makeGradientBorder(bounds: NSRect) -> CAGradientLayer {
        let lineWidth: CGFloat = 3
        let inset = lineWidth / 2
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: max(Layout.cornerRadius - inset, 0),
            cornerHeight: max(Layout.cornerRadius - inset, 0),
            transform: nil)

        let ringMask = CAShapeLayer()
        ringMask.frame = bounds
        ringMask.path = path
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = lineWidth

        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.type = .conic
        gradient.colors = [
            DesignTokens.accentGold.cgColor,
            NSColor.systemOrange.cgColor,
            NSColor.systemPink.cgColor,
            NSColor.systemPurple.cgColor,
            NSColor.systemTeal.cgColor,
            DesignTokens.accentGold.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradient.mask = ringMask
        gradient.opacity = 0
        return gradient
    }

    private func startGradientFlow() {
        gradientBorder.opacity = 1
        guard gradientBorder.animation(forKey: "flow") == nil else { return }
        let steps = 32
        let anim = CAKeyframeAnimation(keyPath: "endPoint")
        anim.values = (0...steps).map { i -> NSValue in
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            return NSValue(point: CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle)))
        }
        anim.duration = 4.0
        anim.calculationMode = .linear
        anim.repeatCount = .infinity
        gradientBorder.add(anim, forKey: "flow")
    }

    private func stopGradientFlow() {
        gradientBorder.removeAnimation(forKey: "flow")
        gradientBorder.opacity = 0
    }

    // MARK: - Character loading
    private func reloadCharacterIfNeeded() {
        let character = HUDCharacter.current
        guard character != loadedCharacter else { return }
        loadedCharacter = character

        if let img = character.image {
            iconView.image = img
        } else {
            iconView.image = PixelGuanyinRenderer.shared.listeningFrames(frameIndex: 0)
        }

        usesBounce = (character == .maitreya)
    }

    // MARK: - Show
    func show(state: State, near cursorRect: NSRect, on screen: NSScreen?) {
        guard let win = window else { return }
        reloadCharacterIfNeeded()
        win.setContentSize(Layout.size)
        win.setFrameOrigin(fixedBottomCenterOrigin(size: win.frame.size, screen: screen))
        win.orderFront(nil)
        startGradientFlow()
        setState(state)
    }

    func setState(_ state: State) {
        switch state {
        case .recording:
            elapsed = 0
            startIdleMotion()
            waveform.start()
            startElapsedTimer()
        case .processing(let message):
            waveform.stop()
            stopElapsedTimer()
            statusLabel.stringValue = message
        }
    }

    func hide() {
        window?.orderOut(nil)
        confirmPanel?.orderOut(nil)
        stopIdleMotion()
        waveform.stop()
        stopGradientFlow()
        stopElapsedTimer()
        elapsed = 0
        recordingCaption = "錄音中"   // reset so the next dictation isn't mislabeled
    }

    // MARK: - 口頭修正 confirm panel
    //
    // A separate, dynamically-sized panel — the recording HUD's fixed 230×150
    // single-line status label truncated long terms. The key handling (↩ /
    // ⇧↩ / ⎋) lives in InputController's event tap; this panel is purely the
    // visual surface, so it stays a non-activating panel that never steals keys.
    private var confirmPanel: NSPanel?

    /// Show the parsed-entry confirmation, replacing the recording HUD window.
    func showDojoConfirm(correct: String, wrong: String, on screen: NSScreen? = NSScreen.main) {
        window?.orderOut(nil)
        stopIdleMotion(); waveform.stop(); stopGradientFlow(); stopElapsedTimer()
        present(DojoConfirmView(correct: correct, wrong: wrong), on: screen)
    }

    /// Replace the confirm panel with a single centered status line — used for
    /// post-save feedback ("分享中…", "已送出待審核 ✓") without a jarring resize.
    func updateDojoConfirmMessage(_ text: String) {
        guard confirmPanel != nil else { return }
        present(DojoConfirmView(message: text), on: confirmPanel?.screen ?? NSScreen.main)
    }

    private func present(_ view: DojoConfirmView, on screen: NSScreen?) {
        let panel = confirmPanel ?? Self.makeBareConfirmPanel()
        confirmPanel = panel
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.setFrameOrigin(fixedBottomCenterOrigin(size: panel.frame.size, screen: screen))
        panel.orderFront(nil)
    }

    private static func makeBareConfirmPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 320, height: 120)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    /// Feeds the latest microphone amplitude (0...1) into the waveform view.
    /// Called continuously while `voiceService.isRecording` is true.
    func updateAudioLevel(_ level: Float) {
        waveform.updateLevel(level)
    }

    // MARK: - Idle motion (float, or belly bounce for maitreya)
    private func startIdleMotion() {
        guard let layer = iconView.layer else { return }
        if usesBounce {
            guard layer.animation(forKey: "bounce") == nil else { return }
            let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
            sy.values = [1.0, 0.93, 1.04, 1.0]
            sy.keyTimes = [0, 0.4, 0.75, 1]
            let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
            sx.values = [1.0, 1.06, 0.98, 1.0]
            sx.keyTimes = [0, 0.4, 0.75, 1]
            let group = CAAnimationGroup()
            group.animations = [sy, sx]
            group.duration = 0.85
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: "bounce")
        } else {
            guard layer.animation(forKey: "float") == nil else { return }
            let anim = CABasicAnimation(keyPath: "transform.translation.y")
            anim.fromValue = 0
            anim.toValue = 3
            anim.duration = 1.2
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "float")
        }
    }

    private func stopIdleMotion() {
        iconView?.layer?.removeAnimation(forKey: "float")
        iconView?.layer?.removeAnimation(forKey: "bounce")
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsed += 1
            let m = self.elapsed / 60, s = self.elapsed % 60
            self.statusLabel.stringValue = self.redDot
                + String(format: "\(self.recordingCaption) %02d:%02d", m, s)
        }
        statusLabel.stringValue = redDot + "\(recordingCaption) 00:00"
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
    }
}

// MARK: - Shared floating-window positioning

/// Cursor-relative placement, used by the select-and-polish preview popup
/// (it needs to appear right where the user was looking, not at a fixed spot).
func floatingOrigin(size: CGSize, below cursor: NSRect, screen: NSScreen?) -> NSPoint {
    let sf = (screen ?? NSScreen.main)?.visibleFrame ?? cursor
    var o  = NSPoint(x: cursor.minX, y: cursor.minY - size.height - 8)
    if o.x + size.width > sf.maxX { o.x = sf.maxX - size.width }
    if o.y < sf.minY              { o.y = cursor.maxY + 4 }
    return o
}

/// Fixed bottom-center placement (Typeless-style), used by the voice
/// recording HUD — always appears in the same spot regardless of where the
/// text cursor happens to be.
func fixedBottomCenterOrigin(size: CGSize, screen: NSScreen?) -> NSPoint {
    let sf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: size)
    let bottomMargin: CGFloat = 48
    let x = sf.midX - size.width / 2
    let y = sf.minY + bottomMargin
    return NSPoint(x: x, y: y)
}

// MARK: - 口頭修正 confirm surface

/// Dynamically-sized confirmation view: multi-line term display + an action
/// legend, or (via `init(message:)`) a single centered status line. Wrapping
/// labels have their max width capped so long terms wrap instead of truncating.
/// The rounded CALayer background re-resolves on light/dark change, matching
/// CardRowView's technique.
private final class DojoConfirmView: NSView {
    private static let corner: CGFloat = 18
    private static let maxWidth: CGFloat = 360

    private static let sideInset: CGFloat = 20

    /// Full confirm layout (term + action legend).
    init(correct: String, wrong: String) {
        super.init(frame: .zero)
        let (stack, legendWidth) = Self.buildConfirmStack(correct: correct, wrong: wrong)
        // Card must be at least as wide as the action legend, or the legend's
        // last pill ("⎋ 取消") overflows the card's right edge when a short term
        // label alone sets the width. ("標頭列多顆控制項要算總寬".) Capped at
        // maxWidth — the legend is measured to comfortably fit under it.
        commonInit(content: stack, minWidth: legendWidth + 2 * Self.sideInset)
    }

    /// Single-line status message (post-save feedback).
    init(message: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: message)
        label.font = DesignTokens.monoFont(13, weight: .bold)
        label.textColor = .labelColor
        label.alignment = .center
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 16, right: 22)
        commonInit(content: stack, minWidth: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func commonInit(content: NSStackView, minWidth: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = Self.corner
        layer?.borderWidth = 1
        updateColors()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Pin content to all four edges — the view's height/width follow the
        // content's intrinsic size (same pattern as DesignTokens.makeSectionCard).
        var cs: [NSLayoutConstraint] = [
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
        ]
        if minWidth > 0 {
            cs.append(widthAnchor.constraint(
                greaterThanOrEqualToConstant: min(minWidth, Self.maxWidth)))
        }
        NSLayoutConstraint.activate(cs)
        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        content.setContentHuggingPriority(.required, for: .vertical)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: Content builders

    /// Returns the assembled stack plus the action legend's measured width —
    /// the legend's intrinsic width does not reliably propagate through the
    /// outer stack (BadgePill sizes via internal constraints), so the caller
    /// enforces it as the card's minimum width instead.
    private static func buildConfirmStack(correct: String, wrong: String) -> (NSStackView, CGFloat) {
        let title = NSTextField(labelWithString: "加入道場詞庫？")
        title.font = DesignTokens.monoFont(13, weight: .bold)
        title.textColor = .secondaryLabelColor

        var rows: [NSView] = [
            title,
            infoRow(caption: "正確詞", value: correct, valueColor: DesignTokens.accentGold),
        ]
        if !wrong.isEmpty && wrong != correct {
            rows.append(infoRow(caption: "常見誤辨", value: wrong, valueColor: .labelColor))
        }
        let legend = actionLegend()
        rows.append(legend)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return (stack, legend.fittingSize.width)
    }

    private static func infoRow(caption: String, value: String, valueColor: NSColor) -> NSView {
        let cap = NSTextField(labelWithString: caption)
        cap.font = DesignTokens.monoFont(11, weight: .bold)
        cap.textColor = .secondaryLabelColor
        cap.setContentHuggingPriority(.required, for: .horizontal)
        cap.setContentCompressionResistancePriority(.required, for: .horizontal)

        let val = NSTextField(wrappingLabelWithString: value)
        val.font = DesignTokens.monoFont(15, weight: .bold)
        val.textColor = valueColor
        val.preferredMaxLayoutWidth = maxWidth - 90

        let row = NSStackView(views: [cap, val])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private static func actionLegend() -> NSView {
        func item(_ key: String, _ text: String, fill: NSColor, keyColor: NSColor) -> NSStackView {
            let pill = BadgePill(text: key, fill: fill, textColor: keyColor, fontSize: 10, height: 20)
            let lbl = NSTextField(labelWithString: text)
            lbl.font = DesignTokens.monoFont(11, weight: .medium)
            lbl.textColor = .labelColor
            let s = NSStackView(views: [pill, lbl])
            s.orientation = .horizontal
            s.spacing = 5
            s.alignment = .centerY
            return s
        }
        let row = NSStackView(views: [
            item("↩", "加入", fill: DesignTokens.accentGold, keyColor: .black),
            item("⇧↩", "加入並分享", fill: NSColor.systemTeal, keyColor: .white),
            item("⎋", "取消", fill: NSColor.systemGray, keyColor: .white),
        ])
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY

        // Small top gap separating the legend from the info rows.
        let wrap = NSStackView(views: [row])
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        return wrap
    }
}
