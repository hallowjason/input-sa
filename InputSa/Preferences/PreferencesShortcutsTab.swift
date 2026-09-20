import AppKit

/// 快捷鍵 pane — every one of the seven actions is now user-rebindable. Each row
/// pairs the action's name + description with a `ShortcutRecorderView`; a recording
/// action shows a muted「切換」hint. A reset button restores all defaults, and a
/// warning line flags conflicts or an unmodified bare key that would fire during
/// normal typing.
extension PreferencesWindowController {

    func makeShortcutsContent() -> NSView {
        // ── Group 1: 快捷鍵（可自訂）──────────────────────────
        shortcutRecorders.removeAll()
        let shortcutRows: [NSView] = ShortcutAction.allCases.map { action in
            let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
            recorder.setShortcut(ShortcutSettings.shared.shortcut(for: action))
            recorder.onChange = { [weak self] sc in
                ShortcutSettings.shared.set(sc, for: action)
                self?.updateShortcutWarning()
            }
            shortcutRecorders[action] = recorder
            return DesignTokens.row(title: action.titleZh, subtitle: action.subtitleZh,
                                    control: recorderControl(recorder, hold: action.isRecordingAction))
        }
        let shortcutCard = DesignTokens.groupCard(shortcutRows)

        let resetButton = DesignTokens.pushButton(title: "還原預設", target: self,
                                                  action: #selector(resetAllShortcuts))
        let resetRow = NSStackView(views: [resetButton])
        resetRow.orientation = .horizontal
        resetRow.alignment = .centerY

        let hint = DesignTokens.caption(
            "錄音功能：按一下開始，再按一下結束；按 Esc 取消。點快捷鍵欄位可自訂按鍵，也可使用單顆修飾鍵（如右 ⌥）。")

        // Conflict / unmodified-key warning (hidden unless something needs attention).
        shortcutWarningLabel = WrappingTextField("")
        shortcutWarningLabel.font = DesignTokens.uiFont(11, weight: .medium)
        shortcutWarningLabel.textColor = DesignTokens.Palette.statusWarn
        shortcutWarningLabel.preferredMaxLayoutWidth = DesignTokens.contentWidth - 8
        shortcutWarningLabel.isHidden = true

        // ── Group 2: 錄音面板外觀 ─────────────────────────────
        let appearanceCard = DesignTokens.groupCard([
            DesignTokens.row(title: "HUD 神佛角色", control: makeCharacterPopUp()),
        ])

        // ── Assemble ─────────────────────────────────────────
        let shortcutGroup = NSStackView(views: [
            DesignTokens.group(title: "快捷鍵", card: shortcutCard, footnote: hint),
            resetRow,
            shortcutWarningLabel,
        ])
        shortcutGroup.orientation = .vertical
        shortcutGroup.alignment = .leading
        shortcutGroup.spacing = 7
        for child in shortcutGroup.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: shortcutGroup.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [
            shortcutGroup,
            DesignTokens.group(title: "錄音面板外觀", card: appearanceCard),
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

    /// Recorder + optional muted「切換」hint for start/stop recording actions.
    private func recorderControl(_ recorder: ShortcutRecorderView, hold: Bool) -> NSView {
        let holdLabel = DesignTokens.styledLabel(
            hold ? "切換" : "", size: 11, weight: .regular, kern: -0.1,
            color: DesignTokens.Palette.inkMuted(0.35))
        let cluster = NSStackView(views: [recorder, holdLabel])
        cluster.orientation = .horizontal
        cluster.distribution = .fill
        cluster.alignment = .centerY
        cluster.spacing = 6
        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalToConstant: 140),
            holdLabel.widthAnchor.constraint(equalToConstant: 28),
            cluster.widthAnchor.constraint(equalToConstant: 174),
        ])
        return cluster
    }

    /// Warn on (a) two actions bound to the same keys, or (b) a bare key with no
    /// modifiers, which would trigger during ordinary typing anywhere.
    func updateShortcutWarning() {
        guard shortcutWarningLabel != nil else { return }
        var messages: [String] = []

        // Conflicts: report each colliding pair once.
        var seen: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            let sc = ShortcutSettings.shared.shortcut(for: action)
            if let other = ShortcutSettings.shared.conflictingAction(for: sc, excluding: action),
               !seen.contains(other) {
                messages.append("「\(action.titleZh)」和「\(other.titleZh)」設成了同一個鍵（\(sc.displayString)），只有一個會生效。")
            }
            seen.append(action)
        }

        // Unmodified bare key (a combo with zero modifiers, not a modifier-only chord).
        for action in ShortcutAction.allCases {
            let sc = ShortcutSettings.shared.shortcut(for: action)
            if !sc.isModifierOnly && sc.modifierFlags == 0 {
                messages.append("「\(action.titleZh)」設成了不含修飾鍵的單一按鍵（\(sc.displayString)），日常打字打到這個鍵時也會觸發。")
            }
        }

        if messages.isEmpty {
            shortcutWarningLabel.isHidden = true
        } else {
            shortcutWarningLabel.stringValue = "⚠ " + messages.joined(separator: "\n⚠ ")
            shortcutWarningLabel.isHidden = false
        }
    }

    @objc private func resetAllShortcuts() {
        ShortcutSettings.shared.resetAll()
        for (action, recorder) in shortcutRecorders {
            recorder.setShortcut(ShortcutSettings.shared.shortcut(for: action))
        }
        updateShortcutWarning()
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

}
