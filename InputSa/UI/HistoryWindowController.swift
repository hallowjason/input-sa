import AppKit

/// Local transcript recovery. Copying and clearing are explicit user actions;
/// this window never inserts text into another app or replays audio.
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = HistoryWindowController()

    private let store: TranscriptHistoryStore
    private var records: [TranscriptHistoryStore.Entry] = []
    private var selectedID: UUID?
    private var observer: NSObjectProtocol?
    private let table = NSTableView()
    private let recordingSwitch = NSSwitch()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let metadataLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "還沒有口述紀錄")
    private let rawView = NSTextView()
    private let resultView = NSTextView()
    private let stagePicker = NSPopUpButton()
    private var copyRawButton: NSButton!
    private var copyResultButton: NSButton!
    private var clearButton: NSButton!
    private let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
    private let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    init(store: TranscriptHistoryStore = .shared) {
        self.store = store
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 650),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "口述紀錄 — Input-sa"
        win.minSize = NSSize(width: 900, height: 540)
        win.backgroundColor = DesignTokens.Palette.canvas
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        super.init(window: win)
        setupUI()
        observer = NotificationCenter.default.addObserver(
            forName: TranscriptHistoryStore.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in self?.reload() }
        reload()
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let title = DesignTokens.paneTitle("找回每一句話")
        let enabledLabel = NSTextField(labelWithString: "記錄口述")
        enabledLabel.font = DesignTokens.uiFont(12)
        recordingSwitch.target = self
        recordingSwitch.action = #selector(toggleRecording)
        recordingSwitch.setAccessibilityLabel("記錄口述")
        clearButton = DesignTokens.pushButton(title: "清空紀錄…", target: self, action: #selector(clearHistory))
        clearButton.contentTintColor = DesignTokens.Palette.destructive
        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, enabledLabel, recordingSwitch, clearButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        title.setContentHuggingPriority(.required, for: .horizontal)

        summaryLabel.font = DesignTokens.uiFont(12)
        summaryLabel.textColor = DesignTokens.Palette.inkMuted()
        summaryLabel.maximumNumberOfLines = 2

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.width = 260
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.style = .sourceList
        table.backgroundColor = .clear
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("口述紀錄清單")
        listScroll.documentView = table
        emptyLabel.font = DesignTokens.uiFont(13)
        emptyLabel.textColor = DesignTokens.Palette.inkMuted()
        emptyLabel.alignment = .center

        metadataLabel.font = DesignTokens.uiFont(12)
        metadataLabel.textColor = DesignTokens.Palette.inkMuted()
        metadataLabel.maximumNumberOfLines = 3
        metadataLabel.setContentHuggingPriority(.required, for: .vertical)
        let rawTitle = NSTextField(labelWithString: "辨識原文")
        rawTitle.font = DesignTokens.uiFont(13, weight: .semibold)
        stagePicker.addItems(withTitles: ["實際輸出", "繁體原稿", "AI 整理"])
        stagePicker.font = DesignTokens.uiFont(12)
        stagePicker.target = self
        stagePicker.action = #selector(changeStage)
        stagePicker.setAccessibilityLabel("結果階段")
        copyRawButton = DesignTokens.pushButton(title: "複製原文", target: self, action: #selector(copyRaw))
        copyResultButton = DesignTokens.pushButton(title: "複製輸出", target: self, action: #selector(copyResult))
        let rawPanel = textPanel(heading: rawTitle, textView: rawView, button: copyRawButton)
        let resultPanel = textPanel(heading: stagePicker, textView: resultView, button: copyResultButton)
        rawView.setAccessibilityLabel("原始語音辨識文字")
        resultView.setAccessibilityLabel("所選階段文字")
        let comparison = NSStackView(views: [rawPanel, resultPanel])
        comparison.orientation = .horizontal
        comparison.alignment = .top
        comparison.distribution = .fillEqually
        comparison.spacing = 14
        rawPanel.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true
        resultPanel.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true

        noticeLabel.font = DesignTokens.uiFont(11)
        noticeLabel.textColor = DesignTokens.Palette.inkMuted()
        noticeLabel.maximumNumberOfLines = 3
        noticeLabel.setContentHuggingPriority(.required, for: .vertical)
        let detail = NSStackView(views: [metadataLabel, comparison, noticeLabel])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        for view in [metadataLabel, comparison, noticeLabel] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        let body = NSView()
        for view in [listScroll, detail, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: body.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 260),
            detail.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 20),
            detail.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            detail.topAnchor.constraint(equalTo: body.topAnchor),
            detail.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: listScroll.widthAnchor, constant: -32),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        let root = NSStackView(views: [header, summaryLabel, body])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        for view in [header, summaryLabel, body] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }

    private func textPanel(heading: NSView, textView: NSTextView, button: NSButton) -> NSStackView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = DesignTokens.Palette.card
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = DesignTokens.uiFont(14)
        textView.textColor = DesignTokens.Palette.ink
        textView.backgroundColor = DesignTokens.Palette.card
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 260, height: 100)
        scroll.documentView = textView
        let panel = NSStackView(views: [heading, scroll, button])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 8
        heading.heightAnchor.constraint(equalToConstant: 24).isActive = true
        scroll.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return panel
    }

    private var selectedEntry: TranscriptHistoryStore.Entry? {
        guard let selectedID else { return nil }
        return records.first { $0.id == selectedID }
    }

    private func reload() {
        let previousSelection = selectedID
        records = store.entries
        recordingSwitch.state = store.isEnabled ? .on : .off
        if let error = store.loadErrorDescription {
            summaryLabel.stringValue = "紀錄讀取失敗，已暫停新增。既有檔案保留，清空後可重新啟用。"
            summaryLabel.toolTip = error
        } else {
            summaryLabel.stringValue = "僅存在這台 Mac，最多保留最近 200 筆，不保存錄音。" +
                (store.isEnabled ? "目前有 \(records.count) 筆。" : "已暫停新增，既有紀錄仍可查看。")
            summaryLabel.toolTip = nil
        }
        clearButton.isEnabled = !records.isEmpty || store.loadErrorDescription != nil
        emptyLabel.isHidden = !records.isEmpty
        table.reloadData()
        if let index = records.firstIndex(where: { $0.id == previousSelection }) {
            selectedID = previousSelection
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !records.isEmpty {
            selectedID = records[0].id
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedID = nil
            table.deselectAll(nil)
        }
        refreshDetail()
    }

    private func refreshDetail() {
        guard let entry = selectedEntry else {
            metadataLabel.stringValue = "選擇一段口述，對照辨識原文與最後輸出。"
            rawView.string = ""
            resultView.string = ""
            noticeLabel.stringValue = "需要找回原稿時，選取紀錄並按「複製原文」。"
            copyRawButton.isEnabled = false
            copyResultButton.isEnabled = false
            stagePicker.isEnabled = false
            return
        }
        let date = detailDateFormatter.string(from: entry.date)
        let duration = String(format: "%.1f", Double(entry.durationMs) / 1000)
        let app = entry.appName ?? entry.appBundleID ?? "未記錄 App"
        let changed = entry.wasEdited ? "整理後有變更" : "整理後未變更"
        metadataLabel.stringValue = "\(date) · \(entry.engine) · \(duration) 秒\n\(app) · \(entry.status.displayName) · \(changed)"
        metadataLabel.toolTip = entry.appBundleID
        rawView.string = entry.rawText
        switch stagePicker.indexOfSelectedItem {
        case 1:
            resultView.string = entry.normalizedText
            copyResultButton.title = "複製繁體原稿"
        case 2:
            resultView.string = entry.aiText ?? "這次未取得 AI 整理結果。"
            copyResultButton.title = "複製 AI 整理"
        default:
            resultView.string = entry.finalText
            copyResultButton.title = "複製實際輸出"
        }
        noticeLabel.stringValue = entry.fallbackReason.map { "本次處理備註：\($0)" }
            ?? "「已送往 App」表示已發送輸入，不代表目標 App 已確認接收。"
        noticeLabel.toolTip = entry.fallbackReason
        copyRawButton.isEnabled = !entry.rawText.isEmpty
        copyResultButton.isEnabled = selectedStageText(for: entry).map { !$0.isEmpty } ?? false
        stagePicker.isEnabled = true
        rawView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        resultView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let entry = records[row]
        let cell = HistoryCellView()
        let text = entry.finalText.isEmpty ? entry.normalizedText : entry.finalText
        cell.preview.stringValue = text.replacingOccurrences(of: "\n", with: " ")
        cell.caption.stringValue = "\(rowDateFormatter.string(from: entry.date)) · \(entry.appName ?? "口述") · \(entry.status.displayName)"
        cell.toolTip = cell.preview.stringValue
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedID = records.indices.contains(table.selectedRow) ? records[table.selectedRow].id : nil
        refreshDetail()
    }

    @objc private func changeStage() { refreshDetail() }

    @objc private func toggleRecording() {
        do { try store.setEnabled(recordingSwitch.state == .on) }
        catch { recordingSwitch.state = store.isEnabled ? .on : .off; showError(error) }
    }

    @objc private func copyRaw() {
        guard let entry = selectedEntry else { return }
        copy(entry.rawText, notice: "已複製辨識原文。")
    }

    @objc private func copyResult() {
        guard let entry = selectedEntry, let text = selectedStageText(for: entry), !text.isEmpty else { return }
        copy(text, notice: "已複製目前顯示的文字。")
    }

    private func selectedStageText(for entry: TranscriptHistoryStore.Entry) -> String? {
        switch stagePicker.indexOfSelectedItem {
        case 1: return entry.normalizedText
        case 2: return entry.aiText
        default: return entry.finalText
        }
    }

    private func copy(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { noticeLabel.stringValue = notice }
    }

    @objc private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空這台 Mac 的口述紀錄？"
        alert.informativeText = "已保存的原稿與結果將全部刪除，無法還原。已輸入其他 App 的文字不受影響。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空紀錄")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.clear() } catch { self.showError(error) }
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "口述紀錄未儲存"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
}

private final class HistoryCellView: NSTableCellView {
    let preview = NSTextField(labelWithString: "")
    let caption = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        preview.font = DesignTokens.uiFont(13, weight: .medium)
        preview.lineBreakMode = .byTruncatingTail
        caption.font = DesignTokens.uiFont(10)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [preview, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        textField = preview
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
