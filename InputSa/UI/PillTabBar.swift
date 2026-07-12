import AppKit

/// Custom hand-drawn tab switcher replacing NSTabView's native tab chrome —
/// a dark capsule track with a solid gold pill marking the active tab, driving
/// a borderless (`.noTabsNoBorder`) NSTabView via `onSelect`.
final class PillTabBar: NSView {
    private let labels: [String]
    private(set) var selectedIndex: Int
    var onSelect: ((Int) -> Void)?

    private var segmentFrames: [NSRect] = []

    private let trackColor = NSColor(calibratedWhite: 0.13, alpha: 1.0)
    private let selectedFill = DesignTokens.accentGold
    private let selectedTextColor = NSColor.black
    private let unselectedTextColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)

    init(labels: [String], selectedIndex: Int = 0) {
        self.labels = labels
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Fixed height, flexible width — avoids the "NSBox custom type has no
    // intrinsic size" trap from the section-card work: this view genuinely
    // HAS a well-defined preferred size, so declaring it here is correct
    // (unlike stretching a container to match unrelated content).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 44)
    }

    func select(_ index: Int) {
        guard index >= 0, index < labels.count, index != selectedIndex else { return }
        selectedIndex = index
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let count = labels.count
        guard count > 0 else { return }
        let padding: CGFloat = 4
        let segWidth = (bounds.width - padding * 2) / CGFloat(count)
        segmentFrames = (0..<count).map { i in
            NSRect(x: padding + CGFloat(i) * segWidth, y: padding,
                   width: segWidth, height: bounds.height - padding * 2)
        }

        for (i, label) in labels.enumerated() {
            let frame = segmentFrames[i]
            let textColor: NSColor
            if i == selectedIndex {
                selectedFill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
                textColor = selectedTextColor
            } else {
                textColor = unselectedTextColor
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: DesignTokens.monoFont(12, weight: .semibold),
                .foregroundColor: textColor,
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            let textRect = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                   width: size.width, height: size.height)
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
