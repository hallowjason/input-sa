import AppKit

/// Custom hand-drawn segmented control — a soft ink-tinted capsule track with
/// a solid ink pill marking the active option (the reference sheet's black
/// "VISA" register: selection is always ink, never a hue). Used for the
/// transcription-provider and polish-provider pickers.
final class PillSegmentedControl: NSView {
    private let labels: [String]
    private(set) var selectedIndex: Int
    var onSelect: ((Int) -> Void)?

    private var segmentFrames: [NSRect] = []

    init(labels: [String], selectedIndex: Int = 0) {
        self.labels = labels
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 38)
    }

    func select(_ index: Int) {
        guard index >= 0, index < labels.count, index != selectedIndex else { return }
        selectedIndex = index
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds
        DesignTokens.Palette.ink.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let count = labels.count
        guard count > 0 else { return }
        let padding: CGFloat = 3
        let segWidth = (bounds.width - padding * 2) / CGFloat(count)
        segmentFrames = (0..<count).map { i in
            NSRect(x: padding + CGFloat(i) * segWidth, y: padding,
                   width: segWidth, height: bounds.height - padding * 2)
        }

        for (i, label) in labels.enumerated() {
            let frame = segmentFrames[i]
            let textColor: NSColor
            if i == selectedIndex {
                DesignTokens.Palette.ink.setFill()
                NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
                textColor = DesignTokens.Palette.inkInverse
            } else {
                textColor = DesignTokens.Palette.inkMuted(0.6)
            }
            var font = DesignTokens.uiFont(12, weight: .semibold)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            var str = NSAttributedString(string: label, attributes: attrs)
            var size = str.size()
            let maxWidth = frame.width - 10
            // Long labels ("Google STT（含台語）") can overflow a narrow segment —
            // step the font down rather than clipping or wrapping mid-word.
            if size.width > maxWidth {
                font = DesignTokens.uiFont(10, weight: .semibold)
                attrs[.font] = font
                str = NSAttributedString(string: label, attributes: attrs)
                size = str.size()
            }
            let textRect = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                   width: min(size.width, maxWidth), height: size.height)
            str.draw(in: textRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = segmentFrames.firstIndex(where: { $0.contains(point) }) else { return }
        select(idx)
        onSelect?(idx)
    }
}
