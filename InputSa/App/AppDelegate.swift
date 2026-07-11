import AppKit
import ApplicationServices
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {

    let inputController = InputController()
    private var statusItem: NSStatusItem?
    private var accessibilityPollTimer: Timer?

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
        menu.addItem(withTitle: "語音輸入：長按右 Option 錄音，放開後自動輸出", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "語音翻譯：句尾說「請幫我翻譯成英文」，或長按右 Command", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "關於 Input-sa", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "結束 Input-sa", action: #selector(quit), keyEquivalent: "q")
            .target = self
        statusItem?.menu = menu
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
