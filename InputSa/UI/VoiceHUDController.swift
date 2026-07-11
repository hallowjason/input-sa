import AppKit
import QuartzCore

/// Floating voice recording / processing HUD.
/// Liquid-glass panel (NSGlassEffectView .clear) with a pixel-art deity.
/// Each character has a signature animation rooted in its archetype:
///   觀音: notes into ear, nectar sprinkling from the vase (聞聲救苦、淨瓶甘露)
///   彌勒: words absorbed into the belly + happy bounce + 「哈」 bubbles (大肚能容)
///   關公: bamboo-slip characters fly in (夜讀春秋), blade flash + 義 seal on processing
///   耶穌: notes into ear, halo glow pulse (光環)
///   孔子: messy characters in → tidy characters out (述而不作、亂進齊出)
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

    private enum ParticleColor {
        static let gold   = NSColor(red: 0.93, green: 0.76, blue: 0.38, alpha: 1.0)
        static let nectar = NSColor(red: 0.55, green: 0.85, blue: 0.98, alpha: 1.0)
        static let bamboo = NSColor(red: 0.55, green: 0.75, blue: 0.42, alpha: 1.0)
        static let seal   = NSColor(red: 0.82, green: 0.18, blue: 0.14, alpha: 1.0)
    }

    // MARK: - UI
    private var contentRoot:   NSView!
    private var iconView:      NSImageView!
    private var statusLabel:   NSTextField!
    private var emitters:      [CAEmitterLayer] = []
    private var haloPulse:     CALayer?
    private var stampLayer:    CALayer?
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

        window?.contentView = makeGlassContainer(bounds: bounds, content: contentRoot)
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

    // MARK: - Character loading
    private func reloadCharacterIfNeeded() {
        let character = HUDCharacter.current
        guard character != loadedCharacter else { return }
        loadedCharacter = character

        let isLegacyArt: Bool
        if let img = character.image {
            iconView.image = img
            isLegacyArt = Bundle.main.url(forResource: "char_\(character.rawValue)",
                                          withExtension: "png", subdirectory: "hud") == nil
        } else {
            iconView.image = PixelGuanyinRenderer.shared.listeningFrames(frameIndex: 0)
            isLegacyArt = false
        }

        rebuildAnimations(for: character, legacy: isLegacyArt)
    }

    /// The sprite's aspect-fitted rect inside Layout.iconBox.
    private func fittedRect() -> NSRect {
        let box = Layout.iconBox
        guard let img = iconView.image, img.size.width > 0, img.size.height > 0 else { return box }
        let scale = min(box.width / img.size.width, box.height / img.size.height)
        let w = img.size.width * scale, h = img.size.height * scale
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// Converts a sprite-space fraction (x from left, y from bottom) to view coords.
    private func point(_ frac: CGPoint, in rect: NSRect) -> CGPoint {
        CGPoint(x: rect.minX + frac.x * rect.width, y: rect.minY + frac.y * rect.height)
    }

    // MARK: - Per-character animation setup
    private func rebuildAnimations(for character: HUDCharacter, legacy: Bool) {
        guard let rootLayer = contentRoot.layer else { return }
        let wasActive = (emitters.first?.birthRate ?? 0) > 0
        emitters.forEach { $0.removeFromSuperlayer() }
        emitters.removeAll()
        haloPulse?.removeFromSuperlayer(); haloPulse = nil
        stampLayer?.removeFromSuperlayer(); stampLayer = nil
        usesBounce = false

        let fitted = fittedRect()
        let earL = point(legacy ? Layout.legacyEarLeft : character.earLeftFrac, in: fitted)

        switch (legacy ? .guanyin : character) {
        case .guanyin:
            // 聞聲救苦: words drift into the ear; 甘露 sprinkles from the vase in her hands.
            emitters.append(glyphDriftEmitter(
                glyphs: ["♪", "♫", "ㄅ", "ㄨ", "音"], color: ParticleColor.gold,
                to: earL, birthRate: 0.45))
            let vase = point(CGPoint(x: 0.50, y: 0.30), in: fitted)
            emitters.append(nectarFountainEmitter(at: vase))

        case .maitreya:
            // 大肚能容: words get sucked into the belly and vanish; 「哈」 bubbles rise.
            let belly = point(CGPoint(x: 0.50, y: 0.34), in: fitted)
            emitters.append(glyphDriftEmitter(
                glyphs: ["♪", "ㄏ", "ㄚ", "話", "音"], color: ParticleColor.gold,
                to: belly, birthRate: 0.5, shrinkOnArrival: true))
            let headTop = point(CGPoint(x: 0.55, y: 0.95), in: fitted)
            emitters.append(bubbleEmitter(glyph: "哈", color: ParticleColor.gold, at: headTop))
            usesBounce = true

        case .guangong:
            // 夜讀春秋: bamboo-slip characters fly toward him while you speak.
            let face = point(CGPoint(x: 0.45, y: 0.65), in: fitted)
            emitters.append(glyphDriftEmitter(
                glyphs: ["春", "秋", "忠", "義"], color: ParticleColor.bamboo,
                to: face, birthRate: 0.5))
            // Blade flash + 義 seal fire in setState(.processing).

        case .jesus:
            // 話語入耳; halo pulses with steady light. No output particles (per spec).
            emitters.append(glyphDriftEmitter(
                glyphs: ["♪", "♫", "ㄨ", "音"], color: ParticleColor.gold,
                to: earL, birthRate: 0.45))
            let halo = point(CGPoint(x: 0.50, y: 0.93), in: fitted)
            haloPulse = makeHaloPulse(at: halo)

        case .confucius:
            // 亂進齊出: jumbled characters tumble in, tidy ones file out in a line.
            let scroll = point(CGPoint(x: 0.50, y: 0.45), in: fitted)
            emitters.append(messyGlyphEmitter(
                glyphs: ["之", "乎", "者", "也"], color: ParticleColor.gold, to: scroll))
            let exitPoint = point(CGPoint(x: 0.95, y: 0.45), in: fitted)
            emitters.append(tidyGlyphEmitter(
                glyphs: ["仁", "義", "禮", "智", "信"], color: ParticleColor.gold, from: exitPoint))
        }

        emitters.forEach { rootLayer.addSublayer($0) }
        if let halo = haloPulse { rootLayer.addSublayer(halo) }
        if wasActive { setEmittersActive(true) }
    }

    // MARK: - Emitter builders

    /// Characters drift from the left edge toward `target` and fade out on arrival.
    private func glyphDriftEmitter(
        glyphs: [String], color: NSColor, to target: CGPoint,
        birthRate: Float, shrinkOnArrival: Bool = false
    ) -> CAEmitterLayer {
        let e = baseEmitter()
        e.emitterPosition = CGPoint(x: 14, y: target.y)
        let travel = max(target.x - 14, 20)
        let speed: CGFloat = 42
        e.emitterCells = glyphs.map { glyph in
            let c = CAEmitterCell()
            c.contents = Self.glyphImage(glyph, fontSize: 7, color: color)
            c.birthRate = birthRate
            c.lifetime = Float(travel / speed)
            c.velocity = speed
            c.velocityRange = 6
            c.emissionLongitude = 0
            c.emissionRange = 0.1
            c.yAcceleration = 4
            c.scale = 0.9
            c.scaleRange = 0.15
            c.alphaSpeed = -Float(speed / travel)
            if shrinkOnArrival { c.scaleSpeed = -0.45 }   // absorbed = shrinks away
            return c
        }
        return e
    }

    /// Gentle nectar fountain: droplets arc up out of the vase and fall to both sides.
    /// Deliberately sparse (the old dual-emitter mix read as "a blue-yellow blob").
    private func nectarFountainEmitter(at vase: CGPoint) -> CAEmitterLayer {
        let e = baseEmitter()
        e.emitterPosition = vase
        let droplet = CAEmitterCell()
        droplet.contents = Self.dropletImage()
        droplet.birthRate = 7
        droplet.lifetime = 1.3
        droplet.velocity = 40
        droplet.velocityRange = 14
        droplet.emissionLongitude = .pi / 2      // straight up
        droplet.emissionRange = 0.85             // spread into an arc
        droplet.yAcceleration = -85              // fall back down
        droplet.scale = 0.8
        droplet.scaleRange = 0.25
        droplet.alphaSpeed = -0.55
        e.emitterCells = [droplet]
        return e
    }

    /// Occasional single glyphs rising and growing, like bursts of laughter.
    private func bubbleEmitter(glyph: String, color: NSColor, at origin: CGPoint) -> CAEmitterLayer {
        let e = baseEmitter()
        e.emitterPosition = origin
        let c = CAEmitterCell()
        c.contents = Self.glyphImage(glyph, fontSize: 8, color: color)
        c.birthRate = 0.8
        c.lifetime = 1.6
        c.velocity = 17
        c.velocityRange = 4
        c.emissionLongitude = .pi / 2
        c.emissionRange = 0.35
        c.scale = 0.7
        c.scaleSpeed = 0.35     // grows as it rises
        c.alphaSpeed = -0.62
        e.emitterCells = [c]
        return e
    }

    /// Tumbling, spinning, scattered glyphs converging on the scroll.
    private func messyGlyphEmitter(glyphs: [String], color: NSColor, to target: CGPoint) -> CAEmitterLayer {
        let e = baseEmitter()
        e.emitterPosition = CGPoint(x: 14, y: target.y)
        let travel = max(target.x - 14, 20)
        let speed: CGFloat = 40
        e.emitterCells = glyphs.map { glyph in
            let c = CAEmitterCell()
            c.contents = Self.glyphImage(glyph, fontSize: 7, color: color)
            c.birthRate = 0.5
            c.lifetime = Float(travel / speed)
            c.velocity = speed
            c.velocityRange = 14
            c.emissionLongitude = 0
            c.emissionRange = 0.35              // scattered heights = messy
            c.yAcceleration = 8
            c.scale = 0.85
            c.scaleRange = 0.3
            c.spin = 2.2                        // tumbling
            c.spinRange = 2.0
            c.alphaSpeed = -Float(speed / travel)
            return c
        }
        return e
    }

    /// Single-file, upright, evenly spaced glyphs marching out to the right.
    private func tidyGlyphEmitter(glyphs: [String], color: NSColor, from origin: CGPoint) -> CAEmitterLayer {
        let e = baseEmitter()
        e.emitterPosition = origin
        let travel = Layout.size.width - origin.x - 8
        let speed: CGFloat = 30
        e.emitterCells = glyphs.map { glyph in
            let c = CAEmitterCell()
            c.contents = Self.glyphImage(glyph, fontSize: 7, color: color)
            c.birthRate = 0.35
            c.lifetime = Float(travel / speed)
            c.velocity = speed                  // constant speed, no jitter
            c.velocityRange = 0
            c.emissionLongitude = 0
            c.emissionRange = 0                 // dead straight = tidy
            c.scale = 0.9
            c.alphaSpeed = -Float(speed / travel) * 0.9
            return c
        }
        return e
    }

    private func baseEmitter() -> CAEmitterLayer {
        let e = CAEmitterLayer()
        e.frame = contentRoot.bounds
        e.emitterShape = .point
        e.birthRate = 0
        return e
    }

    /// Soft radial gold glow behind the halo, pulsing while recording.
    private func makeHaloPulse(at center: CGPoint) -> CALayer {
        let d: CGFloat = 34
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        glow.colors = [
            ParticleColor.gold.withAlphaComponent(0.75).cgColor,
            ParticleColor.gold.withAlphaComponent(0.0).cgColor,
        ]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint   = CGPoint(x: 1.0, y: 1.0)
        glow.opacity = 0
        return glow
    }

    private func startHaloPulse() {
        guard let halo = haloPulse, halo.animation(forKey: "pulse") == nil else { return }
        halo.opacity = 0.55
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.8; scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7; fade.toValue = 0.18
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.5
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(group, forKey: "pulse")
    }

    private func stopHaloPulse() {
        haloPulse?.removeAnimation(forKey: "pulse")
        haloPulse?.opacity = 0
    }

    // MARK: - Guangong processing effects (blade flash + 義 seal)
    private func runBladeFlashAndSeal() {
        guard let rootLayer = contentRoot.layer else { return }

        // Diagonal light band sweeping across the panel — one quick slash.
        let band = CAGradientLayer()
        band.frame = CGRect(x: 0, y: 0, width: 46, height: Layout.size.height * 1.6)
        band.colors = [
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.85).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint   = CGPoint(x: 1, y: 0.5)
        band.setAffineTransform(CGAffineTransform(rotationAngle: -0.5))
        band.position = CGPoint(x: -40, y: Layout.size.height / 2)
        rootLayer.addSublayer(band)

        CATransaction.begin()
        CATransaction.setCompletionBlock { band.removeFromSuperlayer() }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -40
        sweep.toValue = Layout.size.width + 40
        sweep.duration = 0.32
        sweep.timingFunction = CAMediaTimingFunction(name: .easeIn)
        band.add(sweep, forKey: "sweep")
        band.position = CGPoint(x: Layout.size.width + 40, y: Layout.size.height / 2)
        CATransaction.commit()

        // 義 seal stamps down after the slash.
        guard let sealImg = Self.sealImage() else { return }
        let seal = CALayer()
        let s: CGFloat = 26
        seal.frame = CGRect(x: Layout.size.width - s - 16, y: Layout.size.height - s - 14, width: s, height: s)
        seal.contents = sealImg
        seal.magnificationFilter = .nearest
        seal.opacity = 0
        rootLayer.addSublayer(seal)
        stampLayer = seal

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.8, 0.92, 1.0]
        pop.keyTimes = [0, 0.7, 1]
        pop.duration = 0.28
        pop.beginTime = CACurrentMediaTime() + 0.30
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0; show.toValue = 1
        show.duration = 0.08
        show.beginTime = pop.beginTime
        seal.add(pop, forKey: "pop")
        seal.add(show, forKey: "show")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak seal] in
            seal?.opacity = 1
        }
    }

    // MARK: - Emitter control
    private func setEmittersActive(_ active: Bool) {
        let rate: Float = active ? 1 : 0
        for e in emitters {
            e.birthRate = rate
            if active { e.beginTime = CACurrentMediaTime() }
        }
        if active { startHaloPulse() } else { stopHaloPulse() }
    }

    // MARK: - Particle images (pixel-art style)

    private static func glyphImage(_ glyph: String, fontSize: CGFloat, color: NSColor) -> CGImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: glyph, attributes: attrs)
        var size = str.size()
        size.width = ceil(size.width); size.height = ceil(size.height)
        guard size.width > 0, size.height > 0 else { return nil }
        let img = NSImage(size: size, flipped: false) { _ in
            str.draw(at: .zero)
            return true
        }
        guard let small = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return upscaleNearest(small, factor: 3)
    }

    private static func pixelSprite(_ rows: [String], palette: [Character: NSColor], scale: Int) -> CGImage? {
        let h = rows.count
        let w = rows.map(\.count).max() ?? 0
        guard w > 0, h > 0 else { return nil }
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for (rowIdx, row) in rows.enumerated() {
                for (colIdx, ch) in row.enumerated() {
                    guard let color = palette[ch] else { continue }
                    color.setFill()
                    NSRect(x: colIdx, y: h - 1 - rowIdx, width: 1, height: 1).fill()
                }
            }
            return true
        }
        guard let small = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return upscaleNearest(small, factor: scale)
    }

    private static func upscaleNearest(_ image: CGImage, factor: Int) -> CGImage? {
        let w = image.width * factor, h = image.height * factor
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func dropletImage() -> CGImage? {
        let cyan  = NSColor(red: 0.55, green: 0.85, blue: 0.98, alpha: 1.0)
        let deep  = NSColor(red: 0.30, green: 0.65, blue: 0.92, alpha: 1.0)
        let shine = NSColor.white
        return pixelSprite([
            "..c..",
            ".ccc.",
            "cwccd",
            "ccccd",
            ".cdd.",
        ], palette: ["c": cyan, "d": deep, "w": shine], scale: 3)
    }

    /// Red square seal with 義 — pixel style.
    private static func sealImage() -> CGImage? {
        let size = NSSize(width: 13, height: 13)
        let img = NSImage(size: size, flipped: false) { _ in
            ParticleColor.seal.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 13, height: 13)).fill()
            NSColor(red: 0.96, green: 0.92, blue: 0.86, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 1, y: 1, width: 11, height: 11)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                .foregroundColor: ParticleColor.seal,
            ]
            let str = NSAttributedString(string: "義", attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: (13 - sz.width) / 2, y: (13 - sz.height) / 2))
            return true
        }
        guard let small = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return upscaleNearest(small, factor: 2)
    }

    // MARK: - Show
    func show(state: State, near cursorRect: NSRect, on screen: NSScreen?) {
        guard let win = window else { return }
        reloadCharacterIfNeeded()
        win.setContentSize(Layout.size)
        win.setFrameOrigin(floatingOrigin(size: win.frame.size, below: cursorRect, screen: screen))
        win.orderFront(nil)
        setState(state)
    }

    func setState(_ state: State) {
        switch state {
        case .recording:
            elapsed = 0
            clearStamp()
            startIdleMotion()
            setEmittersActive(true)
            startElapsedTimer()
        case .processing(let message):
            setEmittersActive(false)
            stopElapsedTimer()
            statusLabel.stringValue = message
            if loadedCharacter == .guangong, stampLayer == nil {
                runBladeFlashAndSeal()
            }
        }
    }

    func hide() {
        window?.orderOut(nil)
        stopIdleMotion()
        setEmittersActive(false)
        stopElapsedTimer()
        clearStamp()
        elapsed = 0
    }

    private func clearStamp() {
        stampLayer?.removeFromSuperlayer()
        stampLayer = nil
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
func floatingOrigin(size: CGSize, below cursor: NSRect, screen: NSScreen?) -> NSPoint {
    let sf = (screen ?? NSScreen.main)?.visibleFrame ?? cursor
    var o  = NSPoint(x: cursor.minX, y: cursor.minY - size.height - 8)
    if o.x + size.width > sf.maxX { o.x = sf.maxX - size.width }
    if o.y < sf.minY              { o.y = cursor.maxY + 4 }
    return o
}
