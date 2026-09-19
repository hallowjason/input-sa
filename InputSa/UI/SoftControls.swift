import AppKit

/// A label whose natural height follows the width allocated by Auto Layout.
/// Plain wrappingLabel's preferred width otherwise stays at its creation value
/// when a preferences window or a row's trailing control changes size.
final class WrappingTextField: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        preferredMaxLayoutWidth = 480
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        if bounds.width > 0, abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}

/// Retains NSPopUpButton's menu and keyboard behavior while sharing the material.
final class SoftPopUpButton: NSPopUpButton {
    init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let textFont = font ?? DesignTokens.uiFont(12)
        let titleWidth = itemTitles.map { ($0 as NSString).size(withAttributes: [.font: textFont]).width }.max() ?? 0
        return NSSize(width: ceil(titleWidth) + 54, height: 36)
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            SoftMaterial.draw(in: bounds.insetBy(dx: 4, dy: 4), radius: 14, pressed: isHighlighted)
            let color = DesignTokens.Palette.ink.withAlphaComponent(isEnabled ? 1 : 0.45)
            let text = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [
                .font: font ?? DesignTokens.uiFont(12), .foregroundColor: color,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: 18, y: (bounds.height - size.height) / 2))
            let arrow = NSBezierPath()
            let x = bounds.width - 22
            let y = bounds.midY
            arrow.move(to: NSPoint(x: x - 3, y: y - 2))
            arrow.line(to: NSPoint(x: x, y: y - 5))
            arrow.line(to: NSPoint(x: x + 3, y: y - 2))
            arrow.move(to: NSPoint(x: x - 3, y: y + 2))
            arrow.line(to: NSPoint(x: x, y: y + 5))
            arrow.line(to: NSPoint(x: x + 3, y: y + 2))
            arrow.lineWidth = 1.4
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            color.setStroke()
            arrow.stroke()
            SoftMaterial.drawFocusRing(for: self, radius: 14)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Input-sa's own AppKit material: a shared surface, with light from the upper
/// left. Native buttons retain keyboard activation and accessibility semantics.
enum SoftMaterial {
    static func drawFocusRing(for view: NSView, radius: CGFloat) {
        guard view.window?.firstResponder === view else { return }
        NSGraphicsContext.saveGraphicsState()
        NSFocusRingPlacement.only.set()
        NSBezierPath(roundedRect: view.bounds.insetBy(dx: 4, dy: 4), xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    static func draw(in rect: NSRect, radius: CGFloat, pressed: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if !pressed {
            for (color, offset) in [
                (DesignTokens.Palette.lightEdge, NSSize(width: -2, height: 2)),
                (DesignTokens.Palette.softShadow, NSSize(width: 2, height: -2)),
            ] {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = color
                shadow.shadowOffset = offset
                shadow.shadowBlurRadius = 4
                shadow.set()
                DesignTokens.Palette.card.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        (pressed ? DesignTokens.Palette.pressed : DesignTokens.Palette.card).setFill()
        path.fill()
        (pressed ? DesignTokens.Palette.sep : DesignTokens.Palette.lightEdge).setStroke()
        path.lineWidth = 0.7
        path.stroke()
    }
}

class SoftPillButton: NSButton {
    var selected = false { didSet { state = selected ? .on : .off; restyle() } }
    var onPress: (() -> Void)?

    init(title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self
        action = #selector(pressed)
        font = DesignTokens.uiFont(12, weight: .medium)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            imagePosition = .imageLeft
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        setAccessibilityLabel(title)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: DesignTokens.uiFont(12, weight: .semibold)]).width
        return NSSize(width: ceil(width) + (image == nil ? 0 : 20) + 34, height: 36)
    }
    private func restyle() {
        let color = selected ? NSColor.labelColor : DesignTokens.Palette.inkMuted(0.78)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DesignTokens.uiFont(12, weight: selected ? .semibold : .medium),
            .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.45),
        ])
        contentTintColor = color
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            SoftMaterial.draw(in: bounds.insetBy(dx: 4, dy: 4), radius: 16,
                              pressed: selected || isHighlighted)
            let baseColor = selected ? NSColor.labelColor : DesignTokens.Palette.inkMuted(0.78)
            let color = isEnabled ? baseColor : baseColor.withAlphaComponent(0.45)
            let text = NSAttributedString(string: title, attributes: [
                .font: DesignTokens.uiFont(12, weight: selected ? .semibold : .medium),
                .foregroundColor: color,
            ])
            let textSize = text.size()
            let imageSpace: CGFloat = image == nil ? 0 : 20
            let x = (bounds.width - textSize.width - imageSpace) / 2
            if let image {
                let icon = NSImage.tinted(image, color: color)
                let scale = min(14 / max(image.size.width, 1), 14 / max(image.size.height, 1))
                let iconSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                icon.draw(in: NSRect(x: x + (14 - iconSize.width) / 2,
                                    y: bounds.midY - iconSize.height / 2,
                                    width: iconSize.width, height: iconSize.height),
                          from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            }
            text.draw(at: NSPoint(x: x + imageSpace, y: (bounds.height - textSize.height) / 2))
            SoftMaterial.drawFocusRing(for: self, radius: 16)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
    @objc private func pressed() { onPress?() }
}

final class SoftSegmentedPicker: NSView {
    private var buttons: [SoftPillButton] = []
    private(set) var selectedIndex: Int
    var onSelect: ((Int) -> Void)?

    init(labels: [String], selectedIndex: Int = 0) {
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buttons = labels.enumerated().map { index, title in
            let button = SoftPillButton(title: title)
            button.onPress = { [weak self] in self?.select(index); self?.onSelect?(index) }
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        select(selectedIndex)
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        for (i, button) in buttons.enumerated() { button.selected = i == index }
    }
    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.Palette.well.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class SoftChoiceGrid: NSView {
    struct Option {
        let title: String
        let detail: String
    }
    private var buttons: [ChoiceButton] = []
    var onSelect: ((Int) -> Void)?

    init(options: [Option], selectedIndex: Int = 0, columns: Int = 2) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buttons = options.enumerated().map { index, option in
            let button = ChoiceButton(option: option)
            button.onPress = { [weak self] in self?.select(index); self?.onSelect?(index) }
            return button
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for start in stride(from: 0, to: buttons.count, by: max(1, columns)) {
            let end = min(start + max(1, columns), buttons.count)
            let row = NSStackView(views: Array(buttons[start..<end]))
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        select(selectedIndex)
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(_ index: Int) {
        for (i, button) in buttons.enumerated() { button.selected = i == index }
    }
}

private final class ChoiceButton: NSButton {
    let option: SoftChoiceGrid.Option
    private let titleLabel: WrappingTextField
    private let detailLabel: WrappingTextField
    var selected = false {
        didSet {
            state = selected ? .on : .off
            titleLabel.font = DesignTokens.uiFont(13, weight: selected ? .semibold : .medium)
            needsDisplay = true
        }
    }
    var onPress: (() -> Void)?
    init(option: SoftChoiceGrid.Option) {
        self.option = option
        titleLabel = WrappingTextField(option.title)
        detailLabel = WrappingTextField(option.detail)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.uiFont(13, weight: .medium)
        titleLabel.textColor = DesignTokens.Palette.ink
        detailLabel.font = DesignTokens.uiFont(11)
        detailLabel.textColor = DesignTokens.Palette.inkMuted(0.72)
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 46),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -17),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
        setAccessibilityLabel(option.title)
        setAccessibilityHelp(option.detail)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Static wrapping labels are decorative children of this native button.
        super.hitTest(point) == nil ? nil : self
    }
    override func draw(_ dirtyRect: NSRect) {
        SoftMaterial.draw(in: bounds.insetBy(dx: 4, dy: 4), radius: 17,
                          pressed: selected || isHighlighted)
        let circle = NSRect(x: 19, y: bounds.midY - 8, width: 16, height: 16)
        // Resolve explicitly: attributed controls can leave a different current
        // drawing appearance active, making a dynamic dark-mode mark disappear.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let mark = isDark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.17, alpha: 1)
        mark.withAlphaComponent(selected ? 1 : 0.40).setStroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = selected ? 1.8 : 1.2
        ring.stroke()
        if selected {
            mark.setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: 4, dy: 4)).fill()
        }
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 17, yRadius: 17).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    @objc private func pressed() { onPress?() }
}
