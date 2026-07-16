import AppKit

/// System Settings-style sidebar: translucent material, app identity on top
/// (the pixel Guanyin at its native 64 pt — no smoothing-blurred downscale),
/// then one nav item per pane. Selection is owned by the window controller:
/// clicks report through `onSelect`, and the controller calls `select(_:)`
/// back — one source of truth, no PillTabBar/NSTabView-style split-brain.
final class PreferencesSidebar: NSView {

    struct Item {
        let title: String
        let symbol: String
    }

    var onSelect: ((Int) -> Void)?
    private var buttons: [SidebarNavButton] = []

    init(items: [Item], selectedIndex: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        // ── App identity ────────────────────────────────────────
        let icon = NSImageView(image: PixelGuanyinRenderer.shared.preferencesIcon())
        icon.imageScaling = .scaleNone
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = DesignTokens.styledLabel("Input-sa", size: 13, weight: .semibold,
                                                 kern: -0.2, color: DesignTokens.Palette.ink)
        let subLabel = DesignTokens.styledLabel("語音輸入法", size: 11, weight: .regular,
                                                kern: -0.1,
                                                color: DesignTokens.Palette.inkMuted(0.55))
        let nameStack = NSStackView(views: [nameLabel, subLabel])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2

        let identity = NSStackView(views: [icon, nameStack])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 10
        identity.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 10, right: 6)

        // ── Nav items ───────────────────────────────────────────
        buttons = items.enumerated().map { idx, item in
            let btn = SidebarNavButton(title: item.title, symbol: item.symbol)
            btn.onClick = { [weak self] in
                self?.select(idx)
                self?.onSelect?(idx)
            }
            return btn
        }

        let stack = NSStackView(views: [identity] + buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        // Top inset clears the window's traffic lights (full-size content view).
        stack.edgeInsets = NSEdgeInsets(top: 48, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for view in [identity] + buttons as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        // Hairline edge against the content pane.
        let edge = DesignTokens.hairline()
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])
        // The vertical hairline overrides the 1-pt *height* the factory set —
        // deactivate it so the edge can stretch vertically instead.
        for c in edge.constraints where c.firstAttribute == .height { c.isActive = false }

        select(selectedIndex)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Programmatic selection (also called on click) — updates button visuals.
    func select(_ index: Int) {
        for (i, btn) in buttons.enumerated() { btn.isSelected = (i == index) }
    }
}

/// One sidebar nav row: 16-pt SF Symbol + 13-pt label. Selected = accent fill
/// with white content; hover = subtle well. Hand-drawn (bare AppKit, no
/// NSTableView source list needed for four fixed items).
private final class SidebarNavButton: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { applyState() } }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let title: String
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            iconView.image = img
        }
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [iconView, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyState() {
        let textColor: NSColor = isSelected ? .white : DesignTokens.Palette.ink
        label.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: DesignTokens.uiFont(13),
            .kern: -0.2,
            .foregroundColor: textColor,
        ])
        iconView.contentTintColor = isSelected ? .white : DesignTokens.Palette.inkMuted(0.6)
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                layer?.backgroundColor = DesignTokens.Palette.accent.cgColor
            } else if hovering {
                layer?.backgroundColor = DesignTokens.Palette.well.cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyBackground() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
