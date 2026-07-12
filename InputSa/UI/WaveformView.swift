import AppKit

/// Pixel-art scrolling amplitude meter for the voice HUD.
///
/// We only ever have one aggregate mic level per tick (AudioLevelMeter reads
/// AVAudioRecorder.averagePower, not per-frequency-band data), so a literal
/// waveform shape isn't available. Instead this renders what we actually
/// have honestly: a short scrolling history of recent levels as blocky
/// LED-style bars — newest reading on the right, older readings scroll left.
///
/// Drawing technique matches the rest of the HUD's pixel art: build a tiny
/// low-res bitmap (columns × rows), then nearest-neighbor upscale so edges
/// stay crisp and blocky instead of blurring.
final class WaveformView: NSView {
    private let columns = 18
    private let maxRows = 5
    private let scale = 3

    private var history: [Float]
    private let imageView: NSImageView
    private var isActive = false

    private static let litColor = NSColor(red: 0.93, green: 0.76, blue: 0.38, alpha: 1.0)
    private static let dimColor = NSColor(red: 0.93, green: 0.76, blue: 0.38, alpha: 0.16)

    override init(frame frameRect: NSRect) {
        history = Array(repeating: 0, count: columns)
        imageView = NSImageView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        addSubview(imageView)
        alphaValue = 0
        redraw()
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        isActive = true
        history = Array(repeating: 0, count: columns)
        redraw()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func stop() {
        isActive = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }
    }

    /// `level` is a normalized 0...1 mic amplitude, pushed ~30×/sec while recording.
    func updateLevel(_ level: Float) {
        guard isActive else { return }
        history.removeFirst()
        history.append(max(0, min(1, level)))
        redraw()
    }

    private func redraw() {
        let w = columns, h = maxRows
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for (col, level) in self.history.enumerated() {
                let filledRows = Int((level * Float(h)).rounded())
                for row in 0..<h {
                    // Rows are bottom-up (row 0 = bottom); NSImage draws top-down,
                    // so flip when placing the rect.
                    let y = row
                    let isLit = row < filledRows
                    (isLit ? Self.litColor : Self.dimColor).setFill()
                    NSRect(x: col, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        guard let small = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let upscaled = Self.upscaleNearest(small, factor: scale) else { return }
        imageView.image = NSImage(cgImage: upscaled, size: NSSize(width: w * scale, height: h * scale))
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
}
