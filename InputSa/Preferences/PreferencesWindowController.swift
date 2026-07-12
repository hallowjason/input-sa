import AppKit

/// Preferences window with four tabs:
/// 1. API Keys  2. Voice & Shortcuts  3. Custom AI Modes  4. Dojo Vocabulary
final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {

    static let shared = PreferencesWindowController()

    // MARK: - Shortcut Keys storage (voice only — polish is automatic after transcription)
    private static let voiceShortcutKey = "com.inputsa.shortcut.voice"

    // MARK: - Dojo mode toggle storage (read by SherpaVoiceService per-transcription)
    private static let dojoModeKey = "com.inputsa.dojoMode"

    static var dojoMode: Bool {
        get { UserDefaults.standard.bool(forKey: dojoModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: dojoModeKey) }
    }

    static var voiceShortcut: ShortcutRecorderView.Shortcut? {
        get {
            guard let data = UserDefaults.standard.data(forKey: voiceShortcutKey) else { return nil }
            return try? JSONDecoder().decode(ShortcutRecorderView.Shortcut.self, from: data)
        }
        set {
            if let sc = newValue, let data = try? JSONEncoder().encode(sc) {
                UserDefaults.standard.set(data, forKey: voiceShortcutKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceShortcutKey)
            }
        }
    }

    // MARK: - UI
    private var tabView: NSTabView!
    private var pillTabBar: PillTabBar!
    // API Keys tab
    private var providerPicker: PillSegmentedControl!
    private var groqSection: NSView!
    private var googleSection: NSView!
    private var groqField: NSTextField!
    private var googleSttField: NSTextField!
    private var geminiField: NSTextField!
    private var providerStatusLabel: NSTextField!
    private var providerStatusBox: NSBox!
    // Voice tab
    private var voiceRecorder: ShortcutRecorderView!
    private var translatePopUp: NSPopUpButton!
    private var shortcutWarningLabel: NSTextField!
    // Custom modes tab
    private var promptTableView: NSTableView!
    private var customPrompts: [UserStyleModel.CustomPrompt] = []
    // Dojo vocabulary tab
    private var dojoTableView: NSTableView!
    private var dojoEntries: [DojoCorrectionTable.Entry] = []
    private var dojoModeSwitch: NSSwitch!

    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Input-sa 偏好設定"
        // Voice PTT and the preferences shortcut both work from inside fullscreen apps
        // (CGEventTap, not app-switch-dependent) — without this the window would open
        // on the user's regular desktop Space while they stay stuck looking at the
        // fullscreen app, appearing to do nothing.
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup
    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let bannerImage = PixelGuanyinRenderer.shared.preferencesIcon()
        let bannerView = NSImageView(image: bannerImage)
        bannerView.imageScaling = .scaleNone
        bannerView.setFrameSize(NSSize(width: 64, height: 64))

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.attributedStringValue = NSAttributedString(string: "INPUT-SA", attributes: [
            .font: DesignTokens.monoFont(24, weight: .bold),
            .kern: 2.2,
            .foregroundColor: NSColor.labelColor,
        ])
        let subtitleLabel = NSTextField(labelWithString: "語音轉錄 · 文字潤飾 · AI 強化")
        subtitleLabel.font = DesignTokens.monoFont(11)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        titleStack.alignment = .leading

        let bannerStack = NSStackView(views: [bannerView, titleStack])
        bannerStack.orientation = .horizontal
        bannerStack.spacing = 12
        bannerStack.alignment = .centerY
        bannerStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let separator = NSBox()
        separator.boxType = .separator

        tabView = NSTabView()
        // Native tab chrome is hidden entirely — PillTabBar below drives selection.
        tabView.tabViewType = .noTabsNoBorder
        tabView.addTabViewItem(makeAPIKeysTab())
        tabView.addTabViewItem(makeVoiceTab())
        tabView.addTabViewItem(makeCustomModesTab())
        tabView.addTabViewItem(makeDojoTab())

        tabView.delegate = self
        pillTabBar = PillTabBar(labels: ["API Keys", "語音與快捷鍵", "自訂 AI 模式", "道場詞庫"])
        pillTabBar.onSelect = { [weak self] idx in
            guard let self, idx < self.tabView.tabViewItems.count else { return }
            self.tabView.selectTabViewItem(at: idx)
        }
        let tabBarRow = NSStackView(views: [pillTabBar])
        tabBarRow.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 4, right: 16)

        let mainStack = NSStackView(views: [bannerStack, separator, tabBarRow, tabView])
        mainStack.orientation = .vertical
        mainStack.spacing = 0

        // Flat system background — deliberately not glass. Preferences reads as a
        // "hardware settings panel," a different register from the HUD's liquid-glass
        // "living assistant" panel. (DesignTokens.makeGlassPanel is kept for any future
        // glass surface but is intentionally unused here.)
        contentView.addSubview(mainStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Tab 1: API Keys

    private func makeAPIKeysTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "API Keys"

        // ── 目前使用：狀態列（一眼看出主力是哪個服務）─────────
        let statusBadge = DesignTokens.makeSolidBadge(text: "", fill: .systemBlue)
        providerStatusBox = statusBadge.box
        providerStatusLabel = statusBadge.label

        // ── Card 1: 語音轉錄服務 ───────────────────────────────
        let transcribeCard = DesignTokens.makeSectionCard(title: "語音轉錄服務")

        let initialProviderIdx: Int
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   initialProviderIdx = 0
        case .google: initialProviderIdx = 1
        case .sherpa: initialProviderIdx = 2
        }
        providerPicker = PillSegmentedControl(
            labels: ["Groq Whisper", "Google STT（含台語）", "本地 Paraformer"],
            selectedIndex: initialProviderIdx)
        providerPicker.onSelect = { [weak self] idx in
            self?.serviceProviderChanged(idx)
        }

        let serviceHint = NSTextField(wrappingLabelWithString:
            "Groq：免費，繁體中文  ·  Google STT：60 分鐘 / 月免費，支援國語 + 台語混合  ·  本地 Paraformer：完全離線、免 API Key、免飛航模式也能用，含道場詞庫糾正。\n" +
            "點選上方切換使用的服務；未選取的服務其 API Key 仍會保留在 Keychain，隨時可切回。")
        serviceHint.font = DesignTokens.monoFont(10)
        serviceHint.textColor = .secondaryLabelColor
        serviceHint.preferredMaxLayoutWidth = 420

        // ── Groq section ──────────────────────────────────────
        let groqLabel = NSTextField(labelWithString: "Groq API Key")
        groqLabel.font = DesignTokens.monoFont(12)
        groqField = NSTextField()
        groqField.placeholderString = "gsk_..."
        groqField.stringValue = APIKeyStore.shared.groqKey
        groqField.isEditable = true
        groqField.isSelectable = true
        let groqLink = makeLinkButton(title: "前往 Groq Console 取得 →",
                                      url: "https://console.groq.com/keys")

        groqSection = DesignTokens.makeFieldGrid([
            [groqLabel, groqField],
            [NSView(),  groqLink],
        ])

        // ── Google STT section ────────────────────────────────
        let googleLabel = NSTextField(labelWithString: "Google API Key")
        googleLabel.font = DesignTokens.monoFont(12)
        googleSttField = NSTextField()
        googleSttField.placeholderString = "AIzaSy..."
        googleSttField.stringValue = APIKeyStore.shared.googleSttKey
        googleSttField.isEditable = true
        googleSttField.isSelectable = true
        let googleLink = makeLinkButton(title: "前往 GCP Console 取得 →",
                                        url: "https://console.cloud.google.com/apis/credentials")

        let googleNote = NSTextField(labelWithString: "需啟用 Cloud Speech-to-Text API")
        googleNote.font = DesignTokens.monoFont(10)
        googleNote.textColor = .secondaryLabelColor

        googleSection = DesignTokens.makeFieldGrid([
            [googleLabel, googleSttField],
            [NSView(),    googleLink],
            [NSView(),    googleNote],
        ])

        [providerPicker, serviceHint, groqSection, googleSection].forEach {
            transcribeCard.contentStack.addArrangedSubview($0!)
        }

        // ── Card 2: AI 潤飾服務 ────────────────────────────────
        let polishCard = DesignTokens.makeSectionCard(title: "AI 潤飾服務")

        let geminiLabel = NSTextField(labelWithString: "Gemini API Key")
        geminiLabel.font = DesignTokens.monoFont(12)
        geminiField = NSTextField()
        geminiField.placeholderString = "AIzaSy..."
        geminiField.stringValue = APIKeyStore.shared.geminiKey
        geminiField.isEditable = true
        geminiField.isSelectable = true
        let geminiLink = makeLinkButton(title: "前往 AI Studio 取得 →",
                                        url: "https://aistudio.google.com/app/apikey")

        let geminiGrid = DesignTokens.makeFieldGrid([
            [geminiLabel, geminiField],
            [NSView(),    geminiLink],
        ])
        polishCard.contentStack.addArrangedSubview(geminiGrid)

        // ── Save button ───────────────────────────────────────
        let saveBtn = DesignTokens.makeSolidButton(
            title: "儲存設定", target: self, action: #selector(saveAPIKeys))

        let noteLabel = NSTextField(wrappingLabelWithString:
            "API Key 安全地儲存在系統 Keychain 中。Gemini 為選填，未設定時跳過 AI 潤飾步驟。")
        noteLabel.font = DesignTokens.monoFont(10)
        noteLabel.textColor = .secondaryLabelColor

        // ── Assemble ──────────────────────────────────────────
        // Trailing flex spacer: NSTabView stretches item.view to fill its full content
        // area, taller than this tab's natural content. A bare NSView has no intrinsic
        // size (nothing to hug to), so it absorbs 100% of that slack — without it, the
        // *last card* was the one silently stretched, leaving a hollow gap inside the
        // card's own border (looked exactly like the "no intrinsic size" NSBox trap,
        // but was actually this — content-hugging priority on the card couldn't fix it
        // because a wrapping NSTextField label refuses to be the one to stretch).
        let stack = NSStackView(views: [
            providerStatusBox,
            transcribeCard.box,
            polishCard.box,
            saveBtn,
            noteLabel,
            NSView(),
        ])
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        [providerStatusBox, transcribeCard.box, polishCard.box].forEach {
            $0!.widthAnchor.constraint(equalToConstant: 456).isActive = true
        }

        updateServiceSectionVisibility()
        updateProviderStatus()

        item.view = stack
        return item
    }

    private func serviceProviderChanged(_ selectedIndex: Int) {
        let provider: APIKeyStore.VoiceProvider
        switch selectedIndex {
        case 1:  provider = .google
        case 2:  provider = .sherpa
        default: provider = .groq
        }
        APIKeyStore.shared.voiceProvider = provider
        updateServiceSectionVisibility()
        updateProviderStatus()
    }

    /// Keeps the "目前使用" status banner in sync with the active provider —
    /// the segmented control alone doesn't make it obvious which service is
    /// live vs. which API Keys are just kept around as a switchable fallback.
    private func updateProviderStatus() {
        let (icon, text, tint): (String, String, NSColor)
        switch APIKeyStore.shared.voiceProvider {
        case .sherpa:
            (icon, text, tint) = ("💻", "目前使用：本地 Paraformer — 完全離線運算，不會呼叫任何雲端 API", .systemGreen)
        case .groq:
            (icon, text, tint) = ("🌐", "目前使用：Groq Whisper（雲端）— 需要網路連線", .systemBlue)
        case .google:
            (icon, text, tint) = ("🌐", "目前使用：Google STT（雲端）— 需要網路連線", .systemBlue)
        }
        providerStatusLabel.stringValue = "\(icon)  \(text)"
        providerStatusBox.fillColor = tint
    }

    private func updateServiceSectionVisibility() {
        switch APIKeyStore.shared.voiceProvider {
        case .groq:
            groqSection?.isHidden = false
            googleSection?.isHidden = true
        case .google:
            groqSection?.isHidden = true
            googleSection?.isHidden = false
        case .sherpa:
            groqSection?.isHidden = true
            googleSection?.isHidden = true
        }
    }

    /// Creates a clickable hyperlink-style button.
    private func makeLinkButton(title: String, url: String) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = DesignTokens.monoFont(11)
        btn.contentTintColor = NSColor.linkColor
        btn.toolTip = url
        btn.identifier = NSUserInterfaceItemIdentifier(url)
        return btn
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let urlStr = sender.identifier?.rawValue,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func saveAPIKeys() {
        APIKeyStore.shared.groqKey      = groqField.stringValue
        APIKeyStore.shared.geminiKey    = geminiField.stringValue
        APIKeyStore.shared.googleSttKey = googleSttField.stringValue
        showAlert("設定已儲存", info: "API Key 已安全地寫入 Keychain。")
    }

    // MARK: - Tab 2: Voice & Shortcuts
    private func makeVoiceTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "語音與快捷鍵"

        // ── Default PTT info ─────────────────────────────────
        // (NSBox custom-type intrinsic-size trap: see DesignTokens.makeCalloutBox.)
        let defaultCallout = DesignTokens.makeCalloutBox(
            text: "🎙  長按右 ⌥ 說話 → 轉錄輸出　　🌐  長按右 ⌘ 說中文 → 翻譯輸出",
            tint: .controlAccentColor)
        let defaultBox = defaultCallout.box
        defaultCallout.label.textColor = .labelColor

        // ── Custom shortcut (optional override) ─────────────
        let shortcutCard = DesignTokens.makeSectionCard(title: "自訂快捷鍵（選填）")

        voiceRecorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        voiceRecorder.setShortcut(PreferencesWindowController.voiceShortcut)
        voiceRecorder.onChange = { [weak self] sc in
            PreferencesWindowController.voiceShortcut = sc
            self?.updateShortcutWarning()
        }

        let clearBtn = NSButton(title: "清除", target: self, action: #selector(clearVoiceShortcut))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small

        let recorderRow = NSStackView(views: [voiceRecorder, clearBtn])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 8
        recorderRow.alignment = .centerY

        let overrideHint = NSTextField(wrappingLabelWithString:
            "設定後將取代右 Option 長按。點擊框格錄製新快捷鍵（含無修飾鍵的單鍵）；按 ⎋ 取消錄製。點「清除」恢復右 Option 長按預設。")
        overrideHint.font = DesignTokens.monoFont(10)
        overrideHint.textColor = .secondaryLabelColor

        // Only visible when the saved shortcut has zero modifiers — that key will fire
        // system-wide on every matching keystroke, including normal typing in any app.
        shortcutWarningLabel = NSTextField(wrappingLabelWithString:
            "⚠️ 這是不含修飾鍵的單一按鍵，日常打字打到這個鍵時也會觸發語音錄音，請確認這是你要的。")
        shortcutWarningLabel.font = DesignTokens.monoFont(10, weight: .medium)
        shortcutWarningLabel.textColor = .systemOrange
        shortcutWarningLabel.isHidden = true

        let langLabel = NSTextField(labelWithString: "快捷鍵")
        let translateLabel = NSTextField(labelWithString: "翻譯目標語言")
        let characterLabel = NSTextField(labelWithString: "HUD 神佛角色")
        [langLabel, translateLabel, characterLabel].forEach { $0.font = DesignTokens.monoFont(12) }

        let overrideGrid = DesignTokens.makeFieldGrid([
            [langLabel,       recorderRow],
            [translateLabel,  makeTranslatePopUp()],
            [characterLabel,  makeCharacterPopUp()],
        ])
        shortcutCard.contentStack.addArrangedSubview(overrideGrid)
        shortcutCard.contentStack.addArrangedSubview(overrideHint)
        shortcutCard.contentStack.addArrangedSubview(shortcutWarningLabel)

        // ── Usage hint (plain footnote, outside any card) ────
        let hintLabel = NSTextField(wrappingLabelWithString: """
            語音輸入流程：錄音結束 → 自動轉錄 → AI 潤飾 → 輸出至游標位置。
            若 Gemini API Key 未設定，轉錄結果直接輸出（不經潤飾）。
            語音翻譯（兩種用法擇一）：
            　• 說話結尾直接講「請幫我翻譯成英文」（日文/泰文…皆可，免記快捷鍵）
            　• 或長按右 ⌘ 說中文，放開後翻譯成上方目標語言（需 Gemini API Key）。
            錄音中若按下其他按鍵（右⌘＋C 等組合鍵），翻譯錄音自動取消、組合鍵照常生效。
            文字潤飾快捷鍵：選取文字後按 Ctrl+Option+P（同偏好設定）。
            """)
        hintLabel.font = DesignTokens.monoFont(10)
        hintLabel.textColor = .secondaryLabelColor

        // Trailing flex spacer — see the matching comment in makeAPIKeysTab().
        let stack = NSStackView(views: [
            defaultBox,
            shortcutCard.box,
            hintLabel,
            NSView(),
        ])
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        shortcutCard.box.widthAnchor.constraint(equalToConstant: 456).isActive = true

        updateShortcutWarning()

        item.view = stack
        return item
    }

    /// Shows the "unmodified single key" warning only when a shortcut is saved AND
    /// it has zero modifier flags.
    private func updateShortcutWarning() {
        if let sc = PreferencesWindowController.voiceShortcut {
            shortcutWarningLabel.isHidden = sc.modifierFlags != 0
        } else {
            shortcutWarningLabel.isHidden = true
        }
    }

    /// Common translate targets. Gemini's translate prompt takes this string
    /// verbatim (see TranscriptionMode.swift) so any language name works —
    /// this list is just the curated set exposed in the popup.
    static let translateLanguages = ["英文", "日文", "韓文", "泰文", "越南文", "印尼文"]

    private func makeTranslatePopUp() -> NSPopUpButton {
        translatePopUp = NSPopUpButton()
        translatePopUp.addItems(withTitles: Self.translateLanguages)
        let saved = TranscriptionMode.translateTargetLanguage
        if let idx = Self.translateLanguages.firstIndex(of: saved) {
            translatePopUp.selectItem(at: idx)
        }
        translatePopUp.target = self
        translatePopUp.action = #selector(translateLangChanged)
        return translatePopUp
    }

    private func makeCharacterPopUp() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: HUDCharacter.allCases.map { $0.displayName })
        if let idx = HUDCharacter.allCases.firstIndex(of: HUDCharacter.current) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(hudCharacterChanged(_:))
        return popup
    }

    @objc private func hudCharacterChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < HUDCharacter.allCases.count else { return }
        HUDCharacter.current = HUDCharacter.allCases[idx]
    }

    @objc private func clearVoiceShortcut() {
        PreferencesWindowController.voiceShortcut = nil
        voiceRecorder?.setShortcut(nil)
        updateShortcutWarning()
    }

    @objc private func translateLangChanged() {
        let lang = translatePopUp?.titleOfSelectedItem ?? "英文"
        TranscriptionMode.translateTargetLanguage = lang
    }

    // MARK: - Tab 3: Custom AI Modes
    private func makeCustomModesTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "自訂 AI 模式"

        promptTableView = NSTableView()
        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("emoji"))
        col1.title = "🔖"; col1.width = 30
        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col2.title = "名稱"; col2.width = 100
        let col3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("prompt"))
        col3.title = "指令"; col3.width = 330
        promptTableView.addTableColumn(col1)
        promptTableView.addTableColumn(col2)
        promptTableView.addTableColumn(col3)
        promptTableView.dataSource = self
        promptTableView.delegate = self
        promptTableView.usesAlternatingRowBackgroundColors = false
        promptTableView.rowHeight = 26

        let scroll = NSScrollView()
        scroll.documentView = promptTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 428),
            scroll.heightAnchor.constraint(equalToConstant: 220),
        ])

        let addBtn = NSButton(title: "+ 新增", target: self, action: #selector(addCustomPrompt))
        let delBtn = NSButton(title: "刪除選取", target: self, action: #selector(deleteCustomPrompt))
        addBtn.bezelStyle = .rounded; delBtn.bezelStyle = .rounded
        addBtn.font = DesignTokens.monoFont(11); delBtn.font = DesignTokens.monoFont(11)
        let btnBar = NSStackView(views: [addBtn, delBtn, NSView()])
        btnBar.orientation = .horizontal; btnBar.spacing = DesignTokens.Spacing.compact

        customPrompts = UserStyleModel.shared.customPrompts

        let promptsCard = DesignTokens.makeSectionCard(title: "自訂模式清單")
        [scroll, btnBar].forEach { promptsCard.contentStack.addArrangedSubview($0) }

        let hintLabel = NSTextField(wrappingLabelWithString:
            "語音轉錄完成後，可在此新增自訂 AI 指令模式，供後續輸出時套用。")
        hintLabel.font = DesignTokens.monoFont(10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 456

        let stack = NSStackView(views: [promptsCard.box, hintLabel, NSView()])  // trailing spacer, see makeAPIKeysTab()
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        promptsCard.box.widthAnchor.constraint(equalToConstant: 456).isActive = true

        item.view = stack
        return item
    }

    @objc private func addCustomPrompt() {
        let alert = NSAlert()
        alert.messageText = "新增自訂模式"
        alert.addButton(withTitle: "新增")
        alert.addButton(withTitle: "取消")

        let emojiField  = NSTextField()
        emojiField.placeholderString = "Emoji（如 📱）"
        let nameField   = NSTextField()
        nameField.placeholderString = "模式名稱（如 IG 貼文）"
        let promptField = NSTextField()
        promptField.placeholderString = "AI 指令（如：請改寫成 IG 貼文風格...）"

        let stack = NSStackView(views: [emojiField, nameField, promptField])
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.field
        stack.setFrameSize(NSSize(width: 220, height: stack.fittingSize.height))
        [emojiField, nameField, promptField].forEach {
            $0.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        alert.accessoryView = stack

        if alert.runModal() == .alertFirstButtonReturn {
            let prompt = UserStyleModel.CustomPrompt(
                id: UUID().uuidString,
                name: nameField.stringValue.isEmpty ? "自訂" : nameField.stringValue,
                emoji: emojiField.stringValue.isEmpty ? "✨" : emojiField.stringValue,
                prompt: promptField.stringValue
            )
            UserStyleModel.shared.addCustomPrompt(prompt)
            customPrompts = UserStyleModel.shared.customPrompts
            promptTableView.reloadData()
        }
    }

    @objc private func deleteCustomPrompt() {
        let row = promptTableView.selectedRow
        guard row >= 0, row < customPrompts.count else { return }
        UserStyleModel.shared.removeCustomPrompt(id: customPrompts[row].id)
        customPrompts = UserStyleModel.shared.customPrompts
        promptTableView.reloadData()
    }

    // MARK: - Tab 4: Dojo Vocabulary
    private func makeDojoTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "道場詞庫"

        dojoModeSwitch = NSSwitch()
        dojoModeSwitch.state = PreferencesWindowController.dojoMode ? .on : .off
        dojoModeSwitch.target = self
        dojoModeSwitch.action = #selector(dojoModeChanged)

        let dojoModeLabel = NSTextField(labelWithString: "道場模式（套用「限道場模式」規則）")
        dojoModeLabel.font = DesignTokens.monoFont(12)

        let dojoModeRow = NSStackView(views: [dojoModeSwitch, dojoModeLabel])
        dojoModeRow.orientation = .horizontal
        dojoModeRow.spacing = DesignTokens.Spacing.compact
        dojoModeRow.alignment = .centerY

        dojoTableView = NSTableView()
        let colWrong = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wrong"))
        colWrong.title = "常見誤辨"; colWrong.width = 140
        let colCorrect = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("correct"))
        colCorrect.title = "正確詞"; colCorrect.width = 140
        let colTier = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tier"))
        colTier.title = "分級"; colTier.width = 90
        let colPhonetic = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("phonetic"))
        colPhonetic.title = "拼音"; colPhonetic.width = 50
        dojoTableView.addTableColumn(colWrong)
        dojoTableView.addTableColumn(colCorrect)
        dojoTableView.addTableColumn(colTier)
        dojoTableView.addTableColumn(colPhonetic)
        dojoTableView.dataSource = self
        dojoTableView.delegate = self
        dojoTableView.usesAlternatingRowBackgroundColors = false
        dojoTableView.rowHeight = 26
        dojoTableView.target = self
        dojoTableView.doubleAction = #selector(editDojoEntry)

        let scroll = NSScrollView()
        scroll.documentView = dojoTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 428),
            scroll.heightAnchor.constraint(equalToConstant: 260),
        ])

        let addBtn = NSButton(title: "+ 新增", target: self, action: #selector(addDojoEntry))
        let editBtn = NSButton(title: "編輯選取", target: self, action: #selector(editDojoEntry))
        let delBtn = NSButton(title: "刪除選取", target: self, action: #selector(deleteDojoEntry))
        addBtn.bezelStyle = .rounded; editBtn.bezelStyle = .rounded; delBtn.bezelStyle = .rounded
        [addBtn, editBtn, delBtn].forEach { $0.font = DesignTokens.monoFont(11) }
        let btnBar = NSStackView(views: [addBtn, editBtn, delBtn, NSView()])
        btnBar.orientation = .horizontal; btnBar.spacing = DesignTokens.Spacing.compact

        dojoEntries = DojoCorrectionTable.shared.allEntries

        let dojoCard = DesignTokens.makeSectionCard(title: "道場詞條")
        [dojoModeRow, scroll, btnBar].forEach { dojoCard.contentStack.addArrangedSubview($0) }

        let hintLabel = NSTextField(wrappingLabelWithString: """
            語音轉錄常聽錯的道場專有名詞（人名、聖號、術語），在此新增糾正規則。「一律套用」永遠生效；\
            「限道場模式」只在上方勾選開啟時生效，避免誤糾一般口語（如「半道而廢」）。\
            拼音糾正會自動比對所有同音變體（如妙吉大帝／妙急大帝皆會糾正為妙極大帝），通常不需關閉。
            """)
        hintLabel.font = DesignTokens.monoFont(10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 456

        let stack = NSStackView(views: [dojoCard.box, hintLabel, NSView()])  // trailing spacer, see makeAPIKeysTab()
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        dojoCard.box.widthAnchor.constraint(equalToConstant: 456).isActive = true

        item.view = stack
        return item
    }

    @objc private func dojoModeChanged() {
        PreferencesWindowController.dojoMode = (dojoModeSwitch.state == .on)
    }

    /// Shared add/edit modal. `editingIndex == nil` means "add new".
    private func presentDojoEntryEditor(editingIndex: Int?) {
        let existing = editingIndex.map { dojoEntries[$0] }

        let alert = NSAlert()
        alert.messageText = editingIndex == nil ? "新增道場詞條" : "編輯道場詞條"
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        let wrongField = NSTextField()
        wrongField.placeholderString = "常見誤辨（如：妙計大替）"
        wrongField.stringValue = existing?.wrong ?? ""

        let correctField = NSTextField()
        correctField.placeholderString = "正確詞（如：妙極大帝）"
        correctField.stringValue = existing?.correct ?? ""

        let tierPopUp = NSPopUpButton()
        tierPopUp.addItems(withTitles: ["一律套用", "限道場模式"])
        tierPopUp.selectItem(at: existing?.tier == "dojoOnly" ? 1 : 0)

        let phoneticCheckbox = NSButton(checkboxWithTitle: "同時套用拼音同音糾正", target: nil, action: nil)
        phoneticCheckbox.state = (existing?.phonetic ?? true) ? .on : .off

        let stack = NSStackView(views: [wrongField, correctField, tierPopUp, phoneticCheckbox])
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.item
        [wrongField, correctField, tierPopUp].forEach {
            $0.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wrong = wrongField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = correctField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !correct.isEmpty else { return }

        let entry = DojoCorrectionTable.Entry(
            wrong: wrong,
            correct: correct,
            tier: tierPopUp.indexOfSelectedItem == 1 ? "dojoOnly" : "always",
            phonetic: phoneticCheckbox.state == .on
        )

        var updated = dojoEntries
        if let idx = editingIndex {
            updated[idx] = entry
        } else {
            updated.append(entry)
        }
        applyDojoEntries(updated, failureMessage: "儲存失敗")
    }

    @objc private func addDojoEntry() {
        presentDojoEntryEditor(editingIndex: nil)
    }

    @objc private func editDojoEntry() {
        let row = dojoTableView.selectedRow
        guard row >= 0, row < dojoEntries.count else { return }
        presentDojoEntryEditor(editingIndex: row)
    }

    @objc private func deleteDojoEntry() {
        let row = dojoTableView.selectedRow
        guard row >= 0, row < dojoEntries.count else { return }
        var updated = dojoEntries
        updated.remove(at: row)
        applyDojoEntries(updated, failureMessage: "刪除失敗")
    }

    /// Persist `updated` to `DojoCorrectionTable` and refresh the table view.
    /// On write failure, the in-memory table/UI are left untouched and an alert shown.
    private func applyDojoEntries(_ updated: [DojoCorrectionTable.Entry], failureMessage: String) {
        if DojoCorrectionTable.shared.save(updated) {
            dojoEntries = DojoCorrectionTable.shared.allEntries
            dojoTableView.reloadData()
        } else {
            showAlert(failureMessage, info: "無法寫入偏好設定檔案，請確認磁碟空間或權限。")
        }
    }

    // MARK: - Show
    func showPreferences() {
        // Refresh all fields each time (in case changed externally)
        groqField?.stringValue      = APIKeyStore.shared.groqKey
        geminiField?.stringValue    = APIKeyStore.shared.geminiKey
        googleSttField?.stringValue = APIKeyStore.shared.googleSttKey
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   providerPicker?.select(0)
        case .google: providerPicker?.select(1)
        case .sherpa: providerPicker?.select(2)
        }
        updateServiceSectionVisibility()
        updateProviderStatus()
        voiceRecorder?.setShortcut(PreferencesWindowController.voiceShortcut)
        updateShortcutWarning()
        customPrompts = UserStyleModel.shared.customPrompts
        promptTableView?.reloadData()
        dojoEntries = DojoCorrectionTable.shared.allEntries
        dojoModeSwitch?.state = PreferencesWindowController.dojoMode ? .on : .off
        dojoTableView?.reloadData()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAlert(_ msg: String, info: String) {
        let a = NSAlert()
        a.messageText = msg
        a.informativeText = info
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        voiceRecorder?.cancelRecordingIfActive()
    }

    /// If the window loses key status mid-recording (user clicks another app, Cmd-Tabs
    /// away, etc.) without pressing a key or Esc, cancel it — otherwise the global
    /// CGEventTap stays bypassed (see cancelRecordingIfActive doc) with no way for the
    /// user to notice, since the window that would show "按下快捷鍵..." isn't even visible.
    func windowDidResignKey(_ notification: Notification) {
        voiceRecorder?.cancelRecordingIfActive()
    }

    // MARK: - NSTabViewDelegate
    /// Keeps PillTabBar's highlighted segment in sync regardless of *how* the
    /// tab changed — PillTabBar and NSTabView are two independent pieces of
    /// selection state (custom control driving a borderless native tab view),
    /// so anything that calls `tabView.selectTabViewItem` directly (not just
    /// clicks on the pill bar) needs this to avoid the two disagreeing.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let item = tabViewItem, let idx = tabView.tabViewItems.firstIndex(of: item) else { return }
        pillTabBar?.select(idx)
    }
}

// MARK: - TableView DataSource + Delegate
extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === dojoTableView { return dojoEntries.count }
        return customPrompts.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor col: NSTableColumn?, row: Int) -> Any? {
        if tableView === dojoTableView {
            guard row < dojoEntries.count else { return nil }
            let e = dojoEntries[row]
            switch col?.identifier.rawValue {
            case "wrong":    return e.wrong
            case "correct":  return e.correct
            case "tier":     return e.tier == "dojoOnly" ? "限道場模式" : "一律套用"
            case "phonetic": return e.phonetic ? "✓" : ""
            default:         return nil
            }
        }
        let p = customPrompts[row]
        switch col?.identifier.rawValue {
        case "emoji":  return p.emoji
        case "name":   return p.name
        case "prompt": return p.prompt
        default:       return nil
        }
    }
}
