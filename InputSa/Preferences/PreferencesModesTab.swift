import AppKit

/// AI 模式 pane — the custom-prompt list plus its add action. Same controls
/// and data flow as always; the 2026-07-16 v3 redesign puts the list inside a
/// grouped card with the add button as a card-footer text action.
extension PreferencesWindowController {

    func makeModesContent() -> NSView {
        promptCardList = CardListView(maxHeight: 288)   // 6 rows, then scroll
        promptCardList.emptyStateText = "尚無自訂模式 — 點下方「新增模式」建立"
        promptCardList.onEdit = { [weak self] idx in self?.editCustomPrompt(at: idx) }
        promptCardList.onDelete = { [weak self] idx in self?.deleteCustomPrompt(at: idx) }

        customPrompts = UserStyleModel.shared.customPrompts

        let addBtn = DesignTokens.textButton(title: "新增模式", symbol: "plus",
                                             target: self, action: #selector(addCustomPrompt))
        let footer = NSStackView(views: [addBtn, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 16)
        footer.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let card = DesignTokens.groupCard([promptCardList, footer])

        let hintLabel = DesignTokens.caption(
            "在選單列「AI 模式」選定後，聽寫潤飾與選字潤飾（Option＋P）都會套用該模式。" +
            "內建模式（標準／IG 貼文／條列重點／正式書信）由選單列切換，此處管理自訂模式。")

        let stack = NSStackView(views: [
            DesignTokens.group(title: "自訂模式", card: card, footnote: hintLabel),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.section
        stack.arrangedSubviews.first!.widthAnchor.constraint(
            equalTo: stack.widthAnchor).isActive = true

        reloadPromptCards()

        return stack
    }

    func reloadPromptCards() {
        customPrompts = UserStyleModel.shared.customPrompts
        let rows = customPrompts.map { p -> CardListView.Row in
            let title = NSAttributedString(string: p.name, attributes: [
                .font: DesignTokens.uiFont(13, weight: .semibold),
                .kern: -0.2,
                .foregroundColor: DesignTokens.Palette.ink,
            ])
            return CardListView.Row(
                icon: p.emoji,
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
}
