import AppKit

/// Shared visual constants so the Preferences window and the voice HUD read
/// as one product instead of two unrelated AppKit surfaces. Preferences
/// previously had no shared style source — every box/spacing value was a
/// magic number picked ad hoc per tab.
enum DesignTokens {
    /// Warm gold accent — matches the HUD's particle/waveform color, reused
    /// here so Preferences doesn't feel visually disconnected from the HUD.
    static let accentGold = NSColor(red: 0.93, green: 0.76, blue: 0.38, alpha: 1.0)

    static let panelCornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 18
    static let calloutHeight: CGFloat = 44

    enum Spacing {
        static let section: CGFloat = 16   // outer edge insets
        static let item: CGFloat = 10       // between stacked controls
        static let compact: CGFloat = 6     // between tightly related controls (buttons in a row)
        static let field: CGFloat = 4        // between a field and its inline caption
        static let card: CGFloat = 14        // between section cards, and inside a card's edges
    }

    /// Fixed label-column width shared by every `NSGridView` field row across
    /// all four Preferences tabs — without this, each grid auto-sizes its
    /// label column to its own longest string, so field inputs in different
    /// tabs start at different X positions even though they look like the
    /// same kind of row. Wide enough for "翻譯目標語言" / "HUD 神佛角色".
    enum Grid {
        static let labelColumnWidth: CGFloat = 120
        static let fieldColumnWidth: CGFloat = 280
    }

    /// System monospace font — the "hardware device" reference look uses a
    /// dot-matrix/monospace face throughout. SF Mono ships with macOS, so
    /// this needs no bundled font file.
    static func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Builds the tinted callout box used at the top of the API Keys and Voice
    /// tabs (e.g. "目前使用: Groq Whisper", "長按右 ⌥ 說話"). Centralizing this
    /// avoids each call site re-deriving fillColor/borderColor/cornerRadius by hand.
    static func makeCalloutBox(text: String, tint: NSColor) -> (box: NSBox, label: NSTextField) {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = panelCornerRadius
        box.borderWidth = 1
        box.fillColor = tint.withAlphaComponent(0.08)
        box.borderColor = tint.withAlphaComponent(0.3)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monoFont(12, weight: .medium)
        label.textColor = tint
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 440

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        box.contentView = stack

        // NSBox (boxType: .custom) has no intrinsic content size to hug — without an
        // explicit height it stretches arbitrarily in a vertical NSStackView with
        // slack space (see prior in-file note this replaces, in two call sites).
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: calloutHeight).isActive = true

        return (box, label)
    }

    /// A solid-fill badge — the "TODAY" / "EXERCISE" style flat color-block
    /// label from the reference visual language, used for the active-provider
    /// status line instead of a soft 8%-tint callout. Height is *not* fixed:
    /// this text is a full sentence (unlike the reference's short captions),
    /// so a locked `calloutHeight` clipped two-line text outside the pill
    /// shape when it wrapped ("API" rendered below the box entirely) — same
    /// class of bug as the section-card sizing issue, same fix (pin content
    /// to the box with constraints instead of guessing a fixed height).
    static func makeSolidBadge(text: String, fill: NSColor) -> (box: NSBox, label: NSTextField) {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = panelCornerRadius + 4
        box.borderWidth = 0
        box.fillColor = fill

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monoFont(12, weight: .bold)
        label.textColor = .white
        label.isSelectable = false
        // Deliberately wider than the box's own explicit width constraint (see
        // makeAPIKeysTab's 456pt card width) — the box's real constraint should
        // be what decides wrapping, not this guess. Set too tight here once
        // already (420) and the text wrapped one word early ("API" orphaned
        // outside the pill) even though the box itself rendered plenty wide.
        label.preferredMaxLayoutWidth = 500

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        box.contentView = stack

        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentHuggingPriority(.required, for: .vertical)

        return (box, label)
    }

    /// A solid-fill pill button — replaces the system `.rounded` bezel look for
    /// primary actions ("儲存設定"). `NSButton` with `isBordered = false` draws
    /// no chrome of its own, so the gold fill + rounding is applied via layer.
    static func makeSolidButton(title: String, target: AnyObject?, action: Selector,
                                fill: NSColor = accentGold,
                                textColor: NSColor = .black) -> NSButton {
        let btn = NSButton(title: title, target: target, action: action)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = fill.cgColor
        btn.layer?.cornerRadius = 17
        btn.attributedTitle = solidButtonTitle(title, textColor: textColor)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return btn
    }

    /// Re-title a solid button without losing its pill styling (plain `title =`
    /// resets the attributed string and drops the custom font/color).
    static func solidButtonTitle(_ title: String, textColor: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: monoFont(12, weight: .bold),
            .foregroundColor: textColor,
        ])
    }

    /// A titled, flat-bordered section card — the container used to visually
    /// separate distinct service groups (e.g. "語音轉錄服務" vs "AI 潤飾服務")
    /// instead of a single thin `NSBox.separator` line between them. Deliberately
    /// flat/matte (system control-background fill, hairline border), not glass —
    /// this is the "hardware settings panel" register, distinct from the HUD's
    /// liquid-glass "living assistant" register by design.
    static func makeSectionCard(title: String) -> (box: NSBox, contentStack: NSStackView) {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = cardCornerRadius
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = monoFont(11, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor

        let contentStack = NSStackView(views: [titleLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Spacing.item
        contentStack.edgeInsets = NSEdgeInsets(
            top: Spacing.card, left: Spacing.card, bottom: Spacing.card, right: Spacing.card)

        box.contentView = contentStack
        // NSBox (boxType: .custom) has no intrinsic content size — unlike
        // makeCalloutBox's fixed height, a section card's content is variable
        // (segmented control + N field rows vs. a single field row), so instead
        // of hardcoding a height, pin contentStack to all four edges of the box.
        // That makes the box's size a direct *consequence* of contentStack's own
        // well-defined intrinsic size, rather than something the box has to guess
        // at (which is what produced the giant blank/overlapping cards).
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: box.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        // Both box AND contentStack need required vertical hugging — since all
        // four edges are pinned with *equal* constraints, box and contentStack
        // are bound together as one unit, and that unit's size is only as
        // "tight" as its *weaker* hugging side. Setting only one of the two
        // (tried box alone first) still let the pair stretch to fill the tab's
        // available height, because contentStack's own default-low priority
        // was the side that gave way.
        box.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentHuggingPriority(.required, for: .vertical)

        return (box, contentStack)
    }

    /// Builds a label/field `NSGridView` with the shared column widths applied —
    /// the single source of truth for "does this field row align with every
    /// other field row in Preferences," across all four tabs.
    static func makeFieldGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Spacing.field
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Grid.labelColumnWidth
        if grid.numberOfColumns > 1 {
            grid.column(at: 1).width = Grid.fieldColumnWidth
        }
        // Without this, a vertical NSStackView with slack space (e.g. a card whose
        // width is fixed wider than its tallest sibling needs) can stretch the grid's
        // rows unevenly instead of leaving the grid at its natural fitting height —
        // pin it to required-priority hugging so all extra space goes elsewhere.
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.setContentCompressionResistancePriority(.required, for: .vertical)
        return grid
    }

    /// Liquid-glass-style panel background, same technique as the voice HUD
    /// (NSGlassEffectView .clear on macOS 26+, NSVisualEffectView fallback
    /// below that) — kept as a separate implementation from the HUD's own
    /// `makeGlassContainer` so this refactor doesn't touch already-verified
    /// HUD rendering code.
    static func makeGlassPanel(bounds: NSRect, content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = 0
            glass.style = .clear
            glass.contentView = content
            return glass
        }
        let v = NSVisualEffectView(frame: bounds)
        v.material = .contentBackground
        v.blendingMode = .behindWindow
        v.state = .active
        v.addSubview(content)
        return v
    }
}
