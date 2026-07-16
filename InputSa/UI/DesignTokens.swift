import AppKit

/// Shared visual constants for the Preferences window (plus the handful of
/// legacy names the voice HUD and editor sheets depend on).
///
/// Design system (2026-07-16 redesign v3, "Apple"):
/// the layout skeleton is macOS System Settings — a sidebar plus grouped
/// white-card rows — and the visual discipline is apple.com's: a neutral
/// #f5f5f7 canvas, near-black ink, hairline separators, and exactly ONE
/// chromatic accent (Apple Blue #0071e3) reserved for interactive elements.
/// Status dots (green/orange) are semantic state colours, not decoration;
/// everything else is monochrome. No gradients, no borders except hairlines,
/// no colour-coded badges — hierarchy comes from fill depth, not hue.
enum DesignTokens {
    /// Warm gold accent — the HUD's particle/waveform colour. Preferences no
    /// longer uses it anywhere; kept solely for VoiceHUDController.
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

    // MARK: - Palette (apple.com discipline, System Settings surfaces)

    enum Palette {
        /// Window canvas behind the grouped cards.
        static let canvas = dynamic(rgb(0xf5, 0xf5, 0xf7), rgb(0x1d, 0x1d, 0x20))
        /// Grouped card surface.
        static let card   = dynamic(.white, rgb(0x29, 0x29, 0x2c))
        /// Primary text and solid monochrome fills.
        static let ink    = dynamic(rgb(0x1d, 0x1d, 0x1f), rgb(0xf5, 0xf5, 0xf7))
        /// Text on ink fills (filled badges, InkPillButton).
        static let inkInverse = dynamic(.white, rgb(0x1d, 0x1d, 0x1f))

        static func inkMuted(_ alpha: CGFloat = 0.55) -> NSColor { ink.withAlphaComponent(alpha) }

        /// Row/card hairline separator.
        static let sep = dynamic(rgb(0, 0, 0, 0.08), rgb(0xff, 0xff, 0xff, 0.09))
        /// Alias kept for HairlineView call sites.
        static var hairline: NSColor { sep }
        /// Recessed monochrome well — key caps, emoji tiles, soft badges.
        static let well = dynamic(rgb(0, 0, 0, 0.05), rgb(0xff, 0xff, 0xff, 0.09))

        /// THE accent. Interactive elements only: selected sidebar item,
        /// text buttons, links. Never for emphasis or decoration.
        static let accent = rgb(0x00, 0x71, 0xe3)
        /// Inline text links (slightly darker for text-level readability;
        /// brighter on dark backgrounds).
        static let link = dynamic(rgb(0x00, 0x66, 0xcc), rgb(0x29, 0x97, 0xff))
        /// Destructive text buttons (刪除) — semantic red, Apple HIG.
        static let destructive = dynamic(rgb(0xd7, 0x00, 0x15), rgb(0xff, 0x69, 0x61))

        // Semantic status colours (dots and transient feedback only).
        static let statusOK   = dynamic(rgb(0x24, 0x8a, 0x3d), rgb(0x32, 0xd7, 0x4b))
        static let statusWarn = dynamic(rgb(0xc9, 0x51, 0x00), rgb(0xff, 0x9f, 0x0a))
    }

    // MARK: - Geometry

    static let windowSize = NSSize(width: 780, height: 560)
    static let sidebarWidth: CGFloat = 210
    static let cardCornerRadius: CGFloat = 10
    /// Horizontal padding of a content pane.
    static let contentPadding: CGFloat = 28
    /// Content column width inside a pane (window − sidebar − 2 × padding).
    /// Single source of truth for every card/footnote width pin.
    static let contentWidth: CGFloat = 780 - 210 - 2 * 28

    enum Spacing {
        static let section: CGFloat = 22   // between sibling groups in a pane
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
        styledLabel(text, size: 22, weight: .semibold, kern: -0.35, color: Palette.ink)
    }

    /// Group heading above a card — 13 pt semibold ink, sentence case.
    static func sectionLabel(_ text: String) -> NSTextField {
        styledLabel(text, size: 13, weight: .semibold, kern: -0.2, color: Palette.ink)
    }

    /// Wrapping footnote under a card. 11 pt muted ink.
    static func caption(_ text: String, width: CGFloat = contentWidth - 8) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = uiFont(11)
        label.textColor = Palette.inkMuted(0.55)
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
        let titleLabel = styledLabel(title, size: 13, weight: .regular, kern: -0.2,
                                     color: Palette.ink)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if let subtitle, !subtitle.isEmpty {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.font = uiFont(11)
            sub.textColor = Palette.inkMuted(0.55)
            sub.preferredMaxLayoutWidth = 330
            sub.isSelectable = false
            textStack.addArrangedSubview(sub)
        }
        var views: [NSView] = [textStack]
        if let control {
            views.append(NSView())   // spring pushes the control to the trailing edge
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    /// Status row: caption left; green/orange dot + value right.
    /// Returns the labels so change handlers can restyle text in place.
    static func statusRow(caption: String, value: String, dot: NSColor)
        -> (row: NSView, captionLabel: NSTextField, valueLabel: NSTextField,
            dotView: StatusDotView) {
        let captionLabel = styledLabel(caption, size: 13, weight: .regular, kern: -0.2,
                                       color: Palette.ink)
        let valueLabel = styledLabel(value, size: 12, weight: .medium, kern: -0.15,
                                     color: Palette.ink)
        let dotView = StatusDotView(color: dot)
        let row = NSStackView(views: [captionLabel, NSView(), dotView, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(12, after: captionLabel)
        row.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
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
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
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
        stack.spacing = 7
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: - Controls

    /// Native macOS popup — the System Settings selector for 2+ choices.
    static func popup(items: [String], selectedIndex: Int,
                      target: AnyObject?, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: items)
        if (0..<items.count).contains(selectedIndex) { popup.selectItem(at: selectedIndex) }
        popup.target = target
        popup.action = action
        popup.font = uiFont(12)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    /// Native push button (清除 etc.) — the stock rounded bezel IS the look.
    static func pushButton(title: String, target: AnyObject?, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: target, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = uiFont(12)
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

/// Grouped-card surface: card fill, 10-pt radius, hairline edge. Layer colours
/// re-resolve on appearance changes (CALayer fills don't auto-track).
final class GroupCardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = DesignTokens.cardCornerRadius
        layer?.borderWidth = 1
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignTokens.Palette.card.cgColor
            layer?.borderColor = DesignTokens.Palette.sep.cgColor
        }
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

/// Borderless accent-text button (blue link register). `setTitle` re-titles
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
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        applyTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ newTitle: String) {
        titleText = newTitle
        applyTitle()
        invalidateIntrinsicContentSize()
    }

    private func applyTitle() {
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
