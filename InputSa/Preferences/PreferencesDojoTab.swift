import AppKit

/// 道場詞庫 pane — dojo-mode switch, the vocabulary list with add / voice-add
/// footer actions, and share status. Same controls and data flow as always;
/// the 2026-07-16 v3 redesign moves the list into a grouped card (text-first
/// rows, monochrome badges) with card-footer text actions.
extension PreferencesWindowController {

    func makeDojoContent() -> NSView {
        // ── Card 1: 道場模式 switch ───────────────────────────
        dojoModeSwitch = NSSwitch()
        dojoModeSwitch.state = PreferencesWindowController.dojoMode ? .on : .off
        dojoModeSwitch.target = self
        dojoModeSwitch.action = #selector(dojoModeChanged)

        let modeCard = DesignTokens.groupCard([
            DesignTokens.row(title: "道場模式",
                             subtitle: "關閉時「限道場」詞條不生效，避免誤糾一般口語",
                             control: dojoModeSwitch),
        ])

        // ── Card 2: 詞條 list + footer actions ────────────────
        dojoCardList = CardListView(maxHeight: 240)   // 5 rows, then scroll
        dojoCardList.emptyStateText = "尚無詞條 — 點下方「新增詞條」建立"
        dojoCardList.onEdit = { [weak self] idx in self?.editDojoEntry(at: idx) }
        dojoCardList.onDelete = { [weak self] idx in self?.deleteDojoEntry(at: idx) }

        dojoEntries = DojoCorrectionTable.shared.personalEntries

        let addBtn = DesignTokens.textButton(
            title: "新增詞條", symbol: "plus", target: self, action: #selector(addDojoEntry))
        voiceAddButton = DesignTokens.textButton(
            title: "用說的新增", symbol: "mic.fill", target: self, action: #selector(toggleVoiceAdd))

        dojoCountLabel = DesignTokens.styledLabel(
            "", size: 11, weight: .regular, kern: -0.1,
            color: DesignTokens.Palette.inkMuted(0.35))

        let footer = NSStackView(views: [addBtn, voiceAddButton, NSView(), dojoCountLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 16)
        footer.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let listCard = DesignTokens.groupCard([dojoCardList, footer])

        let hintLabel = DesignTokens.caption(
            "語音轉錄常聽錯的道場專有名詞在此糾正。「一律套用」永遠生效；「限道場」只在道場模式" +
            "開啟時生效。「同音」會比對所有同音變體（妙吉／妙急大帝 → 妙極大帝）。" +
            "「共編」為道友共享的詞條（唯讀），要覆蓋就自己新增同一個誤辨的詞條。")

        // Transient, non-blocking share feedback (kept empty/hidden until a submit
        // resolves) — deliberately not an NSAlert, so a failed share never
        // interrupts the user.
        dojoShareStatusLabel = NSTextField(labelWithString: "")
        dojoShareStatusLabel.font = DesignTokens.uiFont(11, weight: .semibold)
        dojoShareStatusLabel.isHidden = true

        // ── Assemble ─────────────────────────────────────────
        let stack = NSStackView(views: [
            DesignTokens.group(card: modeCard),
            dojoShareStatusLabel,
            DesignTokens.group(title: "詞條", card: listCard, footnote: hintLabel),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.section
        stack.setCustomSpacing(7, after: dojoShareStatusLabel)
        for group in stack.arrangedSubviews where !(group is NSTextField) {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        reloadDojoCards()

        return stack
    }

    func reloadDojoCards() {
        // Personal entries are editable (indices 0..<personal.count map straight
        // to `dojoEntries`, which onEdit/onDelete index into). Shared entries are
        // appended after as read-only rows — they never fire the edit/delete
        // callbacks, so the personal index mapping stays intact.
        dojoEntries = DojoCorrectionTable.shared.personalEntries
        var rows = dojoEntries.map { dojoRow(for: $0, shared: false) }
        rows += DojoCorrectionTable.shared.sharedEntries.map { dojoRow(for: $0, shared: true) }
        dojoCardList?.reload(rows: rows)
        dojoCountLabel?.stringValue = "\(rows.count) 詞條"
    }

    /// One list row for a dojo entry. `shared` marks it as a community entry:
    /// adds a 「共編」 badge and makes the row read-only (no 編輯／刪除).
    /// Monochrome badge hierarchy: always-on tier = filled ink, dojo-only =
    /// soft well, phonetic = soft well, community = hairline outline.
    private func dojoRow(for e: DojoCorrectionTable.Entry, shared: Bool) -> CardListView.Row {
        let isAlways = e.tier != "dojoOnly"
        let title = NSAttributedString(string: e.correct, attributes: [
            .font: DesignTokens.uiFont(13, weight: .semibold),
            .kern: -0.2,
            .foregroundColor: DesignTokens.Palette.ink,
        ])
        var subtitle = e.wrong != e.correct ? "常見誤辨：\(e.wrong)" : "同音變體比對"
        if shared { subtitle += " · 道友分享" }
        var badges: [(text: String, style: DesignTokens.BadgeStyle)] = [
            isAlways ? ("一律套用", .filled) : ("限道場", .soft)
        ]
        if e.phonetic { badges.append(("同音", .soft)) }
        if shared { badges.append(("共編", .outline)) }
        return CardListView.Row(
            title: title,
            subtitle: subtitle,
            badges: badges,
            isReadOnly: shared)
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
            voiceAddButton.setTitle("解析中…")
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
                                                       initial: entry) { [weak self] confirmed, share in
                                    guard let self, let confirmed else { return }
                                    var updated = self.dojoEntries
                                    updated.append(confirmed)
                                    self.applyDojoEntries(updated, failureMessage: "儲存失敗")
                                    self.submitShareIfNeeded(confirmed, share: share)
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
            voiceAddButton.setTitle("停止並解析")
        }
    }

    func resetVoiceAddButton() {
        voiceAddButton.isEnabled = true
        voiceAddButton.setTitle("用說的新增")
    }

    @objc private func addDojoEntry() {
        guard let window else { return }
        DojoEntrySheet.present(on: window, title: "新增道場詞條", initial: nil) { [weak self] entry, share in
            guard let self, let entry else { return }
            var updated = self.dojoEntries
            updated.append(entry)
            self.applyDojoEntries(updated, failureMessage: "儲存失敗")
            self.submitShareIfNeeded(entry, share: share)
        }
    }

    private func editDojoEntry(at index: Int) {
        guard let window, index < dojoEntries.count else { return }
        DojoEntrySheet.present(on: window, title: "編輯道場詞條",
                               initial: dojoEntries[index]) { [weak self] entry, share in
            guard let self, let entry else { return }
            var updated = self.dojoEntries
            updated[index] = entry
            self.applyDojoEntries(updated, failureMessage: "儲存失敗")
            self.submitShareIfNeeded(entry, share: share)
        }
    }

    private func deleteDojoEntry(at index: Int) {
        guard index < dojoEntries.count else { return }
        var updated = dojoEntries
        updated.remove(at: index)
        applyDojoEntries(updated, failureMessage: "刪除失敗")
    }

    /// Persist `updated` to `DojoCorrectionTable` and refresh the list.
    /// On write failure, the in-memory table/UI are left untouched and an alert shown.
    private func applyDojoEntries(_ updated: [DojoCorrectionTable.Entry], failureMessage: String) {
        if DojoCorrectionTable.shared.save(updated) {
            reloadDojoCards()
        } else {
            showAlert(failureMessage, info: "無法寫入偏好設定檔案，請確認磁碟空間或權限。")
        }
    }

    /// Submit an entry to the 共編詞庫 after it's already been saved locally.
    /// Never blocks and never affects the local save — feedback is a transient
    /// label, not an NSAlert (a failed share must not interrupt the user).
    private func submitShareIfNeeded(_ entry: DojoCorrectionTable.Entry, share: Bool) {
        guard share else { return }
        DojoSharedSync.shared.submit(entry: entry) { [weak self] result in
            switch result {
            case .success(.ok):
                self?.flashDojoShareStatus("已送出待審核 ✓", color: DesignTokens.Palette.statusOK)
            case .success(.duplicate):
                self?.flashDojoShareStatus("這條已有人分享過",
                                           color: DesignTokens.Palette.inkMuted(0.55))
            case .failure(let err):
                inputSaLog("dojo share submit failed: \(err.localizedDescription)")
                self?.flashDojoShareStatus("分享失敗，詞條已存在本機",
                                           color: DesignTokens.Palette.statusWarn)
            }
        }
    }

    /// Show a brief message above the list card, then auto-clear.
    private func flashDojoShareStatus(_ text: String, color: NSColor) {
        guard let label = dojoShareStatusLabel else { return }
        label.stringValue = text
        label.textColor = color
        label.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak label] in
            label?.isHidden = true
            label?.stringValue = ""
        }
    }
}
