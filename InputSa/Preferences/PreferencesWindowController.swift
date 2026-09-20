import AppKit

/// Single-column settings with one always-visible row of page buttons. Existing
/// controls and persistence remain in the tab builders; the header only routes.
///
/// The builders live in sibling files (PreferencesVoiceServiceTab / …Shortcuts /
/// …Modes / …Dojo). Stored state stays here because Swift extensions can't add
/// stored properties; the members those files touch are therefore internal.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate,
                                          NSTextFieldDelegate {

    static let shared = PreferencesWindowController()

    // MARK: - Mute-while-recording toggle (read by InputController on record start)
    private static let muteWhileRecordingKey = "com.inputsa.muteWhileRecording"

    /// Whether to mute the system speaker while a PTT recording is active.
    /// Defaults to off — must not change existing users' behaviour.
    static var muteWhileRecording: Bool {
        get { UserDefaults.standard.bool(forKey: muteWhileRecordingKey) }
        set { UserDefaults.standard.set(newValue, forKey: muteWhileRecordingKey) }
    }

    // MARK: - UI (internal: the tab-builder extension files read/write these)
    var sidebar: PreferencesSidebar!
    var panes: [NSScrollView] = []
    // Voice-services pane
    var providerPicker: NSPopUpButton!
    var groqSection: NSView!
    var googleSection: NSView!
    var groqField: NSTextField!
    var googleSttField: NSTextField!
    var geminiField: NSTextField!
    var communityNicknameField: NSTextField!
    var providerStatusLabel: NSTextField!
    var providerStatusCaption: NSTextField!
    var providerStatusDot: StatusDotView!
    var polishProviderPicker: NSPopUpButton!
    var polishStatusLabel: NSTextField!
    var polishStatusCaption: NSTextField!
    var polishStatusDot: StatusDotView!
    var muteWhileRecordingSwitch: NSSwitch!
    var cleanupStylePicker: NSPopUpButton!
    var voiceProviderChoices: SoftChoiceGrid!
    var polishProviderChoices: SoftChoiceGrid!
    var cleanupStyleChoices: SoftSegmentedPicker!
    var cliConfigurationSection: NSView!
    var cliConnectionLabel: NSTextField!
    var cliConnectionTestButton: NSButton!
    var cliConnectionCancelButton: NSButton!
    var cliTestingProvider: APIKeyStore.PolishProvider?
    private var cliConnectionRequest: CLITextRequest?
    private var cliConnectionToken: UUID?
    static let polishProviders: [APIKeyStore.PolishProvider] = [.gemini, .apple, .codex, .claude]
    // Shortcuts pane — one recorder per action (all seven are user-rebindable)
    var shortcutRecorders: [ShortcutAction: ShortcutRecorderView] = [:]
    var shortcutWarningLabel: NSTextField!
    // Custom-modes pane
    var promptCardList: CardListView!
    var customPrompts: [UserStyleModel.CustomPrompt] = []
    // General vocabulary pane (legacy storage names preserve existing entries)
    var dojoCardList: CardListView!
    var dojoShareStatusLabel: NSTextField!
    var dojoCountLabel: NSTextField!
    var dojoEntries: [DojoCorrectionTable.Entry] = []
    /// Non-nil while the 🎙 voice-add button is recording.
    var voiceAddService: VoiceServiceProtocol?
    var voiceAddButton: AccentTextButton!
    // Usage-stats dashboard pane (value labels refreshed on show)
    var dashboardTodayChars: NSTextField?
    var dashboardTodaySegments: NSTextField?
    var dashboardTodayDuration: NSTextField?
    var dashboardTotalChars: NSTextField?
    var dashboardTotalSegments: NSTextField?
    var dashboardTotalDuration: NSTextField?
    var dashboardAvgChars: NSTextField?
    var dashboardChart: UsageBarChartView?

    private init() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 900)
        let initialSize = NSSize(width: min(DesignTokens.windowSize.width, visibleFrame.width - 40),
                                 height: min(DesignTokens.windowSize.height, visibleFrame.height - 60))
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Input-sa 偏好設定"
        // Keep a system window and native keyboard controls inside soft material.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = DesignTokens.Palette.canvas
        win.contentMinSize = NSSize(width: 620, height: 520)
        // Voice PTT and the preferences shortcut both work from inside fullscreen apps
        // (CGEventTap, not app-switch-dependent) — without this the window would open
        // on the user's regular desktop Space while they stay stuck looking at the
        // fullscreen app, appearing to do nothing.
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Setup
    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        sidebar = PreferencesSidebar(items: [
            .init(title: "語音與整理", symbol: "waveform"),
            .init(title: "快捷鍵", symbol: "keyboard"),
            .init(title: "字詞庫", symbol: "character.book.closed"),
            .init(title: "AI 模式", symbol: "sparkles"),
            .init(title: "使用統計", symbol: "chart.bar.xaxis"),
        ], selectedIndex: 0)
        sidebar.onSelect = { [weak self] idx in self?.showPane(idx) }

        panes = [
            makePane(title: "語音與整理", content: makeVoiceServiceContent()),
            makePane(title: "快捷鍵", content: makeShortcutsContent()),
            makePane(title: "字詞庫", content: makeDojoContent()),
            makePane(title: "AI 模式", content: makeModesContent()),
            makePane(title: "使用統計", content: makeDashboardContent()),
        ]

        contentView.addSubview(sidebar)
        for pane in panes { contentView.addSubview(pane) }

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sidebar.heightAnchor.constraint(equalToConstant: DesignTokens.preferencesHeaderHeight),
        ])
        for pane in panes {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: sidebar.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        showPane(0)
    }

    /// One scrolling content pane: 22-pt pane title, then the tab's groups.
    private func makePane(title: String, content: NSView) -> NSScrollView {
        let subtitles = [
            "語音與整理": "先選擇如何辨識，再決定用什麼整理。",
            "快捷鍵": "把常用動作放在順手的位置。",
            "AI 模式": "保留你的語氣，為不同情境安排不同格式。",
            "字詞庫": "人名、專有名詞與慣用拼寫，集中放在這裡。",
            "使用統計": "看看你用聲音留下了多少文字。",
        ]
        let heading = NSStackView(views: [DesignTokens.paneTitle(title),
            DesignTokens.caption(subtitles[title] ?? "")])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5
        let stack = NSStackView(views: [heading, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.edgeInsets = NSEdgeInsets(
            top: 8, left: DesignTokens.contentPadding,
            bottom: 48, right: DesignTokens.contentPadding)
        for child in [heading, content] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor,
                constant: -2 * DesignTokens.contentPadding).isActive = true
        }
        for label in heading.arrangedSubviews {
            label.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        }

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // Width follows the viewport so content never scrolls sideways.
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    /// Single source of truth for pane selection — the sidebar's click handler
    /// and any programmatic switch both land here, and this pushes the visual
    /// state back into the sidebar (no split-brain).
    private func showPane(_ index: Int) {
        guard (0..<panes.count).contains(index) else { return }
        shortcutRecorders.values.forEach { $0.cancelRecordingIfActive() }
        for (i, pane) in panes.enumerated() { pane.isHidden = (i != index) }
        sidebar.select(index)
        refreshDashboard()   // cheap + nil-safe; keeps the stats current on each show
        panes[index].documentView?.scroll(.zero)   // FlippedView: origin = top
    }

    // MARK: - Show
    func showPreferences() {
        // Refresh all fields each time (in case changed externally)
        groqField?.stringValue      = APIKeyStore.shared.groqKey
        geminiField?.stringValue    = APIKeyStore.shared.geminiKey
        googleSttField?.stringValue = APIKeyStore.shared.googleSttKey
        communityNicknameField?.stringValue =
            UserDefaults.standard.string(forKey: DojoSharedSync.nicknameKey) ?? ""
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   providerPicker?.selectItem(at: 0)
        case .google: providerPicker?.selectItem(at: 1)
        case .sherpa: providerPicker?.selectItem(at: 2)
        case .whisper: providerPicker?.selectItem(at: 3)
        }
        polishProviderPicker?.selectItem(at: Self.polishProviders.firstIndex(of: APIKeyStore.shared.polishProvider) ?? 0)
        cleanupStylePicker?.selectItem(at: DictationCleanupStyle.allCases.firstIndex(of: .selected) ?? 1)
        voiceProviderChoices?.select(providerPicker?.indexOfSelectedItem ?? 0)
        polishProviderChoices?.select(polishProviderPicker?.indexOfSelectedItem ?? 0)
        cleanupStyleChoices?.select(cleanupStylePicker?.indexOfSelectedItem ?? 1)
        updateServiceSectionVisibility()
        updateProviderStatus()
        updatePolishProviderStatus()
        for (action, recorder) in shortcutRecorders {
            recorder.setShortcut(ShortcutSettings.shared.shortcut(for: action))
        }
        updateShortcutWarning()
        reloadPromptCards()
        reloadDojoCards()
        refreshDashboard()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAlert(_ msg: String, info: String) {
        let a = NSAlert()
        a.messageText = msg
        a.informativeText = info
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        cancelCLIConnection()
        shortcutRecorders.values.forEach { $0.cancelRecordingIfActive() }
        saveAPIKeys()             // safety net: a field still mid-edit hasn't fired end-editing yet
        saveCommunityNickname()   // same safety net for the nickname field
        if let service = voiceAddService {   // 🎙 voice-add still recording
            service.cancelRecording()
            voiceAddService = nil
            resetVoiceAddButton()
        }
    }

    /// If the window loses key status mid-recording (user clicks another app, Cmd-Tabs
    /// away, etc.) without pressing a key or Esc, cancel it — otherwise the global
    /// CGEventTap stays bypassed (see cancelRecordingIfActive doc) with no way for the
    /// user to notice, since the window that would show "按下快捷鍵..." isn't even visible.
    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorders.values.forEach { $0.cancelRecordingIfActive() }
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        cancelCLIConnection()
    }

    /// Token invalidation happens before process cancellation because a runner
    /// may deliver its completion immediately as the child process exits.
    @objc func cancelCLIConnection() {
        cliConnectionToken = nil
        cliTestingProvider = nil
        let request = cliConnectionRequest
        cliConnectionRequest = nil
        request?.cancel()
        updatePolishProviderStatus()
    }

    @objc func testCLIConnection() {
        let provider = APIKeyStore.shared.polishProvider
        guard (provider == .codex || provider == .claude), cliTestingProvider == nil else { return }
        let token = UUID()
        cliConnectionToken = token
        cliTestingProvider = provider
        updatePolishProviderStatus()
        cliConnectionRequest = CLITextService.shared.checkConnection(provider: provider) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.cliConnectionToken == token else { return }
                self.cliConnectionToken = nil
                self.cliConnectionRequest = nil
                self.cliTestingProvider = nil
                self.updatePolishProviderStatus()
                guard APIKeyStore.shared.polishProvider == provider else { return }
                switch result {
                case .success(let text):
                    self.cliConnectionLabel.stringValue = "連線測試完成：\(text.prefix(180))"
                case .failure(let error):
                    self.cliConnectionLabel.stringValue = "測試未通過：\(error.localizedDescription.prefix(240))"
                }
            }
        }
    }
}
