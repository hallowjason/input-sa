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
        stopIdleMotion()
        waveform.stop()
        stopGradientFlow()
        stopElapsedTimer()
        elapsed = 0
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
            self.statusLabel.stringValue = self.redDot + String(format: "錄音中 %02d:%02d", m, s)
        }
        statusLabel.stringValue = redDot + "錄音中 00:00"
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
