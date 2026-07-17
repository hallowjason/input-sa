import AppKit

/// Floating, non-activating result panel for 劃詞問答 (⌃⌥Q) and 劃詞翻譯 (⌃⌥T).
/// Shows an answer / translation near the cursor WITHOUT injecting anything into
/// the user's document. Read-only but selectable text, a copy button, an optional
/// 英/泰 language toggle (translation mode), and a close button. ⎋ closes it —
/// the panel never becomes key, so that keystroke is caught in InputController's
/// event tap (same pattern as the polish preview).
final class AnswerPanelController {

    static let shared = AnswerPanelController()
    private init() {}

    /// Config for the translation-mode language toggle. Absent ⇒ QA mode (no toggle).
    struct LanguageToggle {
        let options: [String]        // e.g. ["英文", "泰文"]
        let current: String
        let onSelect: (String) -> Void
    }

    private var panel: NSPanel?
    private weak var copyButton: NSButton?
    private var lastBody: String = ""

    private static let width: CGFloat = 420
    private static let maxTextHeight: CGFloat = 380

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Public API

    /// Show (or update, if already open) the panel.
    /// - Parameters:
    ///   - title: header line ("問答" / "翻譯 → 英文").
    ///   - body: the answer / translation text.
    ///   - near: cursor rect used for placement (reuses `floatingOrigin`).
    ///   - toggle: language switcher config for translation mode; nil for QA.
    func show(title: String, body: String, near cursor: NSRect,
              toggle: LanguageToggle? = nil, on screen: NSScreen? = NSScreen.main) {
        lastBody = body
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let content = buildContent(title: title, body: body, toggle: toggle)
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.setFrameOrigin(floatingOrigin(size: panel.frame.size, below: cursor, screen: screen))
        panel.orderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return p
    }

    // MARK: - Content

    private func buildContent(title: String, body: String, toggle: LanguageToggle?) -> NSView {
        let root = PaperCardView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let hInset: CGFloat = 18
        let vInset: CGFloat = 16

        // Title
        let titleLabel = DesignTokens.styledLabel(
            title, size: 13, weight: .semibold, kern: -0.2,
            color: DesignTokens.Palette.inkMuted(0.6))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Body (scrollable, read-only, selectable)
        let (scroll, textHeight) = makeTextScroll(body: body, width: Self.width - 2 * hInset)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Footer buttons
        let footer = makeFooter(toggle: toggle)
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(scroll)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),

            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: vInset),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: hInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -hInset),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: hInset),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -hInset),
            scroll.heightAnchor.constraint(equalToConstant: textHeight),

            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: hInset),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -hInset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -vInset),
        ])
        return root
    }

    /// Read-only selectable NSTextView inside an NSScrollView. Returns the scroll
    /// view plus the height to pin it at (capped at `maxTextHeight`, hugging the
    /// content otherwise). CJK text wraps at the fixed column width.
    private func makeTextScroll(body: String, width: CGFloat) -> (NSScrollView, CGFloat) {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = DesignTokens.Palette.ink
        textView.font = DesignTokens.uiFont(14)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let textWidth = width - 4   // minus container inset
        textView.textContainer?.containerSize =
            NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 10)

        // Paragraph style: comfortable CJK line height.
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        textView.textStorage?.setAttributedString(NSAttributedString(string: body, attributes: [
            .font: DesignTokens.uiFont(14),
            .foregroundColor: DesignTokens.Palette.ink,
            .paragraphStyle: para,
        ]))

        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
        }
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).size.height ?? 40
        let height = min(max(used + 12, 28), Self.maxTextHeight)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = used + 12 > Self.maxTextHeight
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return (scroll, height)
    }

    private func makeFooter(toggle: LanguageToggle?) -> NSStackView {
        var views: [NSView] = []

        let copyBtn = DesignTokens.pushButton(title: "複製", target: self,
                                              action: #selector(copyBody))
        copyButton = copyBtn
        views.append(copyBtn)

        if let toggle {
            let seg = NSSegmentedControl(labels: toggle.options, trackingMode: .selectOne,
                                         target: self, action: #selector(languageChanged(_:)))
            seg.segmentStyle = .rounded
            seg.controlSize = .small
            seg.font = DesignTokens.uiFont(12)
            if let idx = toggle.options.firstIndex(of: toggle.current) {
                seg.selectedSegment = idx
            }
            segmentOptions = toggle.options
            segmentCallback = toggle.onSelect
            views.append(seg)
        } else {
            segmentOptions = nil
            segmentCallback = nil
        }

        let spring = NSView()
        spring.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spring)

        let closeBtn = DesignTokens.pushButton(title: "關閉 ⎋", target: self,
                                               action: #selector(closeClicked))
        views.append(closeBtn)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        spring.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        return stack
    }

    private var segmentOptions: [String]?
    private var segmentCallback: ((String) -> Void)?

    // MARK: - Actions

    @objc private func copyBody() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastBody, forType: .string)
        copyButton?.title = "已複製"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton?.title = "複製"
        }
    }

    @objc private func languageChanged(_ sender: NSSegmentedControl) {
        guard let options = segmentOptions,
              (0..<options.count).contains(sender.selectedSegment) else { return }
        segmentCallback?(options[sender.selectedSegment])
    }

    @objc private func closeClicked() { close() }
}

/// Paper-surfaced rounded card whose CALayer fill/border re-resolve on light/dark
/// change (CALayer cgColors don't auto-track appearance — same technique as
/// GroupCardView / CardRowView).
private final class PaperCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
