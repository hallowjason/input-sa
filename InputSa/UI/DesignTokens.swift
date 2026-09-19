import AppKit

/// Shared soft-material palette. Surface depth and spacing establish hierarchy;
/// restrained gold keeps Input-sa's identity without competing with the text.
enum DesignTokens {
    /// Warm gold for the established Guanyin HUD's particles and waveform.
    static let accentGold = NSColor(red: 0.93, green: 0.76, blue: 0.38, alpha: 1.0)

    // MARK: - Colour primitives

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                alpha: a)
    }

    /// A colour that resolves light/dark per the current appearance — used for
    /// CALayer fills (read `.cgColor` inside `performAsCurrentDrawingAppearance`).
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    // MARK: - Appearance-aware soft material

    enum Palette {
        /// Window canvas behind the grouped cards.
        static let canvas = dynamic(rgb(0xed, 0xee, 0xf1), rgb(0x29, 0x2c, 0x32))
        /// Grouped card surface.
        static let card = canvas
        static let pressed = dynamic(rgb(0xe2, 0xe4, 0xe8), rgb(0x24, 0x27, 0x2d))
        static let lightEdge = dynamic(rgb(0xff, 0xff, 0xff, 0.88), rgb(0x4d, 0x51, 0x5c, 0.50))
        static let softShadow = dynamic(rgb(0x9e, 0xa3, 0xae, 0.42), rgb(0x0c, 0x0e, 0x12, 0.65))
        /// Primary text and solid monochrome fills.
        static let ink    = dynamic(rgb(0x2b, 0x2e, 0x34), rgb(0xeb, 0xec, 0xef))
        /// Text on ink fills (filled badges, InkPillButton).
        static let inkInverse = dynamic(.white, rgb(0x1d, 0x1d, 0x1f))

        static func inkMuted(_ alpha: CGFloat = 0.55) -> NSColor { ink.withAlphaComponent(alpha) }

        /// Row/card hairline separator.
        static let sep = dynamic(rgb(0x6b, 0x71, 0x7d, 0.12), rgb(0xc2, 0xc6, 0xd2, 0.10))
        /// Alias kept for HairlineView call sites.
        static var hairline: NSColor { sep }
        /// Recessed monochrome well — key caps, emoji tiles, soft badges.
        static let well = dynamic(rgb(0xd8, 0xdc, 0xe3, 0.6), rgb(0x15, 0x18, 0x1e, 0.50))

        /// THE accent. Interactive elements only: selected sidebar item,
        /// text buttons, links. Never for emphasis or decoration.
        static let accent = dynamic(rgb(0x8b, 0x71, 0x3e), rgb(0xd3, 0xb8, 0x79))
        /// Inline text links (slightly darker for text-level readability;
        /// brighter on dark backgrounds).
        static let link = dynamic(rgb(0x59, 0x5e, 0x69), rgb(0xc7, 0xca, 0xd2))
        /// Destructive text buttons (刪除) — semantic red, Apple HIG.
        static let destructive = dynamic(rgb(0xd7, 0x00, 0x15), rgb(0xff, 0x69, 0x61))

        // Semantic status colours (dots and transient feedback only).
        static let statusOK   = dynamic(rgb(0x24, 0x8a, 0x3d), rgb(0x32, 0xd7, 0x4b))
        static let statusWarn = dynamic(rgb(0xc9, 0x51, 0x00), rgb(0xff, 0x9f, 0x0a))
    }

    // MARK: - Geometry

    static let windowSize = NSSize(width: 700, height: 820)
    static let sidebarWidth: CGFloat = 0
    static let preferencesHeaderHeight: CGFloat = 156
    static let cardCornerRadius: CGFloat = 20
    /// Horizontal padding of a content pane.
    static let contentPadding: CGFloat = 32
    /// Full-width content column below the settings header.
    /// Single source of truth for every card/footnote width pin.
    static let contentWidth: CGFloat = 660 - 2 * 32

    enum Spacing {
        static let section: CGFloat = 28   // between sibling groups in a pane
        static let item: CGFloat = 10      // between stacked controls
        static let compact: CGFloat = 6    // between tightly related controls
        static let field: CGFloat = 4      // between a field and its inline caption
        static let card: CGFloat = 14      // sheets: between grouped blocks
    }

    enum Grid {
        static let labelColumnWidth: CGFloat = 120
        static let fieldColumnWidth: CGFloat = 280
    }

    // MARK: - Typography
    // SF Pro (+ PingFang TC for CJK) with subtle negative tracking at every
    // size — apple.com tracks tight universally. Mono survives ONLY for
    // hardware-flavoured strings: API keys and the editor sheets' fields.

    static func uiFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Single-line label with precise kerning.
    static func styledLabel(_ text: String, size: CGFloat, weight: NSFont.Weight,
                            kern: CGFloat = 0, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: uiFont(size, weight: weight),
            .kern: kern,
            .foregroundColor: color,
        ])
        return label
    }

    /// Pane heading — "語音服務" at the top of a content pane.
    static func paneTitle(_ text: String) -> NSTextField {
        styledLabel(text, size: 20, weight: .semibold, kern: -0.25, color: Palette.ink)
    }

    /// Group heading above a card — 13 pt semibold ink, sentence case.
    static func sectionLabel(_ text: String) -> NSTextField {
        styledLabel(text, size: 13, weight: .semibold, kern: 0, color: Palette.ink)
    }

    /// Wrapping footnote under a card. 11 pt muted ink.
    static func caption(_ text: String, width: CGFloat = contentWidth - 8) -> NSTextField {
        let label = WrappingTextField(text)
        label.font = uiFont(12)
        label.textColor = Palette.inkMuted(0.70)
        label.preferredMaxLayoutWidth = width
        label.isSelectable = false
        return label
    }

    /// 1-pt separator (rows inside a card, or standalone).
    static func hairline() -> NSView {
        let line = HairlineView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: - Grouped rows (the System Settings register)

    /// One card row: 13 pt title (plus optional 11 pt subtitle) left,
    /// control right. Min height 44, side insets 16.
    static func row(title: String, subtitle: String? = nil, control: NSView? = nil) -> NSView {
        let titleLabel = WrappingTextField(title)
        titleLabel.font = uiFont(13)
        titleLabel.textColor = Palette.ink
        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if let subtitle, !subtitle.isEmpty {
            let sub = WrappingTextField(subtitle)
            sub.font = uiFont(11)
            sub.textColor = Palette.inkMuted(0.70)
            textStack.addArrangedSubview(sub)
        }
        for label in textStack.arrangedSubviews {
            label.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [textStack]
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return row
    }

    /// Status row: caption left; green/orange dot + value right.
    /// Returns the labels so change handlers can restyle text in place.
    static func statusRow(caption: String, value: String, dot: NSColor)
        -> (row: NSView, captionLabel: NSTextField, valueLabel: NSTextField,
            dotView: StatusDotView) {
        let captionLabel = WrappingTextField(caption)
        captionLabel.font = uiFont(13)
        captionLabel.textColor = Palette.ink
        let valueLabel = WrappingTextField(value)
        valueLabel.font = uiFont(12, weight: .medium)
        valueLabel.textColor = Palette.ink
        valueLabel.alignment = .right
        let dotView = StatusDotView(color: dot)
        let row = NSStackView(views: [captionLabel, dotView, valueLabel])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(12, after: captionLabel)
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        valueLabel.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.55).isActive = true
        return (row, captionLabel, valueLabel, dotView)
    }

    /// White grouped card stacking `rows` with hairline separators between.
    /// Every row is pinned to the card's width, so rows can hide/show
    /// (NSStackView collapses hidden arranged views) without leaving gaps.
    ///
    /// `autoSeparators: false` hands separator placement to the caller —
    /// needed when some rows are conditional: a hidden row's auto-inserted
    /// neighbour hairline would stay behind as a stray double line, so such
    /// rows carry their own leading hairline inside their wrapper instead.
    static func groupCard(_ rows: [NSView], autoSeparators: Bool = true) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (i, rowView) in rows.enumerated() {
            if autoSeparators && i > 0 { stack.addArrangedSubview(hairline()) }
            stack.addArrangedSubview(rowView)
        }
        let card = GroupCardView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        card.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentHuggingPriority(.required, for: .vertical)
        return card
    }

    /// One pane group: optional 13-pt heading, the card, optional footnote.
    /// The card is pinned to the group's width; the caller pins the group to
    /// the pane's content column.
    static func group(title: String? = nil, card: NSView,
                      footnote: NSTextField? = nil) -> NSView {
        var views: [NSView] = []
        if let title { views.append(sectionLabel(title)) }
        views.append(card)
        if let footnote { views.append(footnote) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: - Controls

    /// Native macOS popup — the System Settings selector for 2+ choices.
    static func popup(items: [String], selectedIndex: Int,
                      target: AnyObject?, action: Selector) -> NSPopUpButton {
        let popup = SoftPopUpButton()
        popup.addItems(withTitles: items)
        if (0..<items.count).contains(selectedIndex) { popup.selectItem(at: selectedIndex) }
        popup.target = target
        popup.action = action
        popup.font = uiFont(12)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    /// Native button behavior with a raised material capsule.
    static func pushButton(title: String, target: AnyObject?, action: Selector) -> NSButton {
        let btn = SoftPillButton(title: title)
        btn.target = target
        btn.action = action
        return btn
    }

    /// Accent text button — card-footer actions (＋ 新增詞條, 用說的新增).
    static func textButton(title: String, symbol: String? = nil,
                           target: AnyObject?, action: Selector) -> AccentTextButton {
        AccentTextButton(title: title, symbol: symbol, destructive: false,
                         target: target, action: action)
    }

    /// Key-cap chip for the shortcut overview (右 ⌥, ⌃, P…).
    static func keycap(_ text: String) -> BadgePill {
        BadgePill(text: text, fill: Palette.well, textColor: Palette.inkMuted(0.65),
                  fontSize: 11, height: 22, mono: false, cornerRadius: 5,
                  borderColor: Palette.sep, hPad: 14, fontWeight: .medium)
    }

    /// Monochrome list badge. Hierarchy by fill depth, never by hue.
    enum BadgeStyle { case filled, soft, outline }

    static func badge(_ text: String, style: BadgeStyle) -> BadgePill {
        switch style {
        case .filled:
            return BadgePill(text: text, fill: Palette.ink, textColor: Palette.inkInverse,
                             fontSize: 10, height: 20)
        case .soft:
            return BadgePill(text: text, fill: Palette.well,
                             textColor: Palette.inkMuted(0.6), fontSize: 10, height: 20,
                             fontWeight: .medium)
        case .outline:
            return BadgePill(text: text, fill: .clear, textColor: Palette.inkMuted(0.6),
                             fontSize: 10, height: 20, borderColor: Palette.sep,
                             fontWeight: .medium)
        }
    }

    // MARK: - Legacy factories (editor sheets only — do not use in panes)

    /// Solid ink pill — the sheets' 儲存 button.
    static func inkButton(title: String, symbol: String? = nil,
                          target: AnyObject?, action: Selector) -> InkPillButton {
        InkPillButton(title: title, symbol: symbol, style: .solidInk,
                      target: target, action: action)
    }

    /// Soft pill — ink at 8% with ink text.
    static func softButton(title: String, symbol: String? = nil,
                           target: AnyObject?, action: Selector) -> InkPillButton {
        InkPillButton(title: title, symbol: symbol, style: .soft,
                      target: target, action: action)
    }

    /// Label/field `NSGridView` with the shared column widths (editor sheets).
    static func makeFieldGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Spacing.field
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Grid.labelColumnWidth
        if grid.numberOfColumns > 1 {
            grid.column(at: 1).width = Grid.fieldColumnWidth
        }
        // Without this, a vertical NSStackView with slack space can stretch the
        // grid's rows unevenly instead of leaving it at natural fitting height.
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.setContentCompressionResistancePriority(.required, for: .vertical)
        return grid
    }
}

/// Same-material card with enough internal margin for the soft relief edge.
final class GroupCardView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        SoftMaterial.draw(in: bounds.insetBy(dx: 4, dy: 4), radius: DesignTokens.cardCornerRadius)
    }
}

/// Coordinate-flipped container so stacked content grows downward inside an
/// NSScrollView (non-flipped documents anchor to the bottom).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 1-pt divider that re-resolves its tint on appearance changes.
final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyColor()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }
    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignTokens.Palette.hairline.cgColor
        }
    }
}

/// 8-pt status dot; colour swaps via `setColor` (semantic state changes).
final class StatusDotView: NSView {
    private var color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setColor(_ c: NSColor) { color = c; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Soft action capsule. `setTitle` re-titles
/// without losing the styling — the dojo voice-add button relies on that.
final class AccentTextButton: NSButton {
    private let symbol: String?
    private let color: NSColor
    private var titleText: String

    init(title: String, symbol: String?, destructive: Bool,
         target: AnyObject?, action: Selector) {
        self.symbol = symbol
        self.color = destructive ? DesignTokens.Palette.destructive
                                 : DesignTokens.Palette.link
        self.titleText = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        applyTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ newTitle: String) {
        titleText = newTitle
        applyTitle()
        invalidateIntrinsicContentSize()
    }

    private func applyTitle() {
        setAccessibilityLabel(titleText)
        let text = NSMutableAttributedString()
        if let symbol,
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            let attach = NSTextAttachment()
            attach.image = NSImage.tinted(img, color: color)
            attach.bounds = NSRect(x: 0, y: -1.5, width: img.size.width, height: img.size.height)
            text.append(NSAttributedString(attachment: attach))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: titleText, attributes: [
            .font: DesignTokens.uiFont(12, weight: .medium),
            .foregroundColor: color,
            .kern: -0.15,
        ]))
        attributedTitle = text
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 22, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        SoftMaterial.draw(in: bounds.insetBy(dx: 3, dy: 3), radius: 13, pressed: isHighlighted)
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitle()
    }
}

extension NSImage {
    /// Tint a template-ish image by baking colour into a copy — template
    /// rendering inside attributed strings is unreliable pre-macOS 14.
    static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let img = NSImage(size: image.size)
        img.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        rect.fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

/// Pill button in the sheets' two registers: solid ink (primary) or soft
/// ink-8% (secondary). Draws itself, so fills stay appearance-correct, and
/// `setTitle` re-titles without losing the styling.
final class InkPillButton: NSButton {
    enum Style { case solidInk, soft }
    private let style: Style
    private let symbol: String?
    private var titleText: String

    init(title: String, symbol: String?, style: Style, target: AnyObject?, action: Selector) {
        self.style = style
        self.symbol = symbol
        self.titleText = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        applyTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ newTitle: String) {
        titleText = newTitle
        applyTitle()
        invalidateIntrinsicContentSize()
    }

    private func applyTitle() {
        let fg: NSColor = style == .solidInk
            ? DesignTokens.Palette.inkInverse
            : DesignTokens.Palette.ink
        let text = NSMutableAttributedString()
        if let symbol,
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) {
            let attach = NSTextAttachment()
            attach.image = NSImage.tinted(img, color: fg)
            attach.bounds = NSRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
            text.append(NSAttributedString(attachment: attach))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: titleText, attributes: [
            .font: DesignTokens.uiFont(12, weight: .bold),
            .foregroundColor: fg,
            .kern: 0.2,
        ]))
        attributedTitle = text
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 30   // pill side padding
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = style == .solidInk
            ? DesignTokens.Palette.ink
            : DesignTokens.Palette.ink.withAlphaComponent(0.08)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitle()
        needsDisplay = true
    }
}
