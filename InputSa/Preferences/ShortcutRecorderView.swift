import AppKit

/// A simple view that records keyboard shortcuts.
/// Click to enter recording mode, press a key combo, click away to cancel.
final class ShortcutRecorderView: NSView {

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt16
        var modifierFlags: UInt  // NSEvent.ModifierFlags.rawValue

        var displayString: String {
            // A modifier-only chord (hold right-Option etc.) reads as just the
            // side + symbol; the mask would otherwise duplicate the modifier.
            if Self.modifierKeyCodes.contains(keyCode) {
                return Self.modifierKeyCodeLabel(keyCode)
            }
            var parts: [String] = []
            let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
            if flags.contains(.control)  { parts.append("⌃") }
            if flags.contains(.option)   { parts.append("⌥") }
            if flags.contains(.shift)    { parts.append("⇧") }
            if flags.contains(.command)  { parts.append("⌘") }
            parts.append(Self.keyCodeLabel(keyCode))
            return parts.joined()
        }

        /// Side-aware label for a physical modifier key (used for modifier-only
        /// chords). e.g. keyCode 61 → "右 ⌥".
        static func modifierKeyCodeLabel(_ kc: UInt16) -> String {
            switch kc {
            case 54: return "右 ⌘"
            case 55: return "左 ⌘"
            case 56: return "左 ⇧"
            case 57: return "⇪"
            case 58: return "左 ⌥"
            case 59: return "左 ⌃"
            case 60: return "右 ⇧"
            case 61: return "右 ⌥"
            case 62: return "右 ⌃"
            case 63: return "fn"
            default: return "[\(kc)]"
            }
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
    /// The single recorder currently capturing (there are seven on the pane now).
    /// Starting one stops any other so two never hold live monitors at once.
    private static weak var capturingRecorder: ShortcutRecorderView?

    // MARK: - State
    private(set) var shortcut: Shortcut?
    private var isRecording = false
    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?
    // Modifier-only capture bookkeeping (a tap on a bare modifier = hold chord).
    private var sawKeyDown = false
    private var pendingModifierKeyCode: UInt16?
    private var pendingModifierMask: UInt = 0

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
        // Only one recorder captures at a time — stop any sibling first so we never
        // leave a second live monitor (or a stuck isCapturing) behind.
        ShortcutRecorderView.capturingRecorder?.stopRecording()
        ShortcutRecorderView.capturingRecorder = self
        isRecording = true
        sawKeyDown = false
        pendingModifierKeyCode = nil
        pendingModifierMask = 0
        ShortcutRecorderView.isCapturing = true   // tell CGEventTap to step aside
        updateDisplay()

        // Both keyDown (key + modifier combos) and flagsChanged (bare-modifier
        // hold chords like right-Option) so every action is recordable.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }

            if event.type == .flagsChanged {
                self.handleFlagsChangedWhileRecording(event)
                return nil
            }

            // Esc cancels recording without saving
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            // Any other key — with or without modifiers — becomes a combo shortcut.
            // Permissive on purpose: leaving recording mode stuck (isCapturing = true)
            // would tell the global CGEventTap to pass every key through unmodified,
            // disabling all shortcuts system-wide until the user finds Esc.
            self.sawKeyDown = true
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            self.commit(Shortcut(keyCode: event.keyCode, modifierFlags: flags.rawValue))
            return nil
        }
    }

    /// Track modifier presses so a *tap on a bare modifier* (press then release
    /// with no other key in between) records as a modifier-only hold chord.
    private func handleFlagsChangedWhileRecording(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let count = [NSEvent.ModifierFlags.control, .option, .shift, .command]
            .filter { mods.contains($0) }.count
        if count == 1 {
            // Exactly one pure modifier held — remember this physical key as the
            // candidate (side matters: right-Option ≠ left-Option).
            pendingModifierKeyCode = event.keyCode
            pendingModifierMask = mods.rawValue
        } else if mods.isEmpty {
            // Everything released. A single-modifier tap with no keyDown commits
            // as a hold chord; a released half-built combo commits nothing.
            if !sawKeyDown, let kc = pendingModifierKeyCode {
                commit(Shortcut(keyCode: kc, modifierFlags: pendingModifierMask))
            }
            pendingModifierKeyCode = nil
        }
        // count >= 2: building a combo — wait for the keyDown (or a full release).
    }

    private func commit(_ sc: Shortcut) {
        shortcut = sc
        onChange?(sc)
        stopRecording()
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
        if ShortcutRecorderView.capturingRecorder === self {
            ShortcutRecorderView.capturingRecorder = nil
        }
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
