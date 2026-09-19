import AppKit

/// Bounded list for modes and vocabulary. Editable rows always expose native
/// edit/delete buttons; shared rows retain their read-only badge. Wrapping rows
/// hug their content up to maxHeight, then scroll inside the material card.
final class CardListView: NSView {

    struct Row {
        /// Single char or emoji drawn in a leading rounded tile; nil = no tile
        /// (the dojo list is text-first, the modes list keeps its emoji).
        var icon: String? = nil
        let title: NSAttributedString
        let subtitle: String        // secondary line under the title; "" hides it
        let badges: [(text: String, style: DesignTokens.BadgeStyle)]
        /// Read-only rows (e.g. community-synced shared entries) show no 編輯/刪除
        /// buttons and keep their badges permanently visible — no hover crossfade.
        var isReadOnly: Bool = false
    }

    var onEdit: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    /// Shown centered when reload([]) — tell the user where "add" lives.
    var emptyStateText: String = "尚無項目"

    private let scroll = NSScrollView()
    private let stack = FlippedStackContainer()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let maxHeight: CGFloat
    private var heightConstraint: NSLayoutConstraint!

    private static let rowHeight: CGFloat = 56
    private static let emptyHeight: CGFloat = 64

    init(maxHeight: CGFloat) {
        self.maxHeight = maxHeight
        super.init(frame: .zero)

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        emptyLabel.font = DesignTokens.uiFont(11)
        emptyLabel.textColor = DesignTokens.Palette.inkMuted(0.4)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(emptyLabel)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.emptyHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Document width follows the scroll viewport so rows never scroll sideways.
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(rows: [Row]) {
        stack.arrangedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.stringValue = rows.isEmpty ? emptyStateText : ""
        emptyLabel.isHidden = !rows.isEmpty
        for (idx, row) in rows.enumerated() {
            if idx > 0 {
                let sep = DesignTokens.hairline()
                stack.arrangedStack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.arrangedStack.widthAnchor).isActive = true
            }
            let rowView = EntryRowView(row: row)
            rowView.onEdit = { [weak self] in self?.onEdit?(idx) }
            rowView.onDelete = { [weak self] in self?.onDelete?(idx) }
            stack.arrangedStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stack.arrangedStack.widthAnchor).isActive = true
        }
        // Hug the content, cap at maxHeight (then scroll).
        let contentHeight = rows.isEmpty
            ? Self.emptyHeight
            : CGFloat(rows.count) * Self.rowHeight + CGFloat(max(0, rows.count - 1))
        heightConstraint.constant = min(contentHeight, maxHeight)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !stack.arrangedStack.arrangedSubviews.isEmpty, bounds.width > 0 else { return }
        stack.layoutSubtreeIfNeeded()
        let height = min(max(Self.rowHeight, ceil(stack.fittingSize.height)), maxHeight)
        if abs(heightConstraint.constant - height) > 0.5 {
            heightConstraint.constant = height
        }
    }
}

/// NSScrollView documents anchor to the *bottom* for non-flipped views — this
/// wrapper flips coordinates so the row stack grows downward from the top,
/// and forwards its arranged list through `arrangedStack`.
private final class FlippedStackContainer: NSView {
    let arrangedStack = NSStackView()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        arrangedStack.orientation = .vertical
        arrangedStack.spacing = 0
        arrangedStack.alignment = .leading
        arrangedStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrangedStack)
        NSLayoutConstraint.activate([
            arrangedStack.topAnchor.constraint(equalTo: topAnchor),
            arrangedStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            arrangedStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            arrangedStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One list row with subtle hover and persistent, keyboard-accessible actions.
private final class EntryRowView: NSView {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private let badgeStack = NSStackView()
    private let actionStack = NSStackView()
    private var tracking: NSTrackingArea?
    private var isReadOnly = false
    private var hovering = false

    private static let rowHeight: CGFloat = 56

    init(row: CardListView.Row) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        isReadOnly = row.isReadOnly

        var leading: [NSView] = []
        if let icon = row.icon {
            leading.append(WellTile(text: icon))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let titleText = NSMutableAttributedString(attributedString: row.title)
        titleText.addAttribute(.paragraphStyle, value: paragraph,
                               range: NSRange(location: 0, length: titleText.length))
        let titleLabel = WrappingTextField("")
        titleLabel.attributedStringValue = titleText

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if !row.subtitle.isEmpty {
            let subtitleLabel = WrappingTextField(row.subtitle)
            subtitleLabel.font = DesignTokens.uiFont(11)
            subtitleLabel.textColor = DesignTokens.Palette.inkMuted(0.68)
            textStack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeStack.orientation = .horizontal
        badgeStack.spacing = 5
        for badge in row.badges {
            badgeStack.addArrangedSubview(DesignTokens.badge(badge.text, style: badge.style))
        }

        // Read-only rows (shared entries) have no edit/delete actions; the badge
        // stack simply stays visible (no hover crossfade set up below).
        if !row.isReadOnly {
            let editBtn = AccentTextButton(title: "編輯", symbol: nil, destructive: false,
                                           target: self, action: #selector(editTapped))
            let delBtn = AccentTextButton(title: "刪除", symbol: nil, destructive: true,
                                          target: self, action: #selector(deleteTapped))
            actionStack.orientation = .horizontal
            actionStack.spacing = 2
            actionStack.addArrangedSubview(editBtn)
            actionStack.addArrangedSubview(delBtn)
        }

        var trailing: [NSView] = []
        if !row.badges.isEmpty { trailing.append(badgeStack) }
        if !row.isReadOnly { trailing.append(actionStack) }
        for view in trailing {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let content = NSStackView(views: leading + [textStack] + trailing)
        content.orientation = .horizontal
        content.distribution = .fill
        content.spacing = 11
        content.alignment = .centerY
        content.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Layer colors don't auto-track appearance changes — resolve under the
    /// current effectiveAppearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering && !isReadOnly
                ? DesignTokens.Palette.well.cgColor
                : NSColor.clear.cgColor
        }
    }

    @objc private func editTapped() { onEdit?() }
    @objc private func deleteTapped() { onDelete?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t); tracking = nil }
        // Read-only rows have no hover interaction — badges stay visible.
        guard !isReadOnly else { return }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ h: Bool) {
        hovering = h
        applyBackground()
    }
}

/// 28-pt rounded well tile with a single centered character/emoji — the
/// modes list's leading icon (monochrome chrome, the glyph supplies any hue).
private final class WellTile: NSView {
    private let text: String
    private static let side: CGFloat = 28

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.Palette.well.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: DesignTokens.Palette.ink,
        ])
        let size = str.size()
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// Small solid pill/chip label — monochrome badges on a row's trailing edge,
/// also the key-cap chips in the shortcut overview (internal, not private,
/// for exactly that reuse). Defaults preserve the HUD's original pill call
/// (`fill`/`textColor`/`fontSize`/`height`/`mono`); the newer parameters add
/// square-ish corners, hairline borders and lighter weights for the
/// Preferences chips.
final class BadgePill: NSView {
    private let text: String
    private let fill: NSColor
    private let textColor: NSColor
    private let font: NSFont
    private let pillHeight: CGFloat
    private let cornerRadius: CGFloat?
    private let borderColor: NSColor?

    init(text: String, fill: NSColor, textColor: NSColor,
         fontSize: CGFloat = 10, height: CGFloat = 21, mono: Bool = false,
         cornerRadius: CGFloat? = nil, borderColor: NSColor? = nil,
         hPad: CGFloat = 18, fontWeight: NSFont.Weight = .bold) {
        self.text = text
        self.fill = fill
        self.textColor = textColor
        self.font = mono ? DesignTokens.monoFont(fontSize, weight: fontWeight)
                         : DesignTokens.uiFont(fontSize, weight: fontWeight)
        self.pillHeight = height
        self.cornerRadius = cornerRadius
        self.borderColor = borderColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let size = NSAttributedString(string: text, attributes: [.font: font]).size()
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width + hPad),
            heightAnchor.constraint(equalToConstant: pillHeight),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = cornerRadius ?? bounds.height / 2
        let path = NSBezierPath(roundedRect: borderColor == nil
                                    ? bounds : bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let borderColor {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let str = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let size = str.size()
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
