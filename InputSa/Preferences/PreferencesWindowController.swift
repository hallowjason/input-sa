import AppKit

/// Preferences window with four tabs:
/// 1. API Keys  2. Voice & Shortcuts  3. Custom AI Modes  4. Dojo Vocabulary
final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate,
                                          NSTextFieldDelegate {

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
    private var polishProviderPicker: PillSegmentedControl!
    private var polishStatusLabel: NSTextField!
    private var polishStatusBox: NSBox!
    // Voice tab
    private var voiceRecorder: ShortcutRecorderView!
    private var translatePopUp: NSPopUpButton!
    private var shortcutWarningLabel: NSTextField!
    // Custom modes tab
    private var promptCardList: CardListView!
    private var customPrompts: [UserStyleModel.CustomPrompt] = []
    // Dojo vocabulary tab
    private var dojoCardList: CardListView!
    private var dojoEntries: [DojoCorrectionTable.Entry] = []
    private var dojoModeSwitch: NSSwitch!
    /// Non-nil while the 🎙 voice-add button is recording.
    private var voiceAddService: VoiceServiceProtocol?
    private var voiceAddButton: NSButton!

    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
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
        pillTabBar = PillTabBar(labels: ["語音服務", "快捷鍵", "自訂 AI 模式", "道場詞庫"])
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
        item.label = "語音服務"

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

        // Provider picker: Gemini (cloud) vs Apple on-device (offline).
        let initialPolishIdx = APIKeyStore.shared.polishProvider == .apple ? 1 : 0
        polishProviderPicker = PillSegmentedControl(
            labels: ["Gemini（雲端）", "Apple 本地"],
            selectedIndex: initialPolishIdx)
        polishProviderPicker.onSelect = { [weak self] idx in
            self?.polishProviderChanged(idx)
        }

        let polishBadge = DesignTokens.makeSolidBadge(text: "", fill: .systemBlue)
        polishStatusBox = polishBadge.box
        polishStatusLabel = polishBadge.label

        let polishHint = NSTextField(wrappingLabelWithString:
            "Gemini：雲端潤飾，品質最佳，需網路與 API Key  ·  Apple 本地：完全離線、免 API Key（需 macOS 26 + Apple Intelligence）。\n" +
            "翻譯（右 ⌘）與口頭修正固定使用 Gemini，不受此設定影響。")
        polishHint.font = DesignTokens.monoFont(10)
        polishHint.textColor = .secondaryLabelColor
        polishHint.preferredMaxLayoutWidth = 420

        [polishProviderPicker, polishStatusBox, polishHint].forEach {
            polishCard.contentStack.addArrangedSubview($0!)
        }
        polishStatusBox.widthAnchor.constraint(equalToConstant: 420).isActive = true

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

        // ── Auto-save (macOS preferences convention: no explicit save button;
        //    keys are written to Keychain the moment a field ends editing) ──
        [groqField, googleSttField, geminiField].forEach { $0.delegate = self }

        let noteLabel = NSTextField(wrappingLabelWithString:
            "API Key 修改後自動儲存至系統 Keychain。Gemini 為選填，未設定時跳過 AI 潤飾步驟。")
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
        updatePolishProviderStatus()

        item.view = stack
        return item
    }

    private func polishProviderChanged(_ selectedIndex: Int) {
        let wantApple = (selectedIndex == 1)
        // Transparent fallback: if the user taps Apple but the on-device model
        // isn't available on this machine, keep Gemini as the effective provider
        // and explain why in the badge — never silently persist a provider that
        // will just fail at dictation time. (Runtime failures of an available
        // Apple model fall back to the raw transcript, never a silent cloud call.)
        if wantApple, ApplePolishService.availabilityStatus.isAvailable {
            APIKeyStore.shared.polishProvider = .apple
        } else {
            APIKeyStore.shared.polishProvider = .gemini
        }
        updatePolishProviderStatus(requestedApple: wantApple)
    }

    /// Keeps the "AI 潤飾服務" status badge in sync: green when Apple local is
    /// active, blue for Gemini cloud, orange when the user picked Apple but it
    /// isn't available (with the plain-language reason).
    private func updatePolishProviderStatus(requestedApple: Bool? = nil) {
        let provider = APIKeyStore.shared.polishProvider
        let apple = ApplePolishService.availabilityStatus
        let wantApple = requestedApple ?? (provider == .apple)
        let (icon, text, tint): (String, String, NSColor)
        if wantApple && !apple.isAvailable {
            (icon, text, tint) = ("⚠️", "Apple 本地無法使用：\(apple.reason)。目前改用 Gemini（雲端）", .systemOrange)
        } else if provider == .apple {
            (icon, text, tint) = ("💻", "目前使用：Apple 本地 — 完全離線運算，不呼叫任何雲端 API", .systemGreen)
        } else {
            (icon, text, tint) = ("🌐", "目前使用：Gemini（雲端）— 需要網路連線", .systemBlue)
        }
        polishStatusLabel.stringValue = "\(icon)  \(text)"
        polishStatusBox.fillColor = tint
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

    /// Persist whatever is currently in the key fields — called on field
    /// end-editing and as a safety net when the window closes, so an edited
    /// key can't be silently lost by just closing the window.
    private func saveAPIKeys() {
        guard groqField != nil else { return }
        APIKeyStore.shared.groqKey      = groqField.stringValue
        APIKeyStore.shared.geminiKey    = geminiField.stringValue
        APIKeyStore.shared.googleSttKey = googleSttField.stringValue
    }

    // NSTextFieldDelegate — auto-save keys the moment a field ends editing.
    func controlTextDidEndEditing(_ obj: Notification) {
        saveAPIKeys()
    }

    // MARK: - Tab 2: Voice & Shortcuts
    private func makeVoiceTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "快捷鍵"

        // ── Shortcut overview: key-cap pill + one-line description per row,
        //    replacing the old seven-line footnote text wall ─────────────
        let overviewCard = DesignTokens.makeSectionCard(title: "快捷鍵總覽")
        let shortcutRows: [(key: String, desc: String)] = [
            ("右 ⌥ 長按", "說話 → 轉錄 → AI 潤飾 → 輸出至游標（未設 Gemini Key 時直接輸出轉錄）"),
            ("右 ⌘ 長按", "說中文 → 翻譯成目標語言輸出（錄音中按其他組合鍵自動取消）"),
            ("右 ⇧ 長按", "口頭修正：說「崇正寶宮的崇是崇高的崇…」→ Enter 確認加入道場詞庫"),
            ("⌥ P",      "選取文字後按 → AI 潤飾預覽（Enter 接受／Esc 取消）"),
            ("⌃ ⌥ P",    "開啟本偏好設定視窗"),
        ]
        for row in shortcutRows {
            let keyCap = BadgePill(text: row.key, fill: NSColor(calibratedWhite: 0.13, alpha: 1.0),
                                   textColor: .white, fontSize: 11, height: 24)
            let descLabel = NSTextField(wrappingLabelWithString: row.desc)
            descLabel.font = DesignTokens.monoFont(10)
            descLabel.textColor = .secondaryLabelColor
            descLabel.preferredMaxLayoutWidth = 320
            let rowStack = NSStackView(views: [keyCap, descLabel])
            rowStack.orientation = .horizontal
            rowStack.spacing = DesignTokens.Spacing.item
            rowStack.alignment = .centerY
            overviewCard.contentStack.addArrangedSubview(rowStack)
        }

        // ── Custom shortcut (optional override) ─────────────
        let shortcutCard = DesignTokens.makeSectionCard(title: "自訂聽寫快捷鍵（選填）")

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
        langLabel.font = DesignTokens.monoFont(12)

        let overrideGrid = DesignTokens.makeFieldGrid([
            [langLabel, recorderRow],
        ])
        shortcutCard.contentStack.addArrangedSubview(overrideGrid)
        shortcutCard.contentStack.addArrangedSubview(overrideHint)
        shortcutCard.contentStack.addArrangedSubview(shortcutWarningLabel)

        // ── Appearance & language (not shortcuts — grouped separately) ──
        let appearanceCard = DesignTokens.makeSectionCard(title: "外觀與語言")
        let translateLabel = NSTextField(labelWithString: "翻譯目標語言")
        let characterLabel = NSTextField(labelWithString: "HUD 神佛角色")
        [translateLabel, characterLabel].forEach { $0.font = DesignTokens.monoFont(12) }
        let appearanceGrid = DesignTokens.makeFieldGrid([
            [translateLabel, makeTranslatePopUp()],
            [characterLabel, makeCharacterPopUp()],
        ])
        appearanceCard.contentStack.addArrangedSubview(appearanceGrid)

        // Trailing flex spacer — see the matching comment in makeAPIKeysTab().
        let stack = NSStackView(views: [
            overviewCard.box,
            shortcutCard.box,
            appearanceCard.box,
            NSView(),
        ])
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        [overviewCard.box, shortcutCard.box, appearanceCard.box].forEach {
            $0.widthAnchor.constraint(equalToConstant: 456).isActive = true
        }

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

        let addBtn = DesignTokens.makeSolidButton(
            title: "＋ 新增模式", target: self, action: #selector(addCustomPrompt))
        let headerRow = NSStackView(views: [addBtn, NSView()])
        headerRow.orientation = .horizontal

        promptCardList = CardListView(height: 268)
        promptCardList.emptyStateText = "尚無自訂模式 — 點上方「＋ 新增模式」建立"
        promptCardList.onEdit = { [weak self] idx in self?.editCustomPrompt(at: idx) }
        promptCardList.onDelete = { [weak self] idx in self?.deleteCustomPrompt(at: idx) }

        customPrompts = UserStyleModel.shared.customPrompts

        let hintLabel = NSTextField(wrappingLabelWithString:
            "在選單列「AI 模式」選定後，聽寫潤飾與選字潤飾（Option+P）都會套用該模式。")
        hintLabel.font = DesignTokens.monoFont(10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 456

        let stack = NSStackView(views: [headerRow, promptCardList, hintLabel, NSView()])  // trailing spacer, see makeAPIKeysTab()
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        [headerRow, promptCardList].forEach {
            ($0 as NSView).widthAnchor.constraint(equalToConstant: 456).isActive = true
        }

        reloadPromptCards()

        item.view = stack
        return item
    }

    private func reloadPromptCards() {
        customPrompts = UserStyleModel.shared.customPrompts
        let rows = customPrompts.map { p -> CardListView.Row in
            let title = NSAttributedString(string: p.name, attributes: [
                .font: DesignTokens.monoFont(13, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
            return CardListView.Row(
                iconText: p.emoji,
                iconFill: NSColor(calibratedWhite: 0.13, alpha: 1.0),
                title: title,
                subtitle: p.prompt,
                badges: [])
        }
        promptCardList?.reload(rows: rows)
    }

    @objc private func addCustomPrompt() {
        guard let window else { return }
        PromptEntrySheet.present(on: window, title: "新增自訂模式", initial: nil) { [weak self] entry in
            guard let entry else { return }
            UserStyleModel.shared.addCustomPrompt(entry)
            self?.reloadPromptCards()
        }
    }

    private func editCustomPrompt(at index: Int) {
        guard let window, index < customPrompts.count else { return }
        PromptEntrySheet.present(on: window, title: "編輯自訂模式",
                                 initial: customPrompts[index]) { [weak self] entry in
            guard let entry else { return }
            UserStyleModel.shared.updateCustomPrompt(entry)
            self?.reloadPromptCards()
        }
    }

    private func deleteCustomPrompt(at index: Int) {
        guard index < customPrompts.count else { return }
        UserStyleModel.shared.removeCustomPrompt(id: customPrompts[index].id)
        reloadPromptCards()
    }

    // MARK: - Tab 4: Dojo Vocabulary
    private func makeDojoTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "道場詞庫"

        dojoModeSwitch = NSSwitch()
        dojoModeSwitch.state = PreferencesWindowController.dojoMode ? .on : .off
        dojoModeSwitch.target = self
        dojoModeSwitch.action = #selector(dojoModeChanged)

        // Short label — the tier explanation lives in the hint below; the full
        // sentence here pushed the header row past its 456pt width and clipped
        // the switch off the window's left edge.
        let dojoModeLabel = NSTextField(labelWithString: "道場模式")
        dojoModeLabel.font = DesignTokens.monoFont(12)

        let dojoModeRow = NSStackView(views: [dojoModeSwitch, dojoModeLabel])
        dojoModeRow.orientation = .horizontal
        dojoModeRow.spacing = DesignTokens.Spacing.compact
        dojoModeRow.alignment = .centerY

        let addBtn = DesignTokens.makeSolidButton(
            title: "＋ 新增詞條", target: self, action: #selector(addDojoEntry))
        voiceAddButton = DesignTokens.makeSolidButton(
            title: "🎙 用說的新增", target: self, action: #selector(toggleVoiceAdd),
            fill: NSColor(calibratedWhite: 0.13, alpha: 1.0), textColor: .white)
        let headerRow = NSStackView(views: [dojoModeRow, NSView(), voiceAddButton, addBtn])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = DesignTokens.Spacing.compact

        dojoCardList = CardListView(height: 258)
        dojoCardList.emptyStateText = "尚無詞條 — 點右上「＋ 新增詞條」建立"
        dojoCardList.onEdit = { [weak self] idx in self?.editDojoEntry(at: idx) }
        dojoCardList.onDelete = { [weak self] idx in self?.deleteDojoEntry(at: idx) }

        dojoEntries = DojoCorrectionTable.shared.allEntries

        let hintLabel = NSTextField(wrappingLabelWithString: """
            語音轉錄常聽錯的道場專有名詞在此糾正。金色徽章＝永遠生效；灰色徽章＝只在道場模式開啟時生效，\
            避免誤糾一般口語。「同音」表示所有同音變體都會比對（妙吉／妙急大帝 → 妙極大帝）。
            """)
        hintLabel.font = DesignTokens.monoFont(10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 456

        let stack = NSStackView(views: [headerRow, dojoCardList, hintLabel, NSView()])  // trailing spacer, see makeAPIKeysTab()
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Spacing.card
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.section, left: DesignTokens.Spacing.section,
            bottom: DesignTokens.Spacing.section, right: DesignTokens.Spacing.section)
        [headerRow, dojoCardList].forEach {
            ($0 as NSView).widthAnchor.constraint(equalToConstant: 456).isActive = true
        }

        reloadDojoCards()

        item.view = stack
        return item
    }

    private func reloadDojoCards() {
        dojoEntries = DojoCorrectionTable.shared.allEntries
        let rows = dojoEntries.map { e -> CardListView.Row in
            let isAlways = e.tier != "dojoOnly"
            let title = NSMutableAttributedString()
            if e.wrong != e.correct {
                title.append(NSAttributedString(string: "\(e.wrong) → ", attributes: [
                    .font: DesignTokens.monoFont(12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            title.append(NSAttributedString(string: e.correct, attributes: [
                .font: DesignTokens.monoFont(13, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]))
            var badges: [(String, NSColor, NSColor)] = [
                isAlways ? ("一律套用", DesignTokens.accentGold, NSColor.black)
                         : ("限道場", NSColor.systemGray, NSColor.white)
            ]
            if e.phonetic {
                badges.append(("同音", NSColor.systemBlue.withAlphaComponent(0.85), NSColor.white))
            }
            return CardListView.Row(
                iconText: String(e.correct.prefix(1)),
                iconFill: isAlways ? DesignTokens.accentGold : NSColor.systemGray,
                title: title,
                subtitle: "",
                badges: badges.map { (text: $0.0, fill: $0.1, textColor: $0.2) })
        }
        dojoCardList?.reload(rows: rows)
    }

    @objc private func dojoModeChanged() {
        PreferencesWindowController.dojoMode = (dojoModeSwitch.state == .on)
    }

    // MARK: - 口頭修正 (voice-add from Preferences)
    /// Same parse pipeline as the global right-Shift PTT, but the result
    /// prefills the editor sheet for review instead of a HUD Enter/Esc.
    @objc private func toggleVoiceAdd() {
        if let service = voiceAddService {
            // Second click: stop → transcribe → parse → prefill editor.
            voiceAddService = nil
            voiceAddButton.isEnabled = false
            voiceAddButton.attributedTitle = DesignTokens.solidButtonTitle("解析中…", textColor: .white)
            service.stopAndTranscribe { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .failure(let err):
                        self.resetVoiceAddButton()
                        self.showAlert("轉錄失敗", info: err.localizedDescription)
                    case .success(let transcript):
                        DojoVoiceParser.parse(transcript: transcript) { parseResult in
                            self.resetVoiceAddButton()
                            switch parseResult {
                            case .failure(let err):
                                self.showAlert("解析失敗", info: err.localizedDescription)
                            case .success(let entry):
                                guard let window = self.window else { return }
                                DojoEntrySheet.present(on: window, title: "確認口頭修正詞條",
                                                       initial: entry) { [weak self] confirmed in
                                    guard let self, let confirmed else { return }
                                    var updated = self.dojoEntries
                                    updated.append(confirmed)
                                    self.applyDojoEntries(updated, failureMessage: "儲存失敗")
                                }
                            }
                        }
                    }
                }
            }
        } else {
            guard !APIKeyStore.shared.geminiKey.isEmpty else {
                showAlert("需要 Gemini API Key", info: "口頭修正靠 Gemini 解析你說的釋義，請先在「語音服務」分頁填入。")
                return
            }
            let service: VoiceServiceProtocol
            switch APIKeyStore.shared.voiceProvider {
            case .groq:   service = GroqVoiceService()
            case .google: service = GoogleVoiceService()
            case .sherpa: service = SherpaVoiceService()
            }
            voiceAddService = service
            service.startRecording()
            voiceAddButton.attributedTitle = DesignTokens.solidButtonTitle("⏹ 停止並解析", textColor: .white)
        }
    }

    private func resetVoiceAddButton() {
        voiceAddButton.isEnabled = true
        voiceAddButton.attributedTitle = DesignTokens.solidButtonTitle("🎙 用說的新增", textColor: .white)
    }

    @objc private func addDojoEntry() {
        guard let window else { return }
        DojoEntrySheet.present(on: window, title: "新增道場詞條", initial: nil) { [weak self] entry in
            guard let self, let entry else { return }
            var updated = self.dojoEntries
            updated.append(entry)
            self.applyDojoEntries(updated, failureMessage: "儲存失敗")
        }
    }

    private func editDojoEntry(at index: Int) {
        guard let window, index < dojoEntries.count else { return }
        DojoEntrySheet.present(on: window, title: "編輯道場詞條",
                               initial: dojoEntries[index]) { [weak self] entry in
            guard let self, let entry else { return }
            var updated = self.dojoEntries
            updated[index] = entry
            self.applyDojoEntries(updated, failureMessage: "儲存失敗")
        }
    }

    private func deleteDojoEntry(at index: Int) {
        guard index < dojoEntries.count else { return }
        var updated = dojoEntries
        updated.remove(at: index)
        applyDojoEntries(updated, failureMessage: "刪除失敗")
    }

    /// Persist `updated` to `DojoCorrectionTable` and refresh the card list.
    /// On write failure, the in-memory table/UI are left untouched and an alert shown.
    private func applyDojoEntries(_ updated: [DojoCorrectionTable.Entry], failureMessage: String) {
        if DojoCorrectionTable.shared.save(updated) {
            reloadDojoCards()
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
        polishProviderPicker?.select(APIKeyStore.shared.polishProvider == .apple ? 1 : 0)
        updateServiceSectionVisibility()
        updateProviderStatus()
        updatePolishProviderStatus()
        voiceRecorder?.setShortcut(PreferencesWindowController.voiceShortcut)
        updateShortcutWarning()
        reloadPromptCards()
        dojoModeSwitch?.state = PreferencesWindowController.dojoMode ? .on : .off
        reloadDojoCards()
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
        saveAPIKeys()   // safety net: a field still mid-edit hasn't fired end-editing yet
        if let service = voiceAddService {   // 🎙 voice-add still recording
            service.cancelRecording()
            voiceAddService = nil
            resetVoiceAddButton()
        }
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
