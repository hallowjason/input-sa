import AppKit

/// Service choices are visible cards; credentials and capability details stay
/// below the selection. Hidden native pickers retain the existing action API.
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
        case .whisper: initialProviderIdx = 3
        }
        providerPicker = DesignTokens.popup(
            items: ["Groq Whisper", "Google STT（含台語）", "本地 \(SherpaVoiceService.modelDisplayName)", "本地 Whisper Turbo"],
            selectedIndex: initialProviderIdx,
            target: self, action: #selector(providerPopupChanged(_:)))
        voiceProviderChoices = SoftChoiceGrid(options: [
            .init(title: "Groq Whisper", detail: "雲端 · 快速語音轉錄"),
            .init(title: "Google STT", detail: "雲端 · 中文與台語"),
            .init(title: "本地 \(SherpaVoiceService.modelDisplayName)", detail: "離線 · 快速輕量辨識"),
            .init(title: "Whisper Turbo", detail: "離線 · 詞庫提示與暫時字幕"),
        ], selectedIndex: initialProviderIdx)
        voiceProviderChoices.onSelect = { [weak self] index in
            guard let self else { return }
            self.providerPicker.selectItem(at: index)
            self.providerPopupChanged(self.providerPicker)
            self.voiceProviderChoices.select(self.providerPicker.indexOfSelectedItem)
        }

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

        // Mute-while-recording toggle (default off). Not a conditional row —
        // it carries its own leading hairline so it separates cleanly whether or
        // not the provider key sections above it are visible.
        muteWhileRecordingSwitch = NSSwitch()
        muteWhileRecordingSwitch.state = PreferencesWindowController.muteWhileRecording ? .on : .off
        muteWhileRecordingSwitch.target = self
        muteWhileRecordingSwitch.action = #selector(muteWhileRecordingChanged)
        let modelButton = DesignTokens.pushButton(title: "管理模型…", target: self,
                                                  action: #selector(openWhisperModelManager))

        let transcribeCard = DesignTokens.groupCard([
            status.row,
            groqSection,
            googleSection,
            DesignTokens.hairline(),
            DesignTokens.row(title: "Whisper 本地模型", subtitle: "約 1.6 GB · Apple Silicon／macOS 14 以上", control: modelButton),
            DesignTokens.hairline(),
            DesignTokens.row(title: "錄音時靜音喇叭",
                             subtitle: "按住錄音時暫時靜音系統喇叭，避免外放聲音被錄進去",
                             control: muteWhileRecordingSwitch),
        ], autoSeparators: false)

        let serviceHint = DesignTokens.caption(
            "SenseVoice 快速、完全本地，但不支援專有名詞提示。Whisper 支援中英夾雜的有限詞庫提示與暫時字幕；" +
            "模型準備完成後可自行切換，辨識結果仍依錄音而異。Groq／Google 會將錄音傳至對應雲端服務。")

        // ── Group 2: AI 潤飾服務 ────────────────────────────────
        let polishStatus = DesignTokens.statusRow(caption: "目前使用",
                                                  value: "", dot: DesignTokens.Palette.statusOK)
        polishStatusCaption = polishStatus.captionLabel
        polishStatusLabel = polishStatus.valueLabel
        polishStatusDot = polishStatus.dotView

        let initialPolishIdx = Self.polishProviders.firstIndex(of: APIKeyStore.shared.polishProvider) ?? 0
        polishProviderPicker = DesignTokens.popup(
            items: Self.polishProviders.map(\.displayName),
            selectedIndex: initialPolishIdx,
            target: self, action: #selector(polishPopupChanged(_:)))
        polishProviderChoices = SoftChoiceGrid(options: [
            .init(title: "Gemini", detail: "雲端 · 使用自己的 API Key"),
            .init(title: "Apple 本地", detail: "離線 · Apple Intelligence"),
            .init(title: "Codex CLI", detail: "使用這台 Mac 的 Codex 登入"),
            .init(title: "Claude Code", detail: "使用這台 Mac 的 Claude 登入"),
        ], selectedIndex: initialPolishIdx)
        polishProviderChoices.onSelect = { [weak self] index in
            guard let self else { return }
            self.polishProviderPicker.selectItem(at: index)
            self.polishPopupChanged(self.polishProviderPicker)
            let effective = Self.polishProviders.firstIndex(of: APIKeyStore.shared.polishProvider) ?? 0
            self.polishProviderPicker.selectItem(at: effective)
            self.polishProviderChoices.select(effective)
        }

        geminiField = makeKeyField(placeholder: "AIzaSy...")
        cleanupStylePicker = DesignTokens.popup(items: DictationCleanupStyle.allCases.map(\.title),
            selectedIndex: DictationCleanupStyle.allCases.firstIndex(of: .selected) ?? 1,
            target: self, action: #selector(cleanupStyleChanged(_:)))
        cleanupStyleChoices = SoftSegmentedPicker(labels: DictationCleanupStyle.allCases.map(\.title),
            selectedIndex: cleanupStylePicker.indexOfSelectedItem)
        cleanupStyleChoices.widthAnchor.constraint(equalToConstant: 290).isActive = true
        cleanupStyleChoices.onSelect = { [weak self] index in
            guard let self else { return }
            self.cleanupStylePicker.selectItem(at: index)
            self.cleanupStyleChanged(self.cleanupStylePicker)
        }

        cliConnectionTestButton = DesignTokens.pushButton(title: "測試連線", target: self,
                                                          action: #selector(testCLIConnection))
        cliConnectionCancelButton = DesignTokens.pushButton(title: "取消測試", target: self,
                                                            action: #selector(cancelCLIConnection))
        cliConnectionCancelButton.isHidden = true
        let cliActions = NSStackView(views: [cliConnectionTestButton, cliConnectionCancelButton])
        cliActions.orientation = .horizontal
        cliActions.spacing = 4
        cliConnectionLabel = DesignTokens.caption("", width: DesignTokens.contentWidth - 56)
        let cliNote = NSStackView(views: [cliConnectionLabel])
        cliNote.orientation = .vertical
        cliNote.alignment = .leading
        cliNote.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 12, right: 20)
        cliConnectionLabel.widthAnchor.constraint(equalTo: cliNote.widthAnchor, constant: -40).isActive = true
        cliConfigurationSection = conditionalSection(rows: [
            DesignTokens.row(title: "CLI 連線", subtitle: "測試只使用內建範例句，不讀取你的口述", control: cliActions),
            cliNote,
        ])

        let polishCard = DesignTokens.groupCard([
            polishStatus.row,
            DesignTokens.hairline(),
            DesignTokens.row(title: "整理強度", control: cleanupStyleChoices),
            cliConfigurationSection,
            conditionalSection(rows: [   // not conditional, but reuses the hairline wrapper
                DesignTokens.row(title: "Gemini API Key", subtitle: "翻譯與口頭加詞使用", control: geminiField),
                trailingLinkRow(note: nil,
                                link: makeLinkButton(title: "前往 AI Studio 取得 ↗",
                                                     url: "https://aistudio.google.com/app/apikey")),
            ]),
        ], autoSeparators: false)

        let polishHint = DesignTokens.caption(
            "Gemini 使用 API Key；Apple 本地需 macOS 26 與 Apple Intelligence。Codex／Claude 須先自行安裝並登入，" +
            "找到執行檔不代表已登入。CLI 整理仍透過對應服務處理文字，並非離線模型。翻譯與口頭加詞仍使用 Gemini。")

        // ── Auto-save (macOS preferences convention: no explicit save button;
        //    keys are written to Keychain the moment a field ends editing) ──
        [groqField, googleSttField, geminiField].forEach { $0.delegate = self }

        let noteLabel = DesignTokens.caption(
            "原文不呼叫 AI；輕整理保留用詞；結構整理依內容分段。API Key 修改後自動儲存至系統 Keychain。")

        let stack = serviceColumn([
            DesignTokens.group(title: "用什麼辨識", card: serviceColumn([voiceProviderChoices, transcribeCard], spacing: 12), footnote: serviceHint),
            DesignTokens.group(title: "用什麼整理", card: serviceColumn([polishProviderChoices, polishCard], spacing: 12), footnote: polishHint),
            noteLabel,
        ], spacing: DesignTokens.Spacing.section)
        updateServiceSectionVisibility()
        updateProviderStatus()
        updatePolishProviderStatus()
        return stack
    }

    /// Kept next to its persistence handlers, shown with the vocabulary itself.
    func makeCommunityPreferencesSection() -> NSView {
        communityNicknameField = NSTextField()
        communityNicknameField.placeholderString = "分享詞條時的署名（選填）"
        communityNicknameField.font = DesignTokens.uiFont(12)
        communityNicknameField.stringValue =
            UserDefaults.standard.string(forKey: DojoSharedSync.nicknameKey) ?? ""
        communityNicknameField.isEditable = true
        communityNicknameField.isSelectable = true
        communityNicknameField.delegate = self   // auto-save on end-editing (same as key fields)
        let nicknameContent = NSStackView(views: [DesignTokens.sectionLabel("共編暱稱"), communityNicknameField])
        nicknameContent.orientation = .vertical
        nicknameContent.alignment = .leading
        nicknameContent.spacing = 8
        nicknameContent.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        communityNicknameField.widthAnchor.constraint(equalTo: nicknameContent.widthAnchor, constant: -40).isActive = true
        let communityCard = DesignTokens.groupCard([nicknameContent])
        let communityHint = DesignTokens.caption(
            "App 啟動時自動同步社群共享的「已審核」詞條（帶「共編」標記、唯讀）。" +
            "口頭加詞時可選擇分享自己的詞條；暱稱僅用於標示分享者，可留空。")

        return DesignTokens.group(title: "共編詞庫", card: communityCard, footnote: communityHint)
    }

    private func serviceColumn(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for group in stack.arrangedSubviews {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    // MARK: - Row builders

    /// Mono API-key field, fixed trailing width.
    private func makeKeyField(placeholder: String) -> NSTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = DesignTokens.monoFont(11)
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = DesignTokens.Palette.pressed
        field.textColor = DesignTokens.Palette.ink
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
            let noteLabel = DesignTokens.caption(note)
            views.append(noteLabel)
        }
        if note == nil { views.append(NSView()) }
        link.setContentCompressionResistancePriority(.required, for: .horizontal)
        link.setContentHuggingPriority(.required, for: .horizontal)
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

    @objc private func muteWhileRecordingChanged() {
        PreferencesWindowController.muteWhileRecording = (muteWhileRecordingSwitch.state == .on)
    }

    private func polishProviderChanged(_ selectedIndex: Int) {
        guard Self.polishProviders.indices.contains(selectedIndex) else { return }
        cancelCLIConnection()
        let requested = Self.polishProviders[selectedIndex]
        let wantApple = requested == .apple
        // Transparent fallback: if the user taps Apple but the on-device model
        // isn't available on this machine, keep Gemini as the effective provider
        // and explain why in the status row — never silently persist a provider
        // that will just fail at dictation time. (Runtime failures of an available
        // Apple model fall back to the raw transcript, never a silent cloud call.)
        if wantApple && !ApplePolishService.availabilityStatus.isAvailable {
            APIKeyStore.shared.polishProvider = .gemini
        } else {
            APIKeyStore.shared.polishProvider = requested
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
        } else if provider == .gemini {
            (caption, value, dot) = ("目前使用", "Gemini（雲端）· 需網路",
                                     DesignTokens.Palette.statusOK)
        } else {
            let found = CLITextService.isAvailable(provider: provider)
            (caption, value, dot) = ("目前使用", provider.displayName + (found ? " · 已找到 CLI" : " · 尚未找到 CLI"),
                                     found ? DesignTokens.Palette.statusOK : DesignTokens.Palette.statusWarn)
        }
        setStatus(caption: polishStatusCaption, value: polishStatusLabel,
                  dotView: polishStatusDot, captionText: caption, valueText: value, dot: dot)
        let isCLI = provider == .codex || provider == .claude
        cliConfigurationSection?.isHidden = !isCLI
        cliConnectionCancelButton?.isHidden = cliTestingProvider == nil
        if isCLI {
            let found = CLITextService.isAvailable(provider: provider)
            cliConnectionTestButton?.isEnabled = cliTestingProvider == nil && found
            if let testing = cliTestingProvider {
                cliConnectionLabel?.stringValue = "正在用內建範例句測試 \(testing.displayName)…"
            } else {
                cliConnectionLabel?.stringValue = found
                    ? "已找到 \(provider.displayName)。按「測試連線」確認登入與文字整理能力；不會替你安裝或登入。"
                    : "尚未找到 \(provider.displayName)。請先在終端機完成官方安裝與登入，再重新開啟此頁測試。"
            }
        }
    }

    private func serviceProviderChanged(_ selectedIndex: Int) {
        let provider: APIKeyStore.VoiceProvider
        switch selectedIndex {
        case 1:  provider = .google
        case 2:  provider = .sherpa
        case 3:
            guard WhisperRuntime.isSupported, WhisperRuntime.runtimeInstalled, ModelManager.shared.isReady else {
                providerPicker.selectItem(at: [.groq, .google, .sherpa, .whisper].firstIndex(of: APIKeyStore.shared.voiceProvider) ?? 0)
                WhisperModelWindowController.shared.show()
                return
            }
            provider = .whisper
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
        case .sherpa: value = "本地 \(SherpaVoiceService.modelDisplayName) · 完全離線"
        case .whisper: value = "Whisper Turbo · 完全離線"
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
        case .sherpa, .whisper:
            groqSection?.isHidden = true
            googleSection?.isHidden = true
        }
    }

    @objc private func openWhisperModelManager() { WhisperModelWindowController.shared.show() }

    @objc private func cleanupStyleChanged(_ sender: NSPopUpButton) {
        guard DictationCleanupStyle.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        DictationCleanupStyle.selected = DictationCleanupStyle.allCases[sender.indexOfSelectedItem]
        TranscriptionMode.activeCustomPromptID = nil
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
