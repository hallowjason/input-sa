import AppKit

/// General vocabulary pane. Numbered entries are spelling references for AI,
/// with no domain switch or automatic homophone replacement. Legacy property
/// names keep the existing storage and community integration compatible.
extension PreferencesWindowController {

    func makeDojoContent() -> NSView {
        // ── Numbered vocabulary list + footer actions ──────
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
        footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        let listCard = DesignTokens.groupCard([dojoCardList, footer])

        let hintLabel = DesignTokens.caption(
            "人名、專有名詞與常用字詞統一放在這裡，不用切換模式。AI 整理時會參考詞庫，" +
            "不再用同音規則強制替換；未使用 AI 時保留辨識文字。詞多時優先參考與本句相關的詞。" +
            "「共編」是其他使用者分享的詞條（唯讀）。")

        // Transient, non-blocking share feedback (kept empty/hidden until a submit
        // resolves) — deliberately not an NSAlert, so a failed share never
        // interrupts the user.
        dojoShareStatusLabel = WrappingTextField("")
        dojoShareStatusLabel.font = DesignTokens.uiFont(11, weight: .semibold)
        dojoShareStatusLabel.isHidden = true

        // ── Assemble ─────────────────────────────────────────
        let stack = NSStackView(views: [
            dojoShareStatusLabel,
            DesignTokens.group(title: "詞條", card: listCard, footnote: hintLabel),
            makeCommunityPreferencesSection(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.section
        stack.setCustomSpacing(7, after: dojoShareStatusLabel)
        for group in stack.arrangedSubviews {
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
        var rows = dojoEntries.enumerated().map {
            dojoRow(for: $0.element, number: $0.offset + 1, shared: false)
        }
        rows += DojoCorrectionTable.shared.sharedEntries.enumerated().map {
            dojoRow(for: $0.element, number: dojoEntries.count + $0.offset + 1, shared: true)
        }
        dojoCardList?.reload(rows: rows)
        dojoCountLabel?.stringValue = "\(rows.count) 詞條"
    }

    /// Numbers reflect the displayed order, not persistent IDs. Community rows
    /// remain read-only; personal row indexes still map directly to edit/delete.
    private func dojoRow(for e: DojoCorrectionTable.Entry, number: Int,
                         shared: Bool) -> CardListView.Row {
        let title = NSAttributedString(string: String(format: "%03d", number) + "  " + e.correct, attributes: [
            .font: DesignTokens.uiFont(13, weight: .semibold),
            .kern: -0.2,
            .foregroundColor: DesignTokens.Palette.ink,
        ])
        var subtitle = !e.wrong.isEmpty && e.wrong != e.correct
            ? "誤辨備註：\(e.wrong)" : "常用拼寫參考"
        if shared { subtitle += " · 社群分享" }
        let badges: [(text: String, style: DesignTokens.BadgeStyle)] =
            shared ? [("共編", .outline)] : []
        return CardListView.Row(
            title: title,
            subtitle: subtitle,
            badges: badges,
            isReadOnly: shared)
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
                                DojoEntrySheet.present(on: window, title: "確認新增字詞",
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
                showAlert("需要 Gemini API Key", info: "口頭加詞靠 Gemini 解析你說的釋義，請先在「語音服務」分頁填入。")
                return
            }
            let service: VoiceServiceProtocol
            switch APIKeyStore.shared.voiceProvider {
            case .groq:   service = GroqVoiceService()
            case .google: service = GoogleVoiceService()
            case .sherpa: service = SherpaVoiceService()
            case .whisper: service = WhisperVoiceService()
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
        DojoEntrySheet.present(on: window, title: "新增字詞", initial: nil) { [weak self] entry, share in
            guard let self, let entry else { return }
            var updated = self.dojoEntries
            updated.append(entry)
            self.applyDojoEntries(updated, failureMessage: "儲存失敗")
            self.submitShareIfNeeded(entry, share: share)
        }
    }

    private func editDojoEntry(at index: Int) {
        guard let window, index < dojoEntries.count else { return }
        DojoEntrySheet.present(on: window, title: "編輯字詞",
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
