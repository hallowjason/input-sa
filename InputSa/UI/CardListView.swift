import AppKit

/// Card-style list replacing NSTableView for the Custom-AI-Modes and Dojo-Vocabulary
/// tabs — one rounded card per entry (icon circle / title / badge pills), the
/// "transaction list" pattern from the reference visual language, instead of a
/// native header-and-gridlines table.
///
/// Interaction: hovering a card crossfades its badge pills into 編輯/刪除 pill
/// buttons *in the same spot* — an alpha swap, deliberately not isHidden toggling,
/// so nothing reflows under the cursor.
final class CardListView: NSView {

    struct Row {
        let iconText: String        // single char or emoji drawn in the leading circle
        let iconFill: NSColor       // circle fill behind iconText
        let title: NSAttributedString
        let subtitle: String        // secondary line under the title; "" hides it
        let badges: [(text: String, fill: NSColor, textColor: NSColor)]
    }

    var onEdit: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    /// Shown centered when reload([]) — tell the user where "add" lives.
    var emptyStateText: String = "尚無項目"

    private let scroll = NSScrollView()
    private let stack = FlippedStackContainer()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private let listHeight: CGFloat

    init(height: CGFloat) {
        self.listHeight = height
        super.init(frame: .zero)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        emptyLabel.font = DesignTokens.monoFont(11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: listHeight),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Document width follows the scroll viewport so cards never scroll sideways.
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
            let card = CardRowView(row: row)
            card.onEdit = { [weak self] in self?.onEdit?(idx) }
            card.onDelete = { [weak self] in self?.onDelete?(idx) }
            stack.arrangedStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.arrangedStack.widthAnchor).isActive = true
        }
    }
}

/// NSScrollView documents anchor to the *bottom* for non-flipped views — this
/// wrapper flips coordinates so the card stack grows downward from the top,
/// and forwards its arranged list through `arrangedStack`.
private final class FlippedStackContainer: NSView {
    let arrangedStack = NSStackView()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        arrangedStack.orientation = .vertical
        arrangedStack.spacing = 8
        arrangedStack.alignment = .leading
        arrangedStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
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

/// One rounded entry card. Fixed height; hover crossfades badges ↔ action buttons.
private final class CardRowView: NSView {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private let badgeStack = NSStackView()
    private let actionStack = NSStackView()
    private var tracking: NSTrackingArea?

    private static let rowHeight: CGFloat = 52

    init(row: CardListView.Row) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        updateCardColors()

        // Leading icon circle — initial-letter avatar per the placeholder philosophy.
        let icon = IconCircle(text: row.iconText, fill: row.iconFill)

        // Attributed values override the field's own lineBreakMode — bake the
        // truncation into a paragraph style or the label wraps to two lines
        // inside the fixed-height card.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let titleText = NSMutableAttributedString(attributedString: row.title)
        titleText.addAttribute(.paragraphStyle, value: truncating,
                               range: NSRange(location: 0, length: titleText.length))
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.attributedStringValue = titleText
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if !row.subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: row.subtitle)
            subtitleLabel.font = DesignTokens.monoFont(10)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.maximumNumberOfLines = 1
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }

        badgeStack.orientation = .horizontal
        badgeStack.spacing = 5
        for badge in row.badges {
            badgeStack.addArrangedSubview(BadgePill(text: badge.text, fill: badge.fill, textColor: badge.textColor))
        }

        let editBtn = makeActionButton(title: "編輯", fill: DesignTokens.accentGold, textColor: .black,
                                       action: #selector(editTapped))
        let delBtn = makeActionButton(title: "刪除", fill: NSColor.systemRed.withAlphaComponent(0.85),
                                      textColor: .white, action: #selector(deleteTapped))
        actionStack.orientation = .horizontal
        actionStack.spacing = 5
        actionStack.addArrangedSubview(editBtn)
        actionStack.addArrangedSubview(delBtn)
        actionStack.alphaValue = 0

        let content = NSStackView(views: [icon, textStack, NSView(), badgeStack])
        content.orientation = .horizontal
        content.spacing = 10
        content.alignment = .centerY
        content.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Actions float over the badges' spot (same trailing edge) for the alpha crossfade.
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Layer colors don't auto-track appearance changes the way NSColor-backed
    /// drawing does — resolve them under the current effectiveAppearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCardColors()
    }

    private func updateCardColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func makeActionButton(title: String, fill: NSColor, textColor: NSColor,
                                  action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = fill.cgColor
        btn.layer?.cornerRadius = 11
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DesignTokens.monoFont(10, weight: .bold),
            .foregroundColor: textColor,
        ])
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        return btn
    }

    @objc private func editTapped() { onEdit?() }
    @objc private func deleteTapped() { onDelete?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ hovering: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            badgeStack.animator().alphaValue = hovering ? 0 : 1
            actionStack.animator().alphaValue = hovering ? 1 : 0
        }
    }
}

/// Solid-fill circle with a single centered character — the initial-letter
/// avatar used as each card's leading icon.
private final class IconCircle: NSView {
    private let text: String
    private let fill: NSColor
    private static let diameter: CGFloat = 32

    init(text: String, fill: NSColor) {
        self.text = text
        self.fill = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = str.size()
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// Small solid pill label — tier / phonetic markers on a card's trailing edge,
/// also reused as the key-cap glyphs in the shortcut overview (internal, not
/// private, for exactly that reuse).
final class BadgePill: NSView {
    private let text: String
    private let fill: NSColor
    private let textColor: NSColor
    private let font: NSFont
    private let pillHeight: CGFloat

    init(text: String, fill: NSColor, textColor: NSColor,
         fontSize: CGFloat = 9, height: CGFloat = 20) {
        self.text = text
        self.fill = fill
        self.textColor = textColor
        self.font = DesignTokens.monoFont(fontSize, weight: .bold)
        self.pillHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let size = NSAttributedString(string: text, attributes: [.font: font]).size()
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width + 16),
            heightAnchor.constraint(equalToConstant: pillHeight),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let str = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let size = str.size()
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
