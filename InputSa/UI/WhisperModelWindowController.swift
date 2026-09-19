import AppKit

/// Optional local model download. Opening the window never starts a transfer.
final class WhisperModelWindowController: NSWindowController {
    static let shared = WhisperModelWindowController()
    private let manager: ModelManager
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton(title: "下載模型", target: nil, action: nil)
    private var observer: NSObjectProtocol?

    init(manager: ModelManager = .shared) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 310),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Whisper 本地模型 — Input-sa"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        guard let root = window.contentView else { return }
        let title = NSTextField(labelWithString: "在這台 Mac 上辨識")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString:
            "Whisper large-v3-turbo · 約 1.6 GB\n支援多語言與錄音暫時字幕。模型下載完成後，可在語音服務選擇「本地 Whisper Turbo」。")
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.bezelStyle = .rounded
        let note = NSTextField(wrappingLabelWithString:
            "從官方模型來源下載並驗證完整性。支援暫停續傳；下載後的辨識不需要網路。AI 整理是否連網，仍由所選服務決定。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, description, statusLabel, progress, actionButton, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        observer = NotificationCenter.default.addObserver(forName: ModelManager.didChange, object: manager, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        progress.doubleValue = 0
        actionButton.isEnabled = true
        if let reason = WhisperRuntime.unavailabilityReason {
            statusLabel.stringValue = reason
            actionButton.isEnabled = false
            return
        }
        guard WhisperRuntime.runtimeInstalled else {
            statusLabel.stringValue = "此安裝包缺少 Whisper 執行程式，請安裝完整版本。"
            actionButton.isEnabled = false
            return
        }
        switch manager.state {
        case .missing:
            statusLabel.stringValue = "尚未下載"
            actionButton.title = "下載模型（約 1.6 GB）"
        case .downloading(let fraction):
            progress.doubleValue = fraction
            statusLabel.stringValue = "下載中 · \(Int(fraction * 100))%"
            actionButton.title = "暫停下載"
        case .verifying:
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            statusLabel.stringValue = "正在驗證模型完整性…"
            actionButton.title = "驗證中"
            actionButton.isEnabled = false
        case .ready:
            progress.doubleValue = 1
            statusLabel.stringValue = "模型已就緒，可在語音服務切換使用。"
            actionButton.title = "已下載並驗證"
            actionButton.isEnabled = false
        case .paused:
            statusLabel.stringValue = "下載已暫停，進度已保留。"
            actionButton.title = "繼續下載"
        case .failed(let reason):
            statusLabel.stringValue = reason
            actionButton.title = "重試下載"
        }
    }

    @objc private func performAction() {
        switch manager.state {
        case .downloading: manager.cancel()
        case .missing, .paused, .failed: manager.download()
        case .verifying, .ready: break
        }
    }
}
