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
    private let tierPicker: PillSegmentedControl
    private let phoneticSwitch = NSSwitch()
    private let completion: (DojoCorrectionTable.Entry?) -> Void

    /// `initial` prefills the form (existing entry being edited, or a
    /// voice-parsed suggestion awaiting confirmation); nil is a blank add.
    static func present(on window: NSWindow, title: String,
                        initial: DojoCorrectionTable.Entry?,
                        completion: @escaping (DojoCorrectionTable.Entry?) -> Void) {
        let editor = DojoEntrySheet(title: title, initial: initial, completion: completion)
        activeSheets.append(editor)
        window.beginSheet(editor.sheet) { _ in
            activeSheets.removeAll { $0 === editor }
        }
    }

    private init(title: String, initial: DojoCorrectionTable.Entry?,
                 completion: @escaping (DojoCorrectionTable.Entry?) -> Void) {
        self.completion = completion
        self.tierPicker = PillSegmentedControl(
            labels: ["一律套用", "限道場模式"],
            selectedIndex: initial?.tier == "dojoOnly" ? 1 : 0)
        self.sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        correctField.placeholderString = "正確詞（如：妙極大帝）"
        correctField.stringValue = initial?.correct ?? ""
        correctField.font = DesignTokens.monoFont(13)

        wrongField.placeholderString = "選填——留空時只靠同音比對糾正"
        wrongField.stringValue = initial.map { $0.wrong == $0.correct ? "" : $0.wrong } ?? ""
        wrongField.font = DesignTokens.monoFont(13)

        phoneticSwitch.state = (initial?.phonetic ?? true) ? .on : .off
        let phoneticLabel = NSTextField(labelWithString: "同音變體一併糾正（妙吉／妙急…都會比對到）")
        phoneticLabel.font = DesignTokens.monoFont(11)
        let phoneticRow = NSStackView(views: [phoneticSwitch, phoneticLabel])
        phoneticRow.orientation = .horizontal
        phoneticRow.spacing = DesignTokens.Spacing.compact
        phoneticRow.alignment = .centerY

        tierPicker.translatesAutoresizingMaskIntoConstraints = false
        tierPicker.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let grid = DesignTokens.makeFieldGrid([
            [fieldLabel("正確詞"), correctField],
            [fieldLabel("常見誤辨"), wrongField],
            [fieldLabel("套用範圍"), tierPicker],
            [NSView(), phoneticRow],
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
        // Empty "wrong" means the user only knows the correct term (the common
        // voice-added case) — store wrong == correct so the exact-replacement
        // pass is a no-op and the phonetic pass does all the work.
        if wrong.isEmpty { wrong = correct }
        let entry = DojoCorrectionTable.Entry(
            wrong: wrong, correct: correct,
            tier: tierPicker.selectedIndex == 1 ? "dojoOnly" : "always",
            phonetic: phoneticSwitch.state == .on)
        endSheet(with: entry)
    }

    @objc private func cancel() { endSheet(with: nil) }

    private func endSheet(with entry: DojoCorrectionTable.Entry?) {
        sheet.sheetParent?.endSheet(sheet)
        completion(entry)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = DesignTokens.monoFont(12)
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
        promptScroll.borderType = .lineBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptScroll.heightAnchor.constraint(equalToConstant: 88),
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
        l.font = DesignTokens.monoFont(12)
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
        titleLabel.font = DesignTokens.monoFont(15, weight: .bold)

        let saveBtn = DesignTokens.makeSolidButton(title: "儲存", target: saveTarget, action: saveAction)
        saveBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "取消", target: cancelTarget, action: cancelAction)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.font = DesignTokens.monoFont(12)
        cancelBtn.keyEquivalent = "\u{1b}"
        let buttonRow = NSStackView(views: [NSView(), cancelBtn, saveBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DesignTokens.Spacing.item

        let stack = NSStackView(views: [titleLabel, content, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.card
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
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
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        sheet.setContentSize(stack.fittingSize)
    }
}
