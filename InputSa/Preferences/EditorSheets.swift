import AppKit

/// Window-attached sheet editors for dojo vocabulary entries and custom AI
/// modes — replaces the bare NSAlert-with-accessory-view modals, which broke
/// the card visual language (system chrome, cramped unlabeled fields) and
/// couldn't host a multiline prompt field.
///
/// Each `present` retains its controller in `activeSheets` until the sheet
/// ends — the sheet's controls hold weak-target references, so without this
/// the controller would deallocate the moment the presenting call returns.
final class DojoEntrySheet: NSObject {

    private static var activeSheets: [DojoEntrySheet] = []

    private let sheet: NSWindow
    private let correctField = NSTextField()
    private let wrongField = NSTextField()
    /// Retain historical metadata when editing; it no longer controls changes.
    private let initialEntry: DojoCorrectionTable.Entry?
    private let shareSwitch = NSSwitch()
    /// Completion carries the entry plus whether the user opted to share it to
    /// the community vocabulary (default off — protects personal terms).
    private let completion: (DojoCorrectionTable.Entry?, Bool) -> Void

    /// `initial` prefills the form (existing entry being edited, or a
    /// voice-parsed suggestion awaiting confirmation); nil is a blank add.
    static func present(on window: NSWindow, title: String,
                        initial: DojoCorrectionTable.Entry?,
                        completion: @escaping (DojoCorrectionTable.Entry?, Bool) -> Void) {
        let editor = DojoEntrySheet(title: title, initial: initial, completion: completion)
        activeSheets.append(editor)
        window.beginSheet(editor.sheet) { _ in
            activeSheets.removeAll { $0 === editor }
        }
    }

    private init(title: String, initial: DojoCorrectionTable.Entry?,
                 completion: @escaping (DojoCorrectionTable.Entry?, Bool) -> Void) {
        self.completion = completion
        self.initialEntry = initial
        self.sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        correctField.placeholderString = "例如：維宸、Input-sa、專案名稱"
        correctField.stringValue = initial?.correct ?? ""
        correctField.font = DesignTokens.monoFont(13)

        wrongField.placeholderString = "曾經辨識錯的寫法（選填）"
        wrongField.stringValue = initial.map { $0.wrong == $0.correct ? "" : $0.wrong } ?? ""
        wrongField.font = DesignTokens.monoFont(13)

        // Share opt-in — default OFF so personal preference terms aren't pushed to
        // the community pool unless the user deliberately chooses to.
        shareSwitch.state = .off
        let shareLabel = WrappingTextField("同時分享到共編詞庫（送審後供其他人參考）")
        shareLabel.font = DesignTokens.monoFont(11)
        shareLabel.preferredMaxLayoutWidth = DesignTokens.Grid.fieldColumnWidth - 48
        shareSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        let shareRow = NSStackView(views: [shareSwitch, shareLabel])
        shareRow.orientation = .horizontal
        shareRow.spacing = DesignTokens.Spacing.compact
        shareRow.alignment = .centerY

        let grid = DesignTokens.makeFieldGrid([
            [fieldLabel("字詞"), correctField],
            [fieldLabel("誤辨備註"), wrongField],
            [NSView(), shareRow],
        ])
        SheetChrome.install(on: sheet, title: title, content: grid,
                            saveTarget: self, saveAction: #selector(save),
                            cancelTarget: self, cancelAction: #selector(cancel))
        sheet.initialFirstResponder = correctField
    }

    @objc private func save() {
        let correct = correctField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correct.isEmpty else { NSSound.beep(); return }
        var wrong = wrongField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the legacy no-alias representation for existing readers. The
        // vocabulary now supplies spelling references, never replacement rules.
        if wrong.isEmpty { wrong = correct }
        let entry = DojoCorrectionTable.Entry(
            wrong: wrong, correct: correct,
            tier: initialEntry?.tier ?? "always",
            phonetic: initialEntry?.phonetic ?? false)
        endSheet(with: entry, share: shareSwitch.state == .on)
    }

    @objc private func cancel() { endSheet(with: nil, share: false) }

    private func endSheet(with entry: DojoCorrectionTable.Entry?, share: Bool) {
        sheet.sheetParent?.endSheet(sheet)
        completion(entry, share)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = DesignTokens.uiFont(12, weight: .medium)
        return l
    }
}

/// Sheet editor for one custom AI mode — multiline prompt field, which the old
/// NSAlert modal fundamentally couldn't offer (single-line NSTextField for a
/// whole rewriting instruction).
final class PromptEntrySheet: NSObject {

    private static var activeSheets: [PromptEntrySheet] = []

    private let sheet: NSWindow
    private let emojiField = NSTextField()
    private let nameField = NSTextField()
    private let promptTextView = NSTextView()
    private let completion: (UserStyleModel.CustomPrompt?) -> Void
    private let existingID: String?

    static func present(on window: NSWindow, title: String,
                        initial: UserStyleModel.CustomPrompt?,
                        completion: @escaping (UserStyleModel.CustomPrompt?) -> Void) {
        let editor = PromptEntrySheet(title: title, initial: initial, completion: completion)
        activeSheets.append(editor)
        window.beginSheet(editor.sheet) { _ in
            activeSheets.removeAll { $0 === editor }
        }
    }

    private init(title: String, initial: UserStyleModel.CustomPrompt?,
                 completion: @escaping (UserStyleModel.CustomPrompt?) -> Void) {
        self.completion = completion
        self.existingID = initial?.id
        self.sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        emojiField.placeholderString = "✨"
        emojiField.stringValue = initial?.emoji ?? ""
        emojiField.font = NSFont.systemFont(ofSize: 16)
        emojiField.alignment = .center
        emojiField.translatesAutoresizingMaskIntoConstraints = false
        emojiField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        nameField.placeholderString = "模式名稱（如：IG 貼文）"
        nameField.stringValue = initial?.name ?? ""
        nameField.font = DesignTokens.monoFont(13)

        promptTextView.string = initial?.prompt ?? ""
        promptTextView.font = DesignTokens.monoFont(12)
        promptTextView.isRichText = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.textContainerInset = NSSize(width: 6, height: 8)
        let promptScroll = NSScrollView()
        promptScroll.documentView = promptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = false
        promptScroll.scrollerStyle = .legacy
        promptScroll.borderType = .lineBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptScroll.heightAnchor.constraint(equalToConstant: 132),
            promptScroll.widthAnchor.constraint(equalToConstant: DesignTokens.Grid.fieldColumnWidth),
        ])
        // NSTextView inside NSScrollView needs its own width management or long
        // lines run off horizontally instead of wrapping.
        promptTextView.autoresizingMask = [.width]
        promptTextView.isHorizontallyResizable = false
        promptTextView.textContainer?.widthTracksTextView = true

        let grid = DesignTokens.makeFieldGrid([
            [fieldLabel("Emoji"), emojiField],
            [fieldLabel("名稱"), nameField],
            [fieldLabel("AI 指令"), promptScroll],
        ])
        SheetChrome.install(on: sheet, title: title, content: grid,
                            saveTarget: self, saveAction: #selector(save),
                            cancelTarget: self, cancelAction: #selector(cancel))
        sheet.initialFirstResponder = nameField
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { NSSound.beep(); return }
        let entry = UserStyleModel.CustomPrompt(
            id: existingID ?? UUID().uuidString,
            name: name,
            emoji: emojiField.stringValue.isEmpty ? "✨" : emojiField.stringValue,
            prompt: prompt)
        endSheet(with: entry)
    }

    @objc private func cancel() { endSheet(with: nil) }

    private func endSheet(with entry: UserStyleModel.CustomPrompt?) {
        sheet.sheetParent?.endSheet(sheet)
        completion(entry)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = DesignTokens.uiFont(12, weight: .medium)
        return l
    }
}

/// Shared sheet scaffolding: header title, caller content, 取消 + gold 儲存
/// buttons (Enter saves, Esc cancels). Kept in one place so both editors read
/// as the same component.
private enum SheetChrome {
    static func install(on sheet: NSWindow, title: String, content: NSView,
                        saveTarget: AnyObject, saveAction: Selector,
                        cancelTarget: AnyObject, cancelAction: Selector) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.uiFont(18, weight: .semibold)
        titleLabel.textColor = DesignTokens.Palette.ink
        sheet.backgroundColor = DesignTokens.Palette.canvas

        let saveBtn = DesignTokens.inkButton(title: "儲存", target: saveTarget, action: saveAction)
        saveBtn.keyEquivalent = "\r"
        let cancelBtn = DesignTokens.pushButton(title: "取消", target: cancelTarget, action: cancelAction)
        cancelBtn.keyEquivalent = "\u{1b}"
        let buttonRow = NSStackView(views: [NSView(), cancelBtn, saveBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DesignTokens.Spacing.item

        let stack = NSStackView(views: [titleLabel, content, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.card
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        // Right-align the button row with the content's trailing edge.
        stack.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = sheet.contentView else { return }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        sheet.setContentSize(stack.fittingSize)
    }
}
