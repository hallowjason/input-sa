import AppKit
import ApplicationServices
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let inputController = InputController()
    private var statusItem: NSStatusItem?
    private var accessibilityPollTimer: Timer?
    private var aiModeMenu: NSMenu?

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🎙"
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
        menu.addItem(withTitle: "語音輸入：長按右 Option 錄音，放開後自動輸出", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "語音翻譯：長按右 Command 說中文，放開後輸出翻譯", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "關於 Input-sa", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "結束 Input-sa", action: #selector(quit), keyEquivalent: "q")
            .target = self
        statusItem?.menu = menu
    }

    // MARK: - AI 模式 submenu
    /// Rebuilt each time the menu opens so modes added/removed in Preferences
    /// show up without an app restart.
    func menuNeedsUpdate(_ menu: NSMenu) {
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
                    DispatchQueue.main.async { self.showMicrophonePermissionAlert() }
                }
            }
        case .denied, .restricted:
            NSLog("[InputSa] Microphone permission: denied — voice input will not work")
            showMicrophonePermissionAlert()
        @unknown default:
            break
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要麥克風權限"
        alert.informativeText = "Input-sa 需要麥克風權限才能使用語音輸入功能。\n\n請前往「系統設定 › 隱私與安全性 › 麥克風」，開啟 Input-sa 的存取權限，然後重新啟動 App。"
        alert.addButton(withTitle: "開啟系統設定")
        alert.addButton(withTitle: "稍後")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
}
