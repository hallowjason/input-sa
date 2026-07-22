import AppKit

/// Preferences window, System Settings register (2026-07-16 redesign v3):
/// a translucent sidebar with four nav items on the left, and one scrolling
/// content pane per item on the right — grouped white-card rows on a neutral
/// canvas. The four `make…Content()` builders (one per tab file) return the
/// exact same control trees as before; only the container language changed.
/// No control, target/action, or data flow was altered.
///
/// The builders live in sibling files (PreferencesVoiceServiceTab / …Shortcuts /
/// …Modes / …Dojo). Stored state stays here because Swift extensions can't add
/// stored properties; the members those files touch are therefore internal.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate,
                                          NSTextFieldDelegate {

    static let shared = PreferencesWindowController()

    // MARK: - Dojo mode toggle storage (read by SherpaVoiceService per-transcription)
    private static let dojoModeKey = "com.inputsa.dojoMode"

    static var dojoMode: Bool {
        get { UserDefaults.standard.bool(forKey: dojoModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: dojoModeKey) }
    }

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
    // Shortcuts pane — one recorder per action (all seven are user-rebindable)
    var shortcutRecorders: [ShortcutAction: ShortcutRecorderView] = [:]
    var translatePopUp: NSPopUpButton!
    var shortcutWarningLabel: NSTextField!
    // Custom-modes pane
    var promptCardList: CardListView!
    var customPrompts: [UserStyleModel.CustomPrompt] = []
    // Dojo vocabulary pane
    var dojoCardList: CardListView!
    var dojoShareStatusLabel: NSTextField!
    var dojoCountLabel: NSTextField!
    var dojoEntries: [DojoCorrectionTable.Entry] = []
    var dojoModeSwitch: NSSwitch!
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
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: DesignTokens.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Input-sa 偏好設定"
        // System Settings look: the sidebar material runs under the title bar,
        // traffic lights float over it. Title stays set for Mission Control/a11y.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = DesignTokens.Palette.canvas
        // Voice PTT and the preferences shortcut both work from inside fullscreen apps
        // (CGEventTap, not app-switch-dependent) — without this the window would open
        // on the user's regular desktop Space while they stay stuck looking at the
        // fullscreen app, appearing to do nothing.
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup
    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        sidebar = PreferencesSidebar(items: [
            .init(title: "語音服務", symbol: "waveform"),
            .init(title: "快捷鍵", symbol: "keyboard"),
            .init(title: "AI 模式", symbol: "sparkles"),
            .init(title: "道場詞庫", symbol: "character.book.closed"),
            .init(title: "使用統計", symbol: "chart.bar.xaxis"),
        ], selectedIndex: 0)
        sidebar.onSelect = { [weak self] idx in self?.showPane(idx) }

        panes = [
            makePane(title: "語音服務", content: makeVoiceServiceContent()),
            makePane(title: "快捷鍵", content: makeShortcutsContent()),
            makePane(title: "AI 模式", content: makeModesContent()),
            makePane(title: "道場詞庫", content: makeDojoContent()),
            makePane(title: "使用統計", content: makeDashboardContent()),
        ]

        contentView.addSubview(sidebar)
        for pane in panes { contentView.addSubview(pane) }

        NSLayoutConstraint.activate([
            // Fixed window size — the styleMask has no .resizable, and pinning
            // the content view keeps Auto Layout from shrinking the window to
            // any subview's fitting width.
            contentView.widthAnchor.constraint(equalToConstant: DesignTokens.windowSize.width),
            contentView.heightAnchor.constraint(equalToConstant: DesignTokens.windowSize.height),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: DesignTokens.sidebarWidth),
        ])
        for pane in panes {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: contentView.topAnchor),
                pane.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                pane.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        showPane(0)
    }

    /// One scrolling content pane: 22-pt pane title, then the tab's groups.
    private func makePane(title: String, content: NSView) -> NSScrollView {
        let stack = NSStackView(views: [DesignTokens.paneTitle(title), content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(
            top: 32, left: DesignTokens.contentPadding,
            bottom: 30, right: DesignTokens.contentPadding)
        content.widthAnchor.constraint(
            equalToConstant: DesignTokens.contentWidth).isActive = true

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
        }
        polishProviderPicker?.selectItem(at: APIKeyStore.shared.polishProvider == .apple ? 1 : 0)
        updateServiceSectionVisibility()
        updateProviderStatus()
        updatePolishProviderStatus()
        for (action, recorder) in shortcutRecorders {
            recorder.setShortcut(ShortcutSettings.shared.shortcut(for: action))
        }
        updateShortcutWarning()
        reloadPromptCards()
        dojoModeSwitch?.state = PreferencesWindowController.dojoMode ? .on : .off
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
}
