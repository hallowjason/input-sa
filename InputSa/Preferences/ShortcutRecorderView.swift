import AppKit

/// A simple view that records keyboard shortcuts.
/// Click to enter recording mode, press a key combo, click away to cancel.
final class ShortcutRecorderView: NSView {

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt16
        var modifierFlags: UInt  // NSEvent.ModifierFlags.rawValue

        var displayString: String {
            var parts: [String] = []
            let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
            if flags.contains(.control)  { parts.append("⌃") }
            if flags.contains(.option)   { parts.append("⌥") }
            if flags.contains(.shift)    { parts.append("⇧") }
            if flags.contains(.command)  { parts.append("⌘") }
            parts.append(Self.keyCodeLabel(keyCode))
            return parts.joined()
        }

        /// Converts a HID keycode (Carbon/AppKit) to a display label.
        /// UnicodeScalar(keyCode) is WRONG — keycodes are HID scancodes, not ASCII.
        private static func keyCodeLabel(_ kc: UInt16) -> String {
            let map: [UInt16: String] = [
                // Special keys
                36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
                76: "↩",  // numpad enter
                // Function keys
                122: "F1", 120: "F2", 99: "F3", 118: "F4",
                96: "F5",  97: "F6",  98: "F7", 100: "F8",
                101: "F9", 109: "F10", 103: "F11", 111: "F12",
                // Letter keys (HID scancode → letter, layout-independent)
                0: "A", 1: "S",  2: "D",  3: "F",  4: "H",
                5: "G", 6: "Z",  7: "X",  8: "C",  9: "V",
                11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 31: "O", 32: "U", 34: "I",
                35: "P", 37: "L", 38: "J", 40: "K", 45: "N",
                46: "M",
                // Number keys
                18: "1", 19: "2", 20: "3", 21: "4",
                22: "6", 23: "5", 25: "9", 26: "7",
                28: "8", 29: "0",
                // Punctuation
                24: "=", 27: "-", 30: "]", 33: "[",
                39: "'", 41: ";", 42: "\\", 43: ",",
                44: "/", 47: ".", 50: "`",
            ]
            return map[kc] ?? "[\(kc)]"
        }

        func matches(event: NSEvent) -> Bool {
            return event.keyCode == keyCode &&
                   event.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue == modifierFlags
        }
    }

    // MARK: - Shared capturing flag
    /// Set to true while recording so CGEventTap knows to pass all events through.
    static var isCapturing: Bool = false

    // MARK: - State
    private(set) var shortcut: Shortcut?
    private var isRecording = false
    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?

    var onChange: ((Shortcut?) -> Void)?

    // MARK: - Init
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    /// Placed inside `NSStackView`s, which force `translatesAutoresizingMaskIntoConstraints
    /// = false` on arranged subviews and then discard the frame this view was constructed
    /// with. Without an intrinsic size, Auto Layout collapses it to 0×0 — the border still
    /// paints (layer draws regardless), but there is no hit-testable area, so real mouse
    /// clicks land on whatever is behind it instead of triggering `mouseDown`.
    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 28)
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.8, alpha: 1).cgColor
        layer?.backgroundColor = NSColor.white.cgColor

        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(white: 0.3, alpha: 1)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateDisplay()
    }

    private func updateDisplay() {
        if isRecording {
            label.stringValue = "按下快捷鍵..."
            label.textColor = NSColor.systemBlue
            layer?.borderColor = NSColor.systemBlue.cgColor
        } else if let sc = shortcut {
            label.stringValue = sc.displayString
            label.textColor = NSColor(white: 0.2, alpha: 1)
            layer?.borderColor = NSColor(white: 0.8, alpha: 1).cgColor
        } else {
            label.stringValue = "點擊設定"
            label.textColor = NSColor(white: 0.6, alpha: 1)
            layer?.borderColor = NSColor(white: 0.8, alpha: 1).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        ShortcutRecorderView.isCapturing = true   // tell CGEventTap to step aside
        updateDisplay()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }

            // Esc cancels recording without saving
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            // Any other key — modifier or not — becomes the shortcut. Previously this
            // required at least one modifier (or a standalone function key) and silently
            // discarded anything else, which left recording mode stuck forever with zero
            // feedback on an unmodified keypress. Stuck recording mode is worse than a
            // permissive shortcut: it leaves ShortcutRecorderView.isCapturing = true, which
            // tells the global CGEventTap to pass every key through unmodified — disabling
            // voice PTT and Ctrl+Option+P system-wide until the user finds Esc.
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            self.shortcut = Shortcut(keyCode: event.keyCode, modifierFlags: flags.rawValue)
            self.onChange?(self.shortcut)
            self.stopRecording()
            return nil
        }
    }

    /// Safety net: if recording is somehow still active when this view is about to
    /// disappear from the key hierarchy (window closed/resigned key while capturing),
    /// cancel it so the CGEventTap bypass in InputController can never get stuck on.
    func cancelRecordingIfActive() {
        guard isRecording else { return }
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        ShortcutRecorderView.isCapturing = false   // restore tap
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        updateDisplay()
    }

    func setShortcut(_ sc: Shortcut?) {
        shortcut = sc
        updateDisplay()
    }
}
