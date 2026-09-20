import AppKit

/// A compact settings header. The legacy name preserves controller references;
/// all five pages stay visible in one keyboard-accessible row of native buttons.
final class PreferencesSidebar: NSView {
    struct Item { let title: String; let symbol: String }
    var onSelect: ((Int) -> Void)?
    private var buttons: [SoftPillButton] = []
    private let navigation = NSStackView()

    init(items: [Item], selectedIndex: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: PixelGuanyinRenderer.shared.preferencesIcon())
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])
        let name = DesignTokens.styledLabel("Input-sa", size: 24, weight: .semibold,
                                            kern: -0.5, color: DesignTokens.Palette.ink)
        let subtitle = DesignTokens.styledLabel("語音輸入與整理", size: 11, weight: .regular,
                                                color: DesignTokens.Palette.inkMuted(0.68))
        let labels = NSStackView(views: [name, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let identity = NSStackView(views: [icon, labels, NSView()])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 12
        identity.translatesAutoresizingMaskIntoConstraints = false
        buttons = items.enumerated().map { index, item in
            let button = SoftPillButton(title: item.title, symbol: item.symbol)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setAccessibilityHelp("顯示\(item.title)設定")
            button.onPress = { [weak self] in
                self?.select(index)
                self?.onSelect?(index)
            }
            return button
        }
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 6
        navigation.translatesAutoresizingMaskIntoConstraints = false
        buttons.forEach { navigation.addArrangedSubview($0) }
        addSubview(identity)
        addSubview(navigation)
        NSLayoutConstraint.activate([
            identity.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            identity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            navigation.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 12),
            navigation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            navigation.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
        ])
        // There is no persisted category/group to migrate. Keep invalid or old
        // callers on the first real page instead of leaving an empty header.
        select(buttons.indices.contains(selectedIndex) ? selectedIndex : 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        for (i, button) in buttons.enumerated() { button.selected = i == index }
    }
}
