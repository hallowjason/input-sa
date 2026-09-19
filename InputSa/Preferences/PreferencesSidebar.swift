import AppKit

/// A compact settings header. The legacy name preserves controller references;
/// navigation is now a two-level, keyboard-accessible group of native buttons.
final class PreferencesSidebar: NSView {
    struct Item { let title: String; let symbol: String }
    var onSelect: ((Int) -> Void)?
    private let groups = [[1, 3, 4], [0, 2]]
    private var lastSelection = [1, 0]
    private var buttons: [SoftPillButton] = []
    private let levelPicker = SoftSegmentedPicker(labels: ["一般", "進階"])
    private let navigation = NSStackView()
    private var currentGroup = 0

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
        let identity = NSStackView(views: [icon, labels, NSView(), levelPicker])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 12
        identity.translatesAutoresizingMaskIntoConstraints = false
        levelPicker.widthAnchor.constraint(equalToConstant: 170).isActive = true
        levelPicker.onSelect = { [weak self] group in
            guard let self else { return }
            self.select(self.lastSelection[group])
            self.onSelect?(self.lastSelection[group])
        }
        buttons = items.enumerated().map { index, item in
            let button = SoftPillButton(title: item.title, symbol: item.symbol)
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
        select(selectedIndex)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ index: Int) {
        guard buttons.indices.contains(index), let group = groups.firstIndex(where: { $0.contains(index) }) else { return }
        if navigation.arrangedSubviews.isEmpty || group != currentGroup {
            navigation.arrangedSubviews.forEach { $0.removeFromSuperview() }
            groups[group].forEach { navigation.addArrangedSubview(buttons[$0]) }
        }
        currentGroup = group
        lastSelection[group] = index
        levelPicker.select(group)
        for (i, button) in buttons.enumerated() { button.selected = i == index }
    }
}
