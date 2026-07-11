import AppKit

/// Preferences window with four tabs:
/// 1. API Keys  2. Voice & Shortcuts  3. Custom AI Modes  4. Dojo Vocabulary
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

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
    // API Keys tab
    private var serviceSegment: NSSegmentedControl!
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
    private var dojoModeCheckbox: NSButton!

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

        let titleLabel = NSTextField(labelWithString: "Input-sa")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        let subtitleLabel = NSTextField(labelWithString: "語音轉錄 · 文字潤飾 · AI 強化")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
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
        tabView.addTabViewItem(makeAPIKeysTab())
        tabView.addTabViewItem(makeVoiceTab())
        tabView.addTabViewItem(makeCustomModesTab())
        tabView.addTabViewItem(makeDojoTab())

        let mainStack = NSStackView(views: [bannerStack, separator, tabView])
        mainStack.orientation = .vertical
        mainStack.spacing = 0

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

        // ── Section header helper ─────────────────────────────
        func sectionHeader(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        // ── 目前使用：狀態列（一眼看出主力是哪個服務）─────────
        providerStatusBox = NSBox()
        providerStatusBox.boxType = .custom
        providerStatusBox.cornerRadius = 8
        providerStatusBox.borderWidth = 1

        providerStatusLabel = NSTextField(wrappingLabelWithString: "")
        providerStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        providerStatusLabel.isSelectable = false
        providerStatusLabel.preferredMaxLayoutWidth = 440

        let statusStack = NSStackView(views: [providerStatusLabel])
        statusStack.orientation = .horizontal
        statusStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        providerStatusBox.contentView = statusStack
        // See defaultBox in makeVoiceTab() for why an explicit height (not hugging
        // priority) is required — NSBox has no intrinsic size to hug to.
        providerStatusBox.translatesAutoresizingMaskIntoConstraints = false
        providerStatusBox.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // ── 語音轉錄服務：service selector (segmented control) ─
        let transcribeHeader = sectionHeader("語音轉錄服務")

        serviceSegment = NSSegmentedControl(
            labels: ["Groq Whisper", "Google STT（含台語）", "本地 Paraformer"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(serviceProviderChanged)
        )
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   serviceSegment.selectedSegment = 0
        case .google: serviceSegment.selectedSegment = 1
        case .sherpa: serviceSegment.selectedSegment = 2
        }

        let serviceHint = NSTextField(wrappingLabelWithString:
            "Groq：免費，繁體中文  ·  Google STT：60 分鐘 / 月免費，支援國語 + 台語混合  ·  本地 Paraformer：完全離線、免 API Key、免飛航模式也能用，含道場詞庫糾正。\n" +
            "點選上方切換使用的服務；未選取的服務其 API Key 仍會保留在 Keychain，隨時可切回。")
        serviceHint.font = NSFont.systemFont(ofSize: 10)
        serviceHint.textColor = .secondaryLabelColor
        serviceHint.preferredMaxLayoutWidth = 440

        // ── Groq section ──────────────────────────────────────
        let groqLabel = NSTextField(labelWithString: "Groq API Key")
        groqField = NSTextField()
        groqField.placeholderString = "gsk_..."
        groqField.stringValue = APIKeyStore.shared.groqKey
        groqField.isEditable = true
        groqField.isSelectable = true
        let groqLink = makeLinkButton(title: "前往 Groq Console 取得 →",
                                      url: "https://console.groq.com/keys")

        let groqGrid = NSGridView(views: [
            [groqLabel, groqField],
            [NSView(),  groqLink],
        ])
        groqGrid.rowSpacing = 4
        groqGrid.columnSpacing = 8
        groqGrid.column(at: 0).xPlacement = .trailing
        groqGrid.column(at: 1).width = 280

        groqSection = groqGrid

        // ── Google STT section ────────────────────────────────
        let googleLabel = NSTextField(labelWithString: "Google API Key")
        googleSttField = NSTextField()
        googleSttField.placeholderString = "AIzaSy..."
        googleSttField.stringValue = APIKeyStore.shared.googleSttKey
        googleSttField.isEditable = true
        googleSttField.isSelectable = true
        let googleLink = makeLinkButton(title: "前往 GCP Console 取得 →",
                                        url: "https://console.cloud.google.com/apis/credentials")

        let googleNote = NSTextField(labelWithString: "需啟用 Cloud Speech-to-Text API")
        googleNote.font = NSFont.systemFont(ofSize: 10)
        googleNote.textColor = .secondaryLabelColor

        let googleGrid = NSGridView(views: [
            [googleLabel, googleSttField],
            [NSView(),    googleLink],
            [NSView(),    googleNote],
        ])
        googleGrid.rowSpacing = 4
        googleGrid.columnSpacing = 8
        googleGrid.column(at: 0).xPlacement = .trailing
        googleGrid.column(at: 1).width = 280

        googleSection = googleGrid

        // ── Separator ─────────────────────────────────────────
        let sep = NSBox()
        sep.boxType = .separator

        // ── AI 潤飾服務：Gemini ───────────────────────────────
        let geminiHeader = sectionHeader("AI 潤飾服務")

        let geminiLabel = NSTextField(labelWithString: "Gemini API Key")
        geminiField = NSTextField()
        geminiField.placeholderString = "AIzaSy..."
        geminiField.stringValue = APIKeyStore.shared.geminiKey
        geminiField.isEditable = true
        geminiField.isSelectable = true
        let geminiLink = makeLinkButton(title: "前往 AI Studio 取得 →",
                                        url: "https://aistudio.google.com/app/apikey")

        let geminiGrid = NSGridView(views: [
            [geminiLabel, geminiField],
            [NSView(),    geminiLink],
        ])
        geminiGrid.rowSpacing = 4
        geminiGrid.columnSpacing = 8
        geminiGrid.column(at: 0).xPlacement = .trailing
        geminiGrid.column(at: 1).width = 280

        // ── Save button ───────────────────────────────────────
        let saveBtn = NSButton(title: "儲存設定", target: self, action: #selector(saveAPIKeys))
        saveBtn.bezelStyle = .rounded

        let noteLabel = NSTextField(wrappingLabelWithString:
            "API Key 安全地儲存在系統 Keychain 中。Gemini 為選填，未設定時跳過 AI 潤飾步驟。")
        noteLabel.font = NSFont.systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor

        // ── Assemble ──────────────────────────────────────────
        let stack = NSStackView(views: [
            providerStatusBox,
            transcribeHeader,
            serviceSegment,
            serviceHint,
            groqSection,
            googleSection,
            sep,
            geminiHeader,
            geminiGrid,
            saveBtn,
            noteLabel,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        updateServiceSectionVisibility()
        updateProviderStatus()

        item.view = stack
        return item
    }

    @objc private func serviceProviderChanged() {
        let provider: APIKeyStore.VoiceProvider
        switch serviceSegment.selectedSegment {
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
        providerStatusLabel.textColor = tint
        providerStatusBox.fillColor = tint.withAlphaComponent(0.08)
        providerStatusBox.borderColor = tint.withAlphaComponent(0.3)
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
        btn.font = NSFont.systemFont(ofSize: 11)
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
        let defaultBox = NSBox()
        defaultBox.boxType = .custom
        defaultBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        defaultBox.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3)
        defaultBox.cornerRadius = 8
        defaultBox.borderWidth = 1

        let defaultLabel = NSTextField(labelWithString: "🎙  長按右 ⌥ 說話 → 轉錄輸出　　🌐  長按右 ⌘ 說中文 → 翻譯輸出")
        defaultLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        defaultLabel.isSelectable = false

        let defaultStack = NSStackView(views: [defaultLabel])
        defaultStack.orientation = .horizontal
        defaultStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        defaultBox.contentView = defaultStack
        // NSBox (boxType: .custom) has NO intrinsic content size at all — not "low
        // priority", genuinely undefined. Content-hugging priority has nothing to hug to,
        // so in a vertical NSStackView with slack space it stretches arbitrarily (label
        // ends up pinned near the bottom of a tall empty box). Needs an explicit height.
        defaultBox.translatesAutoresizingMaskIntoConstraints = false
        defaultBox.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // ── Custom shortcut (optional override) ─────────────
        let overrideHeader = NSTextField(labelWithString: "自訂快捷鍵（選填）")
        overrideHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        overrideHeader.textColor = .secondaryLabelColor

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
        overrideHint.font = NSFont.systemFont(ofSize: 10)
        overrideHint.textColor = .secondaryLabelColor

        // Only visible when the saved shortcut has zero modifiers — that key will fire
        // system-wide on every matching keystroke, including normal typing in any app.
        shortcutWarningLabel = NSTextField(wrappingLabelWithString:
            "⚠️ 這是不含修飾鍵的單一按鍵，日常打字打到這個鍵時也會觸發語音錄音，請確認這是你要的。")
        shortcutWarningLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        shortcutWarningLabel.textColor = .systemOrange
        shortcutWarningLabel.isHidden = true

        let overrideGrid = NSGridView(views: [
            [NSTextField(labelWithString: "快捷鍵"),       recorderRow],
            [NSTextField(labelWithString: "翻譯目標語言"), makeTranslatePopUp()],
            [NSTextField(labelWithString: "HUD 神佛角色"), makeCharacterPopUp()],
        ])
        overrideGrid.rowSpacing = 8
        overrideGrid.columnSpacing = 8
        overrideGrid.column(at: 0).xPlacement = .trailing

        // ── Usage hint ───────────────────────────────────────
        let sep = NSBox(); sep.boxType = .separator

        let hintLabel = NSTextField(wrappingLabelWithString: """
            語音輸入流程：錄音結束 → 自動轉錄 → AI 潤飾 → 輸出至游標位置。
            若 Gemini API Key 未設定，轉錄結果直接輸出（不經潤飾）。
            語音翻譯（兩種用法擇一）：
            　• 說話結尾直接講「請幫我翻譯成英文」（日文/泰文…皆可，免記快捷鍵）
            　• 或長按右 ⌘ 說中文，放開後翻譯成上方目標語言（需 Gemini API Key）。
            錄音中若按下其他按鍵（右⌘＋C 等組合鍵），翻譯錄音自動取消、組合鍵照常生效。
            文字潤飾快捷鍵：選取文字後按 Ctrl+Option+P（同偏好設定）。
            """)
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            defaultBox,
            overrideHeader,
            overrideGrid,
            overrideHint,
            shortcutWarningLabel,
            sep,
            hintLabel,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

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

    private func makeTranslatePopUp() -> NSPopUpButton {
        translatePopUp = NSPopUpButton()
        translatePopUp.addItems(withTitles: ["英文", "泰文"])
        let saved = TranscriptionMode.translateTargetLanguage
        if let idx = ["英文", "泰文"].firstIndex(of: saved) {
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
        promptTableView.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = promptTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 464),
            scroll.heightAnchor.constraint(equalToConstant: 220),
        ])

        let addBtn = NSButton(title: "+ 新增", target: self, action: #selector(addCustomPrompt))
        let delBtn = NSButton(title: "刪除選取", target: self, action: #selector(deleteCustomPrompt))
        addBtn.bezelStyle = .rounded; delBtn.bezelStyle = .rounded
        let btnBar = NSStackView(views: [addBtn, delBtn, NSView()])
        btnBar.orientation = .horizontal; btnBar.spacing = 6

        customPrompts = UserStyleModel.shared.customPrompts

        let hintLabel = NSTextField(wrappingLabelWithString:
            "語音轉錄完成後，可在此新增自訂 AI 指令模式，供後續輸出時套用。")
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 464

        let stack = NSStackView(views: [scroll, btnBar, hintLabel])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        item.view = stack
        return item
    }

    @objc private func addCustomPrompt() {
        let alert = NSAlert()
        alert.messageText = "新增自訂模式"
        alert.addButton(withTitle: "新增")
        alert.addButton(withTitle: "取消")

        let emojiField  = NSTextField(frame: NSRect(x: 0, y: 76, width: 200, height: 22))
        emojiField.placeholderString = "Emoji（如 📱）"
        let nameField   = NSTextField(frame: NSRect(x: 0, y: 50, width: 200, height: 22))
        nameField.placeholderString = "模式名稱（如 IG 貼文）"
        let promptField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 46))
        promptField.placeholderString = "AI 指令（如：請改寫成 IG 貼文風格...）"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        container.addSubview(emojiField)
        container.addSubview(nameField)
        container.addSubview(promptField)
        alert.accessoryView = container

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

        dojoModeCheckbox = NSButton(
            checkboxWithTitle: "道場模式（套用「限道場模式」規則）",
            target: self, action: #selector(dojoModeChanged)
        )
        dojoModeCheckbox.state = PreferencesWindowController.dojoMode ? .on : .off

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
        dojoTableView.usesAlternatingRowBackgroundColors = true
        dojoTableView.target = self
        dojoTableView.doubleAction = #selector(editDojoEntry)

        let scroll = NSScrollView()
        scroll.documentView = dojoTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 464),
            scroll.heightAnchor.constraint(equalToConstant: 260),
        ])

        let addBtn = NSButton(title: "+ 新增", target: self, action: #selector(addDojoEntry))
        let editBtn = NSButton(title: "編輯選取", target: self, action: #selector(editDojoEntry))
        let delBtn = NSButton(title: "刪除選取", target: self, action: #selector(deleteDojoEntry))
        addBtn.bezelStyle = .rounded; editBtn.bezelStyle = .rounded; delBtn.bezelStyle = .rounded
        let btnBar = NSStackView(views: [addBtn, editBtn, delBtn, NSView()])
        btnBar.orientation = .horizontal; btnBar.spacing = 6

        dojoEntries = DojoCorrectionTable.shared.allEntries

        let hintLabel = NSTextField(wrappingLabelWithString: """
            語音轉錄常聽錯的道場專有名詞（人名、聖號、術語），在此新增糾正規則。「一律套用」永遠生效；\
            「限道場模式」只在上方勾選開啟時生效，避免誤糾一般口語（如「半道而廢」）。\
            拼音糾正會自動比對所有同音變體（如妙吉大帝／妙急大帝皆會糾正為妙極大帝），通常不需關閉。
            """)
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 464

        let stack = NSStackView(views: [dojoModeCheckbox, scroll, btnBar, hintLabel])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        item.view = stack
        return item
    }

    @objc private func dojoModeChanged() {
        PreferencesWindowController.dojoMode = (dojoModeCheckbox.state == .on)
    }

    /// Shared add/edit modal. `editingIndex == nil` means "add new".
    private func presentDojoEntryEditor(editingIndex: Int?) {
        let existing = editingIndex.map { dojoEntries[$0] }

        let alert = NSAlert()
        alert.messageText = editingIndex == nil ? "新增道場詞條" : "編輯道場詞條"
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        let wrongField = NSTextField(frame: NSRect(x: 0, y: 112, width: 280, height: 22))
        wrongField.placeholderString = "常見誤辨（如：妙計大替）"
        wrongField.stringValue = existing?.wrong ?? ""

        let correctField = NSTextField(frame: NSRect(x: 0, y: 82, width: 280, height: 22))
        correctField.placeholderString = "正確詞（如：妙極大帝）"
        correctField.stringValue = existing?.correct ?? ""

        let tierPopUp = NSPopUpButton(frame: NSRect(x: 0, y: 46, width: 280, height: 26))
        tierPopUp.addItems(withTitles: ["一律套用", "限道場模式"])
        tierPopUp.selectItem(at: existing?.tier == "dojoOnly" ? 1 : 0)

        let phoneticCheckbox = NSButton(checkboxWithTitle: "同時套用拼音同音糾正", target: nil, action: nil)
        phoneticCheckbox.frame = NSRect(x: 0, y: 14, width: 280, height: 22)
        phoneticCheckbox.state = (existing?.phonetic ?? true) ? .on : .off

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 142))
        container.addSubview(wrongField)
        container.addSubview(correctField)
        container.addSubview(tierPopUp)
        container.addSubview(phoneticCheckbox)
        alert.accessoryView = container

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
        case .groq:   serviceSegment?.selectedSegment = 0
        case .google: serviceSegment?.selectedSegment = 1
        case .sherpa: serviceSegment?.selectedSegment = 2
        }
        updateServiceSectionVisibility()
        updateProviderStatus()
        voiceRecorder?.setShortcut(PreferencesWindowController.voiceShortcut)
        updateShortcutWarning()
        customPrompts = UserStyleModel.shared.customPrompts
        promptTableView?.reloadData()
        dojoEntries = DojoCorrectionTable.shared.allEntries
        dojoModeCheckbox?.state = PreferencesWindowController.dojoMode ? .on : .off
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
