import AppKit

/// 語音服務 pane — transcription provider + AI polish provider + API keys +
/// community nickname. Same control tree and data flow as always; the
/// 2026-07-16 v3 redesign changed only the visual container language:
/// System Settings grouped cards (status row, popup row, field rows with
/// hairline separators) instead of flat typographic groups, and native
/// NSPopUpButtons instead of the hand-drawn pill segmented control.
extension PreferencesWindowController {

    func makeVoiceServiceContent() -> NSView {
        // ── Group 1: 語音轉錄服務 ──────────────────────────────
        let status = DesignTokens.statusRow(caption: "目前使用",
                                            value: "", dot: DesignTokens.Palette.statusOK)
        providerStatusCaption = status.captionLabel
        providerStatusLabel = status.valueLabel
        providerStatusDot = status.dotView

        let initialProviderIdx: Int
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   initialProviderIdx = 0
        case .google: initialProviderIdx = 1
        case .sherpa: initialProviderIdx = 2
        }
        providerPicker = DesignTokens.popup(
            items: ["Groq Whisper", "Google STT（含台語）", "本地 Paraformer"],
            selectedIndex: initialProviderIdx,
            target: self, action: #selector(providerPopupChanged(_:)))

        // ── Groq section (conditional rows own their leading hairline) ──
        groqField = makeKeyField(placeholder: "gsk_...")
        groqSection = conditionalSection(rows: [
            DesignTokens.row(title: "Groq API Key", control: groqField),
            trailingLinkRow(note: nil,
                            link: makeLinkButton(title: "前往 Groq Console 取得 ↗",
                                                 url: "https://console.groq.com/keys")),
        ])

        // ── Google STT section ────────────────────────────────
        googleSttField = makeKeyField(placeholder: "AIzaSy...")
        googleSection = conditionalSection(rows: [
            DesignTokens.row(title: "Google API Key", control: googleSttField),
            trailingLinkRow(note: "需啟用 Cloud Speech-to-Text API",
                            link: makeLinkButton(title: "前往 GCP Console 取得 ↗",
                                                 url: "https://console.cloud.google.com/apis/credentials")),
        ])

        let transcribeCard = DesignTokens.groupCard([
            status.row,
            DesignTokens.hairline(),
            DesignTokens.row(title: "服務", control: providerPicker),
            groqSection,
            googleSection,
        ], autoSeparators: false)

        let serviceHint = DesignTokens.caption(
            "Groq 免費、繁體中文最穩 · Google STT 每月 60 分鐘免費、支援國語＋台語 · " +
            "本地 Paraformer 完全離線、免 API Key。未選取服務的 Key 仍保留在 Keychain，隨時可切回。")

        // ── Group 2: AI 潤飾服務 ────────────────────────────────
        let polishStatus = DesignTokens.statusRow(caption: "目前使用",
                                                  value: "", dot: DesignTokens.Palette.statusOK)
        polishStatusCaption = polishStatus.captionLabel
        polishStatusLabel = polishStatus.valueLabel
        polishStatusDot = polishStatus.dotView

        let initialPolishIdx = APIKeyStore.shared.polishProvider == .apple ? 1 : 0
        polishProviderPicker = DesignTokens.popup(
            items: ["Gemini（雲端）", "Apple 本地"],
            selectedIndex: initialPolishIdx,
            target: self, action: #selector(polishPopupChanged(_:)))

        geminiField = makeKeyField(placeholder: "AIzaSy...")

        let polishCard = DesignTokens.groupCard([
            polishStatus.row,
            DesignTokens.hairline(),
            DesignTokens.row(title: "服務", control: polishProviderPicker),
            conditionalSection(rows: [   // not conditional, but reuses the hairline wrapper
                DesignTokens.row(title: "Gemini API Key", control: geminiField),
                trailingLinkRow(note: nil,
                                link: makeLinkButton(title: "前往 AI Studio 取得 ↗",
                                                     url: "https://aistudio.google.com/app/apikey")),
            ]),
        ], autoSeparators: false)

        let polishHint = DesignTokens.caption(
            "Gemini 品質最佳，需網路與 API Key · Apple 本地完全離線、免 Key（需 macOS 26 ＋ " +
            "Apple Intelligence）。翻譯（右 ⌘）與口頭修正固定使用 Gemini，不受此設定影響。")

        // ── Auto-save (macOS preferences convention: no explicit save button;
        //    keys are written to Keychain the moment a field ends editing) ──
        [groqField, googleSttField, geminiField].forEach { $0.delegate = self }

        // ── Group 3: 道場共編詞庫（community nickname）──────────
        communityNicknameField = NSTextField()
        communityNicknameField.placeholderString = "選填——分享詞條時附上的署名"
        communityNicknameField.font = DesignTokens.uiFont(12)
        communityNicknameField.stringValue =
            UserDefaults.standard.string(forKey: DojoSharedSync.nicknameKey) ?? ""
        communityNicknameField.isEditable = true
        communityNicknameField.isSelectable = true
        communityNicknameField.delegate = self   // auto-save on end-editing (same as key fields)
        communityNicknameField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let communityCard = DesignTokens.groupCard([
            DesignTokens.row(title: "共編暱稱", control: communityNicknameField),
        ])
        let communityHint = DesignTokens.caption(
            "App 啟動時自動同步道友共享的「已審核」詞條（帶「共編」標記、唯讀）。" +
            "口頭修正時可選擇分享自己的詞條；暱稱僅用於標示分享者，可留空。")

        let noteLabel = DesignTokens.caption(
            "API Key 修改後自動儲存至系統 Keychain。Gemini 為選填，未設定時跳過 AI 潤飾步驟。")

        // ── Assemble ──────────────────────────────────────────
        let stack = NSStackView(views: [
            DesignTokens.group(title: "語音轉錄服務", card: transcribeCard, footnote: serviceHint),
            DesignTokens.group(title: "AI 潤飾服務", card: polishCard, footnote: polishHint),
            DesignTokens.group(title: "道場共編詞庫", card: communityCard, footnote: communityHint),
            noteLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.section
        for group in stack.arrangedSubviews where !(group is NSTextField) {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        updateServiceSectionVisibility()
        updateProviderStatus()
        updatePolishProviderStatus()

        return stack
    }

    // MARK: - Row builders

    /// Mono API-key field, fixed trailing width.
    private func makeKeyField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = DesignTokens.monoFont(11)
        field.isEditable = true
        field.isSelectable = true
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return field
    }

    /// Wrapper for rows that hide/show together (provider API-key sections):
    /// brings its own leading hairline so hiding collapses the separator too.
    private func conditionalSection(rows: [NSView]) -> NSView {
        let stack = NSStackView(views: [DesignTokens.hairline()] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setContentHuggingPriority(.required, for: .vertical)
        return stack
    }

    /// Sub-row under a key field: optional muted note leading, link trailing.
    private func trailingLinkRow(note: String?, link: NSButton) -> NSView {
        var views: [NSView] = []
        if let note {
            let noteLabel = DesignTokens.styledLabel(
                note, size: 11, weight: .regular, kern: -0.1,
                color: DesignTokens.Palette.inkMuted(0.45))
            views.append(noteLabel)
        }
        views.append(NSView())
        views.append(link)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 10, right: 16)
        return row
    }

    // MARK: - Change handlers (same data flow as always)

    @objc private func providerPopupChanged(_ sender: NSPopUpButton) {
        serviceProviderChanged(sender.indexOfSelectedItem)
    }

    @objc private func polishPopupChanged(_ sender: NSPopUpButton) {
        polishProviderChanged(sender.indexOfSelectedItem)
    }

    private func polishProviderChanged(_ selectedIndex: Int) {
        let wantApple = (selectedIndex == 1)
        // Transparent fallback: if the user taps Apple but the on-device model
        // isn't available on this machine, keep Gemini as the effective provider
        // and explain why in the status row — never silently persist a provider
        // that will just fail at dictation time. (Runtime failures of an available
        // Apple model fall back to the raw transcript, never a silent cloud call.)
        if wantApple, ApplePolishService.availabilityStatus.isAvailable {
            APIKeyStore.shared.polishProvider = .apple
        } else {
            APIKeyStore.shared.polishProvider = .gemini
        }
        updatePolishProviderStatus(requestedApple: wantApple)
    }

    /// Keeps the "AI 潤飾服務" status row in sync: OK dot when the chosen
    /// provider is live, warn-orange when the user picked Apple but it isn't
    /// available (with the plain-language reason).
    func updatePolishProviderStatus(requestedApple: Bool? = nil) {
        let provider = APIKeyStore.shared.polishProvider
        let apple = ApplePolishService.availabilityStatus
        let wantApple = requestedApple ?? (provider == .apple)
        let (caption, value, dot): (String, String, NSColor)
        if wantApple && !apple.isAvailable {
            (caption, value, dot) = ("Apple 本地不可用：\(apple.reason)",
                                     "改用 Gemini（雲端）", DesignTokens.Palette.statusWarn)
        } else if provider == .apple {
            (caption, value, dot) = ("目前使用", "Apple 本地 · 完全離線",
                                     DesignTokens.Palette.statusOK)
        } else {
            (caption, value, dot) = ("目前使用", "Gemini（雲端）· 需網路",
                                     DesignTokens.Palette.statusOK)
        }
        setStatus(caption: polishStatusCaption, value: polishStatusLabel,
                  dotView: polishStatusDot, captionText: caption, valueText: value, dot: dot)
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

    /// Keeps the "目前使用" status row in sync with the active provider —
    /// the popup alone doesn't make it obvious which service is live vs.
    /// which API Keys are just kept around as a switchable fallback.
    func updateProviderStatus() {
        let value: String
        switch APIKeyStore.shared.voiceProvider {
        case .sherpa: value = "本地 Paraformer · 完全離線"
        case .groq:   value = "Groq Whisper（雲端）· 需網路"
        case .google: value = "Google STT（雲端）· 需網路"
        }
        setStatus(caption: providerStatusCaption, value: providerStatusLabel,
                  dotView: providerStatusDot, captionText: "目前使用", valueText: value,
                  dot: DesignTokens.Palette.statusOK)
    }

    /// Re-style a status row's caption/value/dot in one go (attributed labels
    /// need their kerned attributes rebuilt, not just stringValue).
    private func setStatus(caption: NSTextField?, value: NSTextField?, dotView: StatusDotView?,
                           captionText: String, valueText: String, dot: NSColor) {
        caption?.attributedStringValue = NSAttributedString(string: captionText, attributes: [
            .font: DesignTokens.uiFont(13),
            .kern: -0.2,
            .foregroundColor: DesignTokens.Palette.ink,
        ])
        value?.attributedStringValue = NSAttributedString(string: valueText, attributes: [
            .font: DesignTokens.uiFont(12, weight: .medium),
            .kern: -0.15,
            .foregroundColor: DesignTokens.Palette.ink,
        ])
        dotView?.setColor(dot)
    }

    func updateServiceSectionVisibility() {
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

    /// Clickable link — Palette.link, the pane's only text-colour accent.
    private func makeLinkButton(title: String, url: String) -> NSButton {
        let btn = NSButton(title: "", target: self, action: #selector(openLink(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DesignTokens.uiFont(11, weight: .medium),
            .kern: -0.1,
            .foregroundColor: DesignTokens.Palette.link,
        ])
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
    func saveAPIKeys() {
        guard groqField != nil else { return }
        APIKeyStore.shared.groqKey      = groqField.stringValue
        APIKeyStore.shared.geminiKey    = geminiField.stringValue
        APIKeyStore.shared.googleSttKey = googleSttField.stringValue
    }

    /// Persist the community nickname (UserDefaults, not Keychain — it's not a
    /// secret). Same double-save discipline as the API keys.
    func saveCommunityNickname() {
        guard let field = communityNicknameField else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(value, forKey: DojoSharedSync.nicknameKey)
    }

    // NSTextFieldDelegate — auto-save keys + nickname the moment a field ends editing.
    public func controlTextDidEndEditing(_ obj: Notification) {
        saveAPIKeys()
        saveCommunityNickname()
    }
}
