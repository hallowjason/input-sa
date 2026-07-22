import AppKit

/// The seven user-facing shortcut actions. Each one owns a display name, a
/// shipping default, and whether it is a hold (push-to-talk) or a single press.
/// The event tap (`InputController.handle`) is driven entirely by this registry
/// plus `ShortcutSettings`, so every action is user-rebindable from Preferences.
enum ShortcutAction: String, CaseIterable {
    case dictation          // 語音聽寫   (hold)
    case translate          // 即時翻譯   (hold)
    case correction         // 口頭修正   (hold)
    case manualPolish       // 選字潤飾   (press)
    case selectionQA        // 劃詞問答   (hold)
    case selectionTranslate // 劃詞翻譯   (press)
    case preferences        // 偏好設定   (press)

    /// Hold = push-to-talk (start on key-down, act on release). Press = fire once.
    var isHold: Bool {
        switch self {
        case .dictation, .translate, .correction, .selectionQA: return true
        case .manualPolish, .selectionTranslate, .preferences:  return false
        }
    }

    var titleZh: String {
        switch self {
        case .dictation:          return "語音聽寫"
        case .translate:          return "即時翻譯"
        case .correction:         return "口頭修正"
        case .manualPolish:       return "選字潤飾"
        case .selectionQA:        return "劃詞問答"
        case .selectionTranslate: return "劃詞翻譯"
        case .preferences:        return "偏好設定"
        }
    }

    var subtitleZh: String {
        switch self {
        case .dictation:          return "說話 → 轉錄 → AI 潤飾 → 輸出至游標"
        case .translate:          return "說中文，翻譯成目標語言輸出"
        case .correction:         return "說詞條釋義，Enter 確認加入道場詞庫"
        case .manualPolish:       return "選取文字後按，Enter 接受、Esc 取消"
        case .selectionQA:        return "選取文字後按住說問題，放開顯示答案"
        case .selectionTranslate: return "選取文字後按，浮窗顯示譯文（英／泰）"
        case .preferences:        return "開啟本視窗"
        }
    }

    /// The shipping default binding. Hold actions default to a bare right-side
    /// modifier chord (walkie-talkie feel); press/selection actions default to a
    /// key + modifier combo.
    var defaultShortcut: ShortcutRecorderView.Shortcut {
        typealias SC = ShortcutRecorderView.Shortcut
        let opt = NSEvent.ModifierFlags.option.rawValue
        let ctrlOpt = NSEvent.ModifierFlags([.control, .option]).rawValue
        switch self {
        case .dictation:          return SC(keyCode: 61, modifierFlags: opt)        // 右 ⌥
        case .translate:          return SC(keyCode: 54, modifierFlags: NSEvent.ModifierFlags.command.rawValue) // 右 ⌘
        case .correction:         return SC(keyCode: 60, modifierFlags: NSEvent.ModifierFlags.shift.rawValue)   // 右 ⇧
        case .manualPolish:       return SC(keyCode: 35, modifierFlags: opt)        // ⌥P
        case .selectionQA:        return SC(keyCode: 12, modifierFlags: ctrlOpt)    // ⌃⌥Q
        case .selectionTranslate: return SC(keyCode: 17, modifierFlags: ctrlOpt)    // ⌃⌥T
        case .preferences:        return SC(keyCode: 35, modifierFlags: ctrlOpt)    // ⌃⌥P
        }
    }
}

extension ShortcutRecorderView.Shortcut {
    /// HID keycodes for the physical modifier keys. A shortcut whose keyCode is
    /// one of these is a "modifier-only chord" (e.g. hold right-Option) detected
    /// via flagsChanged; anything else is a key(+modifiers) combo via keyDown.
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    var isModifierOnly: Bool { Self.modifierKeyCodes.contains(keyCode) }
}

/// Per-action shortcut persistence. Absent key ⇒ the action uses its shipping
/// default, so a fresh install and a "reset to defaults" both mean "store
/// nothing". Cheap enough to read on demand; `InputController` snapshots the
/// whole map into a cache and refreshes on UserDefaults change.
final class ShortcutSettings {
    static let shared = ShortcutSettings()

    private static let keyPrefix = "com.inputsa.shortcut2."
    private static let legacyVoiceKey = "com.inputsa.shortcut.voice"

    private init() { migrateLegacyVoiceShortcutIfNeeded() }

    private func storageKey(_ action: ShortcutAction) -> String {
        Self.keyPrefix + action.rawValue
    }

    /// The effective binding for an action: the stored override, or the default.
    func shortcut(for action: ShortcutAction) -> ShortcutRecorderView.Shortcut {
        guard let data = UserDefaults.standard.data(forKey: storageKey(action)),
              let sc = try? JSONDecoder().decode(ShortcutRecorderView.Shortcut.self, from: data)
        else { return action.defaultShortcut }
        return sc
    }

    /// Whether the action currently differs from its shipping default.
    func isCustomized(_ action: ShortcutAction) -> Bool {
        UserDefaults.standard.data(forKey: storageKey(action)) != nil
    }

    /// Store an override, or pass nil to reset this action to its default.
    func set(_ shortcut: ShortcutRecorderView.Shortcut?, for action: ShortcutAction) {
        let key = storageKey(action)
        guard let shortcut,
              let data = try? JSONEncoder().encode(shortcut) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Restore every action to its shipping default.
    func resetAll() {
        for action in ShortcutAction.allCases {
            UserDefaults.standard.removeObject(forKey: storageKey(action))
        }
    }

    /// The full effective binding map — snapshot source for the event tap cache.
    func snapshot() -> [ShortcutAction: ShortcutRecorderView.Shortcut] {
        var map: [ShortcutAction: ShortcutRecorderView.Shortcut] = [:]
        for action in ShortcutAction.allCases { map[action] = shortcut(for: action) }
        return map
    }

    /// Another action already bound to the same keys, if any (used to warn the
    /// user in Preferences before they collide two actions).
    func conflictingAction(for shortcut: ShortcutRecorderView.Shortcut,
                           excluding action: ShortcutAction) -> ShortcutAction? {
        for other in ShortcutAction.allCases where other != action {
            if self.shortcut(for: other) == shortcut { return other }
        }
        return nil
    }

    /// Carry a pre-existing custom dictation shortcut (the old single-shortcut
    /// system stored under `com.inputsa.shortcut.voice`) into the new per-action
    /// store, once. Legacy nil meant "use right-Option default", which the new
    /// default already is, so only a non-nil legacy value needs migrating.
    private func migrateLegacyVoiceShortcutIfNeeded() {
        let dictationKey = storageKey(.dictation)
        guard UserDefaults.standard.object(forKey: dictationKey) == nil,
              let data = UserDefaults.standard.data(forKey: Self.legacyVoiceKey),
              let sc = try? JSONDecoder().decode(ShortcutRecorderView.Shortcut.self, from: data)
        else { return }
        UserDefaults.standard.set(data, forKey: dictationKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyVoiceKey)
        NSLog("[InputSa] migrated legacy voice shortcut → dictation (\(sc.displayString))")
    }
}
