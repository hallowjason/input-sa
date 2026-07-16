import AppKit

/// 快捷鍵 pane — shortcut overview, optional custom dictation shortcut, and
/// appearance/language pickers. Same controls and actions as always; the
/// 2026-07-16 v3 redesign flipped the overview to the native register:
/// action name + description left, key-cap chips right.
extension PreferencesWindowController {

    func makeShortcutsContent() -> NSView {
        // ── Group 1: 快捷鍵總覽 ───────────────────────────────
        let overviewRows: [(name: String, desc: String, keys: [String], suffix: String?)] = [
            ("語音聽寫", "說話 → 轉錄 → AI 潤飾 → 輸出至游標", ["右 ⌥"], "長按"),
            ("即時翻譯", "說中文，翻譯成目標語言輸出", ["右 ⌘"], "長按"),
            ("口頭修正", "說詞條釋義，Enter 確認加入道場詞庫", ["右 ⇧"], "長按"),
            ("選字潤飾", "選取文字後按，Enter 接受、Esc 取消", ["⌥", "P"], nil),
            ("偏好設定", "開啟本視窗", ["⌃", "⌥", "P"], nil),
        ]
        let overviewCard = DesignTokens.groupCard(overviewRows.map { row in
            DesignTokens.row(title: row.name, subtitle: row.desc,
                             control: keycapCluster(keys: row.keys, suffix: row.suffix))
        })

        // ── Group 2: 自訂聽寫快捷鍵（optional override）────────
        voiceRecorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        voiceRecorder.setShortcut(PreferencesWindowController.voiceShortcut)
        voiceRecorder.onChange = { [weak self] sc in
            PreferencesWindowController.voiceShortcut = sc
            self?.updateShortcutWarning()
        }

        let clearBtn = DesignTokens.pushButton(title: "清除", target: self,
                                               action: #selector(clearVoiceShortcut))
        let recorderRow = NSStackView(views: [voiceRecorder, clearBtn])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 8
        recorderRow.alignment = .centerY

        let overrideCard = DesignTokens.groupCard([
            DesignTokens.row(title: "快捷鍵", subtitle: "設定後取代右 Option 長按",
                             control: recorderRow),
        ])
        let overrideHint = DesignTokens.caption(
            "可錄製含無修飾鍵的單鍵；按 ⎋ 取消錄製。點「清除」恢復右 Option 長按預設。")

        // Only visible when the saved shortcut has zero modifiers — that key will fire
        // system-wide on every matching keystroke, including normal typing in any app.
        shortcutWarningLabel = NSTextField(wrappingLabelWithString:
            "⚠ 這是不含修飾鍵的單一按鍵，日常打字打到這個鍵時也會觸發語音錄音，請確認這是你要的。")
        shortcutWarningLabel.font = DesignTokens.uiFont(11, weight: .medium)
        shortcutWarningLabel.textColor = DesignTokens.Palette.statusWarn
        shortcutWarningLabel.preferredMaxLayoutWidth = DesignTokens.contentWidth - 8
        shortcutWarningLabel.isHidden = true

        // ── Group 3: 外觀與語言 ───────────────────────────────
        let appearanceCard = DesignTokens.groupCard([
            DesignTokens.row(title: "翻譯目標語言", control: makeTranslatePopUp()),
            DesignTokens.row(title: "HUD 神佛角色", control: makeCharacterPopUp()),
        ])

        // ── Assemble ─────────────────────────────────────────
        let overrideGroup = NSStackView(views: [
            DesignTokens.group(title: "自訂聽寫快捷鍵", card: overrideCard, footnote: overrideHint),
            shortcutWarningLabel,
        ])
        overrideGroup.orientation = .vertical
        overrideGroup.alignment = .leading
        overrideGroup.spacing = 7
        overrideGroup.arrangedSubviews.first!.widthAnchor.constraint(
            equalTo: overrideGroup.widthAnchor).isActive = true

        let stack = NSStackView(views: [
            DesignTokens.group(title: "快捷鍵總覽", card: overviewCard),
            overrideGroup,
            DesignTokens.group(title: "外觀與語言", card: appearanceCard),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.section
        for group in stack.arrangedSubviews {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        updateShortcutWarning()

        return stack
    }

    /// Trailing key-cap cluster: one chip per key, optional muted suffix（長按）.
    private func keycapCluster(keys: [String], suffix: String?) -> NSView {
        var views: [NSView] = keys.map { DesignTokens.keycap($0) }
        if let suffix {
            views.append(DesignTokens.styledLabel(
                suffix, size: 11, weight: .regular, kern: -0.1,
                color: DesignTokens.Palette.inkMuted(0.35)))
        }
        let cluster = NSStackView(views: views)
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 5
        return cluster
    }

    /// Shows the "unmodified single key" warning only when a shortcut is saved AND
    /// it has zero modifier flags.
    func updateShortcutWarning() {
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
        let saved = TranscriptionMode.translateTargetLanguage
        translatePopUp = DesignTokens.popup(
            items: Self.translateLanguages,
            selectedIndex: Self.translateLanguages.firstIndex(of: saved) ?? 0,
            target: self, action: #selector(translateLangChanged))
        return translatePopUp
    }

    private func makeCharacterPopUp() -> NSPopUpButton {
        DesignTokens.popup(
            items: HUDCharacter.allCases.map { $0.displayName },
            selectedIndex: HUDCharacter.allCases.firstIndex(of: HUDCharacter.current) ?? 0,
            target: self, action: #selector(hudCharacterChanged(_:)))
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
}
