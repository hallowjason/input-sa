import AppKit
import ApplicationServices
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let inputController = InputController()
    private var statusItem: NSStatusItem?
    private var accessibilityPollTimer: Timer?
    private var aiModeMenu: NSMenu?
    private var sharedSyncTimer: Timer?
    /// Disabled "今日：N 字・M 次" row, retitled whenever the menu opens.
    private var todaySummaryItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Request microphone permission (required for AVAudioRecorder).
        // Must be requested at launch — AVAudioRecorder silently records silence when denied.
        requestMicrophonePermission()

        // Request / check Accessibility permission (required for CGEventTap + AXUIElement)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("[InputSa] Accessibility trusted: \(trusted)")

        if trusted {
            inputController.start()
        } else {
            accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.accessibilityPollTimer = nil
                    self?.inputController.start()
                    NSLog("[InputSa] Accessibility granted — CGEventTap started")
                }
            }
        }

        // Pull the community-shared dojo vocabulary. Fire-and-forget and off the
        // transcription path — needs no Accessibility permission, only network.
        startSharedVocabSync()

        // Fail fast on a broken install: the local model ships inside the app
        // bundle, so a missing model is an install problem, not a user problem —
        // surface it now instead of on the first transcription attempt.
        if APIKeyStore.shared.voiceProvider == .sherpa && !SherpaVoiceService.modelInstalled {
            inputSaLog("launch check: local model missing from bundle")
            let alert = NSAlert()
            alert.messageText = "安裝不完整"
            alert.informativeText = "找不到本地語音模型（model.int8.onnx / tokens.txt）。請重新執行 install.sh 或重新下載完整安裝包。"
            alert.runModal()
        }
    }

    /// Sync the 共編詞庫 once at launch, then every 24h (this is a long-lived
    /// menu-bar app). Failures are silent — offline is a normal state.
    private func startSharedVocabSync() {
        DojoSharedSync.shared.syncNow()
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            DojoSharedSync.shared.syncNow()
        }
        timer.tolerance = 60 * 60   // generous — this is a background refresh, not time-critical
        sharedSyncTimer = timer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Geometric volume-bars mark as a template image — adapts to
            // light/dark menu bars and highlight states. Falls back to the
            // old emoji if the resource is somehow missing from the bundle.
            if let path = Bundle.main.path(forResource: "inputsa-menu@2x", ofType: "png"),
               let icon = NSImage(contentsOfFile: path) {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                button.title = "🎙"
            }
            button.toolTip = "Input-sa — 語音輸入 & 文字潤飾"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "偏好設定...", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        menu.addItem(NSMenuItem.separator())

        // AI 模式 quick pick — the invocation point for custom prompts defined
        // in Preferences (they had no way to be applied before this submenu).
        let aiModeItem = NSMenuItem(title: "AI 模式", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "AI 模式")
        submenu.delegate = self   // repopulated on every open via menuNeedsUpdate
        aiModeItem.submenu = submenu
        aiModeMenu = submenu
        menu.addItem(aiModeItem)
        menu.addItem(NSMenuItem.separator())
        // Today's usage summary — disabled (informational), retitled on open.
        let todayItem = NSMenuItem(title: "今日：0 字・0 次", action: nil, keyEquivalent: "")
        todayItem.isEnabled = false
        todaySummaryItem = todayItem
        menu.addItem(todayItem)
        menu.addItem(withTitle: "語音輸入：長按右 Option 錄音，放開後自動輸出", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "語音翻譯：長按右 Command 說中文，放開後輸出翻譯", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "劃詞問答：選字後長按 Ctrl+Option+Q 說問題，浮窗顯示答案", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "劃詞翻譯：選字後按 Ctrl+Option+T，浮窗顯示譯文", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "系統診斷...", action: #selector(runDiagnostics), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "關於 Input-sa", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "結束 Input-sa", action: #selector(quit), keyEquivalent: "q")
            .target = self
        // Delegate drives menuNeedsUpdate for the today summary (the AI 模式
        // submenu has its own delegate assignment above).
        menu.delegate = self
        statusItem?.menu = menu
    }

    // MARK: - AI 模式 submenu
    /// Rebuilt each time the menu opens so modes added/removed in Preferences
    /// show up without an app restart.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Top-level status menu: refresh the today summary and stop.
        if menu === statusItem?.menu {
            let today = UsageStatsStore.shared.today()
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let chars = f.string(from: NSNumber(value: today.chars)) ?? "\(today.chars)"
            let segs = f.string(from: NSNumber(value: today.segments)) ?? "\(today.segments)"
            todaySummaryItem?.title = "今日：\(chars) 字・\(segs) 次"
            return
        }
        guard menu === aiModeMenu else { return }
        menu.removeAllItems()
        let activeID = TranscriptionMode.activeCustomPromptID

        let standardItem = NSMenuItem(title: "📝 標準潤飾", action: #selector(selectAIMode(_:)),
                                      keyEquivalent: "")
        standardItem.target = self
        standardItem.representedObject = nil as String?
        standardItem.state = activeID == nil ? .on : .off
        menu.addItem(standardItem)

        let prompts = UserStyleModel.shared.customPrompts
        if !prompts.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for prompt in prompts {
            let item = NSMenuItem(title: "\(prompt.emoji) \(prompt.name)",
                                  action: #selector(selectAIMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = prompt.id
            item.state = prompt.id == activeID ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectAIMode(_ sender: NSMenuItem) {
        TranscriptionMode.activeCustomPromptID = sender.representedObject as? String
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showPreferences()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func runDiagnostics() {
        SelfDiagnostics.presentReport()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            NSLog("[InputSa] Microphone permission: already authorized")
        case .notDetermined:
            // First run — ask the user. The system dialog appears automatically.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[InputSa] Microphone permission: \(granted ? "granted" : "denied")")
                if !granted {
                    DispatchQueue.main.async { SelfDiagnostics.presentMicPermissionRecovery() }
                }
            }
        case .denied, .restricted:
            // Includes the stale-TCC state (toggle shows ON but the grant no
            // longer matches this binary's signature) — the recovery dialog
            // offers the tccutil reset that actually fixes it.
            NSLog("[InputSa] Microphone permission: denied — voice input will not work")
            SelfDiagnostics.presentMicPermissionRecovery()
        @unknown default:
            break
        }
    }
}
