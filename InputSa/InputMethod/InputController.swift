import AppKit
import Carbon
import ApplicationServices
import AVFoundation

/// CGEventTap-based controller for voice transcription and text polishing.
/// No IMKit / TIS / Bopomofo — AI-powered features only.
final class InputController: NSObject {

    // MARK: - Sub-systems
    // voiceHUD / voiceService are `internal` (not private) so the select-and-act
    // flows in SelectionActions.swift (a cross-file extension) can drive them.
    let voiceHUD      = VoiceHUDController()
    private let polishPreview = PolishPreviewController()
    var voiceService: VoiceServiceProtocol = GroqVoiceService()

    // MARK: - Event Tap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - State
    /// A modifier-only chord (e.g. hold right-Option) currently recording via the
    /// flagsChanged path; nil when no modifier-hold action is active. At most one
    /// modifier-hold action runs at a time.
    private var activeModifierHoldAction: ShortcutAction?
    /// Wall-clock start of the modifier-hold press, to debounce macOS' occasional
    /// double flagsChanged on a single physical key event.
    private var modifierHoldStartTime: Date?
    /// A key-combo (e.g. ⌃⌥Q) hold currently recording via the keyDown/keyUp
    /// path, plus the physical key it owns entirely until release.
    private var activeKeyHoldAction: ShortcutAction?
    private var activeKeyHoldKeyCode: Int?
    /// Effective binding for every action, snapshotted from ShortcutSettings and
    /// refreshed on any UserDefaults change (i.e. right after the user edits one).
    private var cachedShortcuts: [ShortcutAction: ShortcutRecorderView.Shortcut] = [:]
    /// Voice-parsed dojo entry awaiting the user's Enter (save) / Esc (discard).
    private var pendingDojoEntry: DojoCorrectionTable.Entry?
    /// Wall-clock start of the current recording, captured in handleVoiceKeyDown.
    /// The type-specific *RecordingStartTime properties are nil'd before the async
    /// completion fires, so usage-stats duration is measured from this one instead.
    /// Internal so SelectionActions' 劃詞問答 recording path can set it too.
    var recordingStartTime: Date?
    /// Rolling in-memory buffer of the most recent dictation results, fed to the
    /// Gemini polish prompt as prior context so homophones resolve from what the
    /// user just said (「道親」not「到親」). Privacy: memory-only, never persisted
    /// (mirrors UsageStatsStore's "numbers only" stance); capped to the last 2
    /// entries with a 3-minute TTL. Only the right-⌥ dictation path writes here;
    /// translation / ⌥P / 劃詞問答 deliberately do not.
    private var recentUtterances: [(text: String, at: Date)] = []
    /// 劃詞問答 (⌃⌥Q): true while holding Q to record a spoken question, and the
    /// selection captured the instant Q went down (before the mic opens).
    var qaKeyRecording = false
    var qaSelectedText: String?
    /// Cursor rect captured when a select-and-act shortcut fires, so the answer
    /// panel can be placed near where the user was working.
    var selectionActionCursor: NSRect?
    /// Bumps per HUD "flash" toast so a later real recording isn't hidden by a
    /// stale auto-hide timer.
    var hudFlashToken = 0
    /// Loudest normalized level (0...1) seen during the current recording.
    /// Near-zero after a full utterance means the mic never actually captured
    /// audio (wrong input device, muted input, dead TCC grant) — used to turn a
    /// generic transcription error into a pointed "check your input device" one.
    /// Internal so SelectionActions' recording path can reset/track it too.
    var peakRecordedLevel: Float = 0
    /// AX element that was focused when recording began — used for injection after API calls complete.
    private var recordingTargetElement: AXUIElement?
    private lazy var polishHUD: NSPanel = makePolishHUD()
    private var polishHUDLabel: NSTextField?

    // Key codes (Carbon kVK_* values)
    private let kVKReturn: Int = 36
    private let kVKTab:    Int = 48
    private let kVKEscape: Int = 53

    // MARK: - Start / Stop
    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)    |
            (1 << CGEventType.keyUp.rawValue)      |
            (1 << CGEventType.flagsChanged.rawValue)  // Option PTT

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: InputController.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[InputSa] CGEventTap creation failed — check Accessibility permission")
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Cache shortcuts and voice service once; refresh whenever UserDefaults changes
        // (e.g. after saving prefs or switching provider in the preferences window).
        refreshShortcutCache()
        refreshVoiceService()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshShortcutCache()
            self?.refreshVoiceService()
        }

        // Wire up polish preview callbacks once — not on every show()
        // onAccept only ever serves the manual-polish (⌥P) preview — the voice
        // dictation pipeline injects directly without a preview — so recording
        // usage stats here counts each accepted manual polish exactly once.
        polishPreview.onAccept = { [weak self] accepted in
            self?.injectText(accepted)
            UserStyleModel.shared.recordVoiceAccepted()
            UsageStatsStore.shared.record(chars: accepted.count, durationMs: 0)
            self?.polishHUD.orderOut(nil)
        }
        polishPreview.onReject = { [weak self] in
            UserStyleModel.shared.recordVoiceRejected()
            self?.recordingTargetElement = nil
            self?.polishHUD.orderOut(nil)
        }

        NSLog("[InputSa] CGEventTap active (voice + polish mode)")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        NotificationCenter.default.removeObserver(self)
    }

    private func refreshShortcutCache() {
        // Snapshot every action's effective binding so the event tap never touches
        // UserDefaults/JSONDecoder on the hot keypress path. Refreshed on any
        // UserDefaults change, so edits in Preferences take effect immediately.
        cachedShortcuts = ShortcutSettings.shared.snapshot()
    }

    private func refreshVoiceService() {
        // Skip recreation if already recording — provider switch mid-session is harmless
        // (the old service holds its own state until the completion fires).
        guard !voiceService.isRecording else { return }
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   voiceService = GroqVoiceService()
        case .google: voiceService = GoogleVoiceService()
        case .sherpa: voiceService = SherpaVoiceService()
        }
    }

    // MARK: - Static Callback Bridge
    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passRetained(event) }
        let ctrl = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
        return ctrl.handle(proxy: proxy, type: type, event: event)
    }

    // MARK: - Core Event Handler
    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        // ── Bypass when ShortcutRecorderView is actively capturing a new shortcut,
        //    OR when the Preferences window is the key window.
        //    Both conditions ensure the local NSEvent monitor in ShortcutRecorderView fires.
        if ShortcutRecorderView.isCapturing { return Unmanaged.passRetained(event) }
        if let keyWin = NSApp.keyWindow, keyWin === PreferencesWindowController.shared.window {
            return Unmanaged.passRetained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags

        // ── Modifier-only chord engine (flagsChanged): drives every action bound
        //    to a bare modifier hold. Defaults: right-⌥ dictation, right-⌘
        //    translate, right-⇧ 口頭修正 — but any of the seven can be rebound to
        //    a bare modifier, so this is entirely data-driven from cachedShortcuts.
        //    Left-side modifiers keep native macOS behaviour unless a user picks one.
        if type == .flagsChanged {
            handleModifierChordChange(keyCode: keyCode, flags: flags)
            return Unmanaged.passRetained(event)
        }

        // ── Answer panel (劃詞問答 / 劃詞翻譯) is a non-activating panel that
        //    never becomes key, so ⎋ is caught here (same pattern as the polish
        //    preview). Only closes when the panel is actually on screen.
        if type == .keyDown && keyCode == kVKEscape && AnswerPanelController.shared.isVisible {
            AnswerPanelController.shared.close()
            return nil
        }

        // ── Manual polish preview (⌥P) is also a non-activating panel, so its
        //    keys are caught here: ↩/⇥ accept, ⎋ reject. Any other keyDown
        //    dismisses without injecting and passes through (same no-stuck-modal
        //    contract as the pending 口頭修正 entry below).
        if type == .keyDown && polishPreview.isActive {
            if handlePolishPreviewKey(keyCode: keyCode) { return nil }
            polishPreview.reject()
            return Unmanaged.passRetained(event)
        }

        // ── Key-combo hold ownership: while a key-hold action records, own its
        //    key entirely — swallow autorepeat keyDowns and catch the keyUp that
        //    ends recording — so e.g. a held 'Q' (劃詞問答 ⌃⌥Q) never leaks a
        //    character into the document. Applies to whatever key it's bound to.
        if let action = activeKeyHoldAction, keyCode == activeKeyHoldKeyCode {
            if type == .keyUp {
                clearActiveKeyHoldState()
                stopHoldAction(action)
            }
            return nil
        }

        // ── Pending 口頭修正 entry: Enter saves, Esc discards, anything else
        //    dismisses and passes through (no stuck modal state).
        if type == .keyDown, let entry = pendingDojoEntry {
            pendingDojoEntry = nil
            if keyCode == kVKReturn {
                // Shift+Return = save locally AND share to the 共編詞庫; plain
                // Return = save locally only (default, protects personal terms).
                confirmPendingDojoEntry(entry, share: flags.contains(.maskShift))
                return nil
            }
            if keyCode == kVKEscape {
                voiceHUD.hide()
                return nil
            }
            voiceHUD.hide()
            return Unmanaged.passRetained(event)
        }

        // ── Cancel an in-progress modifier-hold PTT when the held modifier turns
        //    out to be part of a combo (right-⌘+C, right-⇧+letter): discard the
        //    recording and let the combo through.
        if type == .keyDown, let active = activeModifierHoldAction {
            clearActiveHoldState()
            cancelActiveRecording(for: active)
            return Unmanaged.passRetained(event)
        }

        // ── Data-driven key-combo dispatch (keyDown): match the pressed key +
        //    modifiers against every action bound to a key combo (not a bare
        //    modifier). Exact modifier match, so ⌃⌥⇧Q never fires ⌃⌥Q; press
        //    actions ignore autorepeat, hold actions start once then own the key.
        if type == .keyDown {
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let action = matchingKeyComboAction(keyCode: keyCode, flags: flags, autorepeat: autorepeat) {
                dispatchKeyCombo(action, keyCode: keyCode)
                return nil
            }
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Data-driven shortcut dispatch

    /// The four device-independent modifier bits currently held, as an
    /// NSEvent.ModifierFlags rawValue (the form shortcuts are stored in).
    private func nsModifierMask(from flags: CGEventFlags) -> UInt {
        var m: NSEvent.ModifierFlags = []
        if flags.contains(.maskShift)     { m.insert(.shift) }
        if flags.contains(.maskControl)   { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand)   { m.insert(.command) }
        return m.rawValue
    }

    /// Whether the bare modifier a modifier-only shortcut is bound to is still down.
    private func modifierStillHeld(_ sc: ShortcutRecorderView.Shortcut, in flags: CGEventFlags) -> Bool {
        (nsModifierMask(from: flags) & sc.modifierFlags) != 0
    }

    /// First action (registry order) whose modifier-only binding exactly matches
    /// this bare-modifier press. Exact keyCode + mask, so a two-modifier press
    /// never triggers a single-modifier chord.
    private func matchingModifierOnlyAction(keyCode: Int, mask: UInt) -> ShortcutAction? {
        for action in ShortcutAction.allCases {
            guard let sc = cachedShortcuts[action], sc.isModifierOnly else { continue }
            if Int(sc.keyCode) == keyCode && sc.modifierFlags == mask { return action }
        }
        return nil
    }

    /// First action whose key-combo binding matches this keyDown. Press actions
    /// ignore autorepeat; hold actions match on the first press (later autorepeat
    /// is caught by the key-ownership branch once recording starts).
    private func matchingKeyComboAction(keyCode: Int, flags: CGEventFlags,
                                        autorepeat: Bool) -> ShortcutAction? {
        let mask = nsModifierMask(from: flags)
        for action in ShortcutAction.allCases {
            guard let sc = cachedShortcuts[action], !sc.isModifierOnly else { continue }
            guard Int(sc.keyCode) == keyCode && sc.modifierFlags == mask else { continue }
            if !action.isHold && autorepeat { continue }
            return action
        }
        return nil
    }

    /// flagsChanged engine for modifier-only chord shortcuts. At most one
    /// modifier-hold action is active; it starts when its bare modifier goes down
    /// and ends (or fires, for a press action) on release, with a 300 ms debounce
    /// that absorbs macOS' occasional double flagsChanged on a single press.
    private func handleModifierChordChange(keyCode: Int, flags: CGEventFlags) {
        if let active = activeModifierHoldAction, let sc = cachedShortcuts[active] {
            if !modifierStillHeld(sc, in: flags) {
                let held = modifierHoldStartTime.map { Date().timeIntervalSince($0) } ?? 1.0
                if active.isHold && held < 0.3 {
                    NSLog("[InputSa] modifier released too quickly (%.2fs) — debounced", held)
                    return   // spurious double event; keep waiting for the real release
                }
                clearActiveHoldState()
                if active.isHold { stopHoldAction(active) } else { firePressAction(active) }
            }
            return
        }

        guard !isAnyRecordingActive else { return }
        let mask = nsModifierMask(from: flags)
        guard let action = matchingModifierOnlyAction(keyCode: keyCode, mask: mask) else { return }
        activeModifierHoldAction = action
        modifierHoldStartTime = Date()
        if action.isHold, !startHoldAction(action, keyCode: keyCode) {
            clearActiveHoldState()   // mic guard failed etc. — don't wait for a release
        }
        // Press actions bound to a bare modifier fire on release (handled above).
    }

    /// keyDown for a matched key-combo action: hold → start + own the key; press → fire.
    private func dispatchKeyCombo(_ action: ShortcutAction, keyCode: Int) {
        if action.isHold {
            guard !isAnyRecordingActive else { return }   // already recording — swallow, don't stack
            activeKeyHoldAction = action
            activeKeyHoldKeyCode = keyCode
            if !startHoldAction(action, keyCode: keyCode) { clearActiveKeyHoldState() }
        } else {
            // Press actions other than opening Preferences are skipped mid-recording.
            guard !isAnyRecordingActive || action == .preferences else { return }
            firePressAction(action)
        }
    }

    @discardableResult
    private func startHoldAction(_ action: ShortcutAction, keyCode: Int) -> Bool {
        switch action {
        case .dictation, .translate, .correction: return handleVoiceKeyDown()
        case .selectionQA:                        return startSelectionQA()
        case .manualPolish, .selectionTranslate, .preferences: return false
        }
    }

    private func stopHoldAction(_ action: ShortcutAction) {
        switch action {
        case .dictation:   handleVoiceKeyUp()
        case .translate:   handleVoiceKeyUp(translate: true)
        case .correction:  handleVoiceKeyUp(correction: true)
        case .selectionQA: finishSelectionQA()
        case .manualPolish, .selectionTranslate, .preferences: break
        }
    }

    private func firePressAction(_ action: ShortcutAction) {
        switch action {
        case .manualPolish:       triggerManualPolish()
        case .selectionTranslate: triggerSelectionTranslate()
        case .preferences:
            DispatchQueue.main.async {
                PreferencesWindowController.shared.showPreferences()
                NSApp.activate(ignoringOtherApps: true)
            }
        case .dictation, .translate, .correction, .selectionQA: break
        }
    }

    /// Tear down an in-progress hold recording (mid-combo cancel). No-op for a
    /// press action that was merely pending a modifier release.
    private func cancelActiveRecording(for action: ShortcutAction) {
        guard action.isHold else { return }
        SystemAudioMute.shared.endMute()   // restore speaker on the combo-cancel path
        if action == .selectionQA {
            qaKeyRecording = false
            qaSelectedText = nil
        }
        voiceService.cancelRecording()
        voiceHUD.hide()
    }

    private func clearActiveHoldState() {
        activeModifierHoldAction = nil
        modifierHoldStartTime = nil
    }

    private func clearActiveKeyHoldState() {
        activeKeyHoldAction = nil
        activeKeyHoldKeyCode = nil
    }

    // MARK: - AXUIElement Helper
    /// Returns the currently focused UI element, or nil if unavailable.
    private func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var el: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &el) == .success
        else { return nil }
        return (el as! AXUIElement)
    }

    // MARK: - Voice Push-to-Talk

    // MARK: - Mic readiness guard

    /// Key-down gate shared by every recording entry point. Recording used to
    /// fail silently when the mic grant was missing — the HUD showed a recording
    /// state while no audio was ever captured (the classic "installed on another
    /// Mac, waveform never moves" report). Explain immediately instead, and
    /// offer the TCC repair flow.
    func micReadyOrExplain() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                inputSaLog("mic permission prompt from key-down → \(granted ? "granted" : "denied")")
            }
            flashHUDMessage("請先允許麥克風權限")
            return false
        default:
            inputSaLog("mic not authorized at key-down — showing recovery dialog")
            DispatchQueue.main.async { SelfDiagnostics.presentMicPermissionRecovery() }
            return false
        }
    }

    /// Start a dictation/translate/correction recording. Returns false if the mic
    /// guard blocks it, so the dispatch layer can clear the active-action state
    /// (which it set before calling in) instead of leaving a phantom recording.
    @discardableResult
    private func handleVoiceKeyDown() -> Bool {
        guard micReadyOrExplain() else { return false }
        peakRecordedLevel = 0
        recordingStartTime = Date()   // unified start for usage-stats duration
        recordingTargetElement = focusedElement()  // snapshot before HUD steals focus
        if APIKeyStore.shared.polishProvider == .apple {
            ApplePolishService.shared.prewarm()  // wake the local model while the user speaks
        }
        // Mute the speaker while recording so its output can't echo back into the
        // mic (opt-in; endMute on every stop/cancel path is a safe no-op if off).
        if UserDefaults.standard.bool(forKey: "com.inputsa.muteWhileRecording") {
            SystemAudioMute.shared.beginMute()
        }
        voiceService.onLevelUpdate = { [weak self] level in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.peakRecordedLevel = max(self.peakRecordedLevel, level)
                self.voiceHUD.updateAudioLevel(level)
            }
        }
        voiceService.startRecording()
        voiceHUD.show(state: .recording, near: getCursorRect(), on: NSScreen.main)
        return true
    }

    private func handleVoiceKeyUp(translate: Bool = false, correction: Bool = false) {
        SystemAudioMute.shared.endMute()   // restore speaker as soon as recording stops

        // Capture recording duration now — the completion below is async and the
        // start-time property is about to be needed for the next recording.
        let durationMs = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        recordingStartTime = nil
        voiceHUD.setState(.processing("轉錄中…"))
        voiceService.stopAndTranscribe { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let err):
                    self.voiceHUD.hide()
                    var message = "轉錄失敗：\(err.localizedDescription)"
                    if self.peakRecordedLevel < 0.02 {
                        message += "\n\n這次錄音從頭到尾幾乎無聲——麥克風可能沒有真正收到音。請從選單列圖示執行「系統診斷…」，或檢查「系統設定 › 聲音 › 輸入」的裝置與音量。"
                    }
                    self.showError(message)
                case .success(let transcript):
                    // Spoken tail commands (「……請幫我翻譯成英文」) were removed
                    // 2026-07-06: dictated content that legitimately ends with such a
                    // phrase is indistinguishable from a command, so translation is
                    // shortcut-only now (right-⌘, target language set in Preferences).
                    if correction {
                        self.runDojoVoiceAdd(transcript)   // 口頭修正 is not usage-tracked
                    } else if translate {
                        self.runTranslate(transcript, durationMs: durationMs)
                    } else {
                        self.runAIPolish(transcript, durationMs: durationMs)
                    }
                }
            }
        }
    }

    // MARK: - 口頭修正 (voice-added dojo vocabulary, right-Shift PTT)

    /// Parse the spoken clarification into a dojo entry and park it for the
    /// user's Enter/Esc. Nothing is written to the vocabulary until confirmed.
    private func runDojoVoiceAdd(_ transcript: String) {
        guard !APIKeyStore.shared.geminiKey.isEmpty else {
            voiceHUD.hide()
            showError("口頭修正需要 Gemini API Key，請在偏好設定（Ctrl+Option+P）填入。")
            return
        }
        voiceHUD.setState(.processing("解析詞條中…"))
        DojoVoiceParser.parse(transcript: transcript) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.voiceHUD.hide()
                self.debugLog("dojo voice-add FAILED: \(err.localizedDescription) (transcript: \(transcript))")
                self.showError("口頭修正解析失敗：\(err.localizedDescription)")
            case .success(let entry):
                self.pendingDojoEntry = entry
                self.debugLog("dojo voice-add parsed: \(entry.wrong) → \(entry.correct)")
                self.voiceHUD.showDojoConfirm(correct: entry.correct, wrong: entry.wrong)
            }
        }
    }

    /// Save the parsed entry to the personal table. When `share` is true, also
    /// submit it to the 共編詞庫 for review — best-effort: a failed share never
    /// affects the local save and never shows a modal.
    private func confirmPendingDojoEntry(_ entry: DojoCorrectionTable.Entry, share: Bool = false) {
        var entries = DojoCorrectionTable.shared.personalEntries
        let duplicate = entries.contains { $0.wrong == entry.wrong && $0.correct == entry.correct }
        if !duplicate { entries.append(entry) }
        guard duplicate || DojoCorrectionTable.shared.save(entries) else {
            voiceHUD.hide()
            showError("詞庫寫入失敗，請確認磁碟空間或權限。")
            return
        }
        debugLog("dojo voice-add saved: \(entry.wrong) → \(entry.correct)\(duplicate ? " (duplicate, skipped)" : "")")

        guard share else {
            voiceHUD.updateDojoConfirmMessage("✅ 已加入詞庫：\(entry.correct)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.voiceHUD.hide()
            }
            return
        }

        // Local save is already committed above — sharing is purely additive.
        voiceHUD.updateDojoConfirmMessage("✅ 已加入詞庫，分享中…")
        DojoSharedSync.shared.submit(entry: entry) { [weak self] result in
            guard let self = self else { return }
            let msg: String
            switch result {
            case .success(.ok):        msg = "已送出待審核 ✓"
            case .success(.duplicate): msg = "這條已有人分享過"
            case .failure(let err):
                self.debugLog("dojo share submit failed: \(err.localizedDescription)")
                msg = "分享失敗，詞條已存在本機"
            }
            self.voiceHUD.updateDojoConfirmMessage(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.voiceHUD.hide()
            }
        }
    }

    /// Translate PTT pipeline: transcript → Gemini translation → inject.
    /// Unlike polish, a failed translation must NOT inject the original Chinese.
    /// `lang` overrides the preference (spoken command names its own language).
    private func runTranslate(_ transcript: String, lang overrideLang: String? = nil,
                              durationMs: Int = 0) {
        guard !APIKeyStore.shared.geminiKey.isEmpty else {
            voiceHUD.hide()
            showError("語音翻譯需要 Gemini API Key，請在偏好設定（Ctrl+Option+P）填入。")
            return
        }
        let lang = overrideLang ?? TranscriptionMode.translateTargetLanguage
        voiceHUD.setState(.processing("翻譯成\(lang)…"))
        GeminiPolishService.shared.enhance(
            text: transcript,
            mode: .translate(to: lang),
            onPartial: { [weak self] partial in
                self?.voiceHUD.setState(.processing(Self.streamingPreview(partial, label: "翻譯中")))
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.voiceHUD.hide()
                switch result {
                case .success(let translated):
                    self.debugLog("translate OK (\(transcript.count) → \(translated.count) chars)")
                    // Number formatting is a no-op for most non-CJK output but harmless
                    // and keeps all injected dictation/translation text on one path.
                    let out = TranscriptNumberFormatter.format(translated)
                    self.finishAndInject(out)
                    UsageStatsStore.shared.record(chars: out.count, durationMs: durationMs)
                case .failure(let err):
                    self.debugLog("translate FAILED: \(err.localizedDescription)")
                    self.showError("翻譯失敗：\(err.localizedDescription)")
                }
            }
        }
    }

    private func debugLog(_ msg: String) { inputSaLog(msg) }

    /// One switch, two call sites (dictation polish + Option+P): route to the
    /// user's chosen polish provider. Both services share the same
    /// `Result<String,Error>` main-thread completion, so the caller's post-pass
    /// and logging are provider-agnostic.
    private func dispatchPolish(
        text: String,
        mode: TranscriptionMode,
        priorContext: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        switch APIKeyStore.shared.polishProvider {
        case .apple:
            // Apple's on-device 3B is deliberately NOT given prior context: extra
            // prompt length feeds its 詞彙表膨脹幻覺 (short input → invented output).
            // v1 keeps prior context Gemini-only; `priorContext` is dropped here.
            ApplePolishService.shared.enhance(text: text, mode: mode,
                                              onPartial: onPartial, completion: completion)
        case .gemini:
            GeminiPolishService.shared.enhance(text: text, mode: mode, priorContext: priorContext,
                                               onPartial: onPartial, completion: completion)
        }
    }

    // MARK: - Prior-context buffer (Gemini dictation polish only)

    /// Record a completed dictation result for use as prior context on the next
    /// utterance. Trims expired/overflow entries as a side effect. Memory-only.
    private func recordUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentUtterances.append((text: trimmed, at: Date()))
        recentUtterances = prunedUtterances()
    }

    /// Drop entries older than the 3-minute TTL and keep only the last 2.
    private func prunedUtterances() -> [(text: String, at: Date)] {
        let cutoff = Date().addingTimeInterval(-180)
        let fresh = recentUtterances.filter { $0.at >= cutoff }
        return fresh.suffix(2).map { $0 }
    }

    /// Prior context for the polish prompt: each entry capped at 120 chars,
    /// expired ones dropped, joined oldest→newest. `nil` when nothing valid.
    private func priorContextForPolish() -> String? {
        let joined = prunedUtterances()
            .map { String($0.text.prefix(120)) }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// AI polish step in the unified pipeline (Gemini cloud or Apple local).
    /// After polishing (or if the provider can't run), injects text directly into
    /// the target element. No preview step required — text appears immediately;
    /// user can Cmd+Z to undo.
    private func runAIPolish(_ transcript: String, durationMs: Int = 0) {
        let provider = APIKeyStore.shared.polishProvider
        // Gemini needs a key; Apple is local and needs none.
        if provider == .gemini, APIKeyStore.shared.geminiKey.isEmpty {
            debugLog("polish SKIPPED (no Gemini key) — injecting raw transcript (\(transcript.count) chars)")
            voiceHUD.hide()
            let formatted = TranscriptNumberFormatter.format(transcript)
            finishAndInject(formatted)
            UsageStatsStore.shared.record(chars: formatted.count, durationMs: durationMs)
            recordUtterance(formatted)   // prior-context buffer: raw transcript on fallback
            return
        }
        let providerTag = provider == .apple ? "Apple" : "Gemini"
        let baseLabel = provider == .apple ? "AI 潤飾中（本地）" : "AI 潤飾中"
        let modeName = TranscriptionMode.activePolishModeName
        voiceHUD.setState(.processing(modeName.map { "\(baseLabel)（\($0)）…" } ?? "\(baseLabel)…"))
        debugLog("polish in (\(providerTag)): \(String(transcript.prefix(120)))")
        dispatchPolish(
            text: transcript,
            mode: TranscriptionMode.activePolishMode,
            // Prior context is Gemini-only (Apple 3B hallucination risk); compute
            // before this utterance is recorded so it never sees itself.
            priorContext: provider == .apple ? nil : priorContextForPolish(),
            onPartial: { [weak self] partial in
                self?.voiceHUD.setState(.processing(Self.streamingPreview(partial, label: "潤飾中")))
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.voiceHUD.hide()
                switch result {
                case .success(let polished):
                    // Post-polish safety net: re-run the dojo correction table so terms
                    // the LLM missed or "normalized away" (發願→發愿 etc.) are restored,
                    // then the deterministic number formatter (百分之三十五→35% etc.) as a
                    // belt-and-suspenders backstop to the prompt's number rules.
                    let dojoMode = UserDefaults.standard.bool(forKey: "com.inputsa.dojoMode")
                    let corrected = DojoCorrectionTable.shared.correct(polished, dojoMode: dojoMode)
                    let final = TranscriptNumberFormatter.format(corrected)
                    let newlines = final.filter { $0 == "\n" }.count
                    self.debugLog("polish OK (\(transcript.count) → \(final.count) chars, \(newlines) newlines)")
                    self.debugLog("polish out: \(String(final.prefix(120)))")
                    self.finishAndInject(final)
                    UsageStatsStore.shared.record(chars: final.count, durationMs: durationMs)
                    self.recordUtterance(final)   // prior-context buffer: polished text
                case .failure(let err):
                    // Fall back to the raw transcript, but tell the user polish didn't run —
                    // silent fallback made key/network failures look like a formatting bug.
                    // The deterministic number pass still applies (it's the whole reason it
                    // exists as a rules layer: it must protect the raw-transcript fallback too).
                    self.debugLog("polish FAILED: \(err.localizedDescription) — injecting raw transcript")
                    let fallback = TranscriptNumberFormatter.format(transcript)
                    self.finishAndInject(fallback)
                    UsageStatsStore.shared.record(chars: fallback.count, durationMs: durationMs)
                    self.recordUtterance(fallback)   // prior-context buffer: raw transcript on fallback
                    self.notifyPolishFailure(err.localizedDescription)
                }
            }
        }
    }

    /// HUD line for streaming partials — the label plus the tail of what has
    /// arrived so far, kept short enough for the single-line status label.
    private static func streamingPreview(_ partial: String, label: String) -> String {
        let flat = partial.replacingOccurrences(of: "\n", with: " ")
        let tail = String(flat.suffix(16))
        return "\(label)…\(tail)"
    }

    /// Non-blocking notice when polish/translation quietly degrades (e.g. bad API key).
    private func notifyPolishFailure(_ reason: String) {
        let note = NSUserNotification()
        note.title = "AI 潤飾未生效（已輸出原文）"
        note.informativeText = reason
        NSUserNotificationCenter.default.deliver(note)
    }

    /// Inject the final text and play a subtle confirmation sound.
    private func finishAndInject(_ text: String) {
        injectText(text)
        NSSound(named: "Pop")?.play()   // brief audio cue so user knows text was inserted
    }

    // MARK: - Shared select-and-act helpers

    /// True while any recording/PTT is in flight — select-and-act shortcuts must
    /// not interrupt an ongoing dictation/translation/correction/QA session.
    var isAnyRecordingActive: Bool {
        activeModifierHoldAction != nil || activeKeyHoldAction != nil || qaKeyRecording
    }

    /// Brief non-blocking HUD toast (e.g. "沒有選取文字"), auto-hidden after 1.2 s.
    /// Never shown while a recording is active (it would hijack the live HUD), and
    /// a token guard stops a stale auto-hide from closing a later real HUD.
    func flashHUDMessage(_ text: String) {
        guard !isAnyRecordingActive else { return }
        voiceHUD.show(state: .processing(text), near: getCursorRect(), on: NSScreen.main)
        hudFlashToken += 1
        let token = hudFlashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, token == self.hudFlashToken,
                  !self.isAnyRecordingActive else { return }
            self.voiceHUD.hide()
        }
    }

    // MARK: - Manual Text Polish (Option+P or custom shortcut)
    private func triggerManualPolish() {
        guard let text = SelectionReader.read() else {
            flashHUDMessage("沒有選取文字")
            return
        }

        dispatchPolish(text: text,
                       mode: TranscriptionMode.activePolishMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let enhanced):
                    // Match the dictation pipeline's post-pass so 道場詞彙 and
                    // number formatting survive in manual polish too, then preview.
                    let dojoMode = UserDefaults.standard.bool(forKey: "com.inputsa.dojoMode")
                    let corrected = DojoCorrectionTable.shared.correct(enhanced, dojoMode: dojoMode)
                    let final = TranscriptNumberFormatter.format(corrected)
                    self.polishPreview.startPreview(original: text, enhanced: final)
                    self.showPolishHUD(final)
                case .failure(let err):
                    self.showError("潤飾失敗：\(err.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Polish Preview HUD
    /// Build the floating panel once via lazy initializer.
    private func makePolishHUD() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = NSColor(red: 0.980, green: 0.980, blue: 0.973, alpha: 1.0)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 8
        panel.contentView?.layer?.borderWidth = 1
        panel.contentView?.layer?.borderColor = NSColor(white: 0.86, alpha: 1).cgColor

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12)
        label.frame = NSRect(x: 12, y: 34, width: 356, height: 38)
        panel.contentView?.addSubview(label)
        polishHUDLabel = label

        let hint = NSTextField(labelWithString: "↩ 接受  ⎋ 拒絕")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 12, y: 10, width: 200, height: 20)
        panel.contentView?.addSubview(hint)
        return panel
    }

    /// Show preview HUD after the voice pipeline completes.
    /// Uses the saved recordingTargetElement rect for accurate positioning.
    private func showPolishPreview(_ text: String) {
        polishPreview.startPreview(original: text, enhanced: text)
        polishHUDLabel?.stringValue = text
        let cursor = recordingTargetElement.flatMap { getCursorRectFor($0) } ?? getCursorRect()
        polishHUD.setFrameOrigin(floatingOrigin(size: polishHUD.frame.size, below: cursor, screen: NSScreen.main))
        polishHUD.orderFront(nil)
    }

    /// Show preview HUD for manual polish (no saved element).
    private func showPolishHUD(_ text: String) {
        polishHUDLabel?.stringValue = text
        polishHUD.setFrameOrigin(floatingOrigin(size: polishHUD.frame.size, below: getCursorRect(), screen: NSScreen.main))
        polishHUD.orderFront(nil)
    }

    private func handlePolishPreviewKey(keyCode: Int) -> Bool {
        if keyCode == kVKReturn || keyCode == kVKTab { polishPreview.accept(); return true }
        if keyCode == kVKEscape                      { polishPreview.reject(); return true }
        return false
    }

    // MARK: - Text Injection via AXUIElement

    /// Deep copy of the user's clipboard captured before an injection, restored
    /// ~300 ms after paste. Held across consecutive injections so a rapid second
    /// paste doesn't overwrite the snapshot with the *first* injected text.
    private var savedClipboardItems: [NSPasteboardItem]?
    /// Bumped per injection so only the latest scheduled restore runs.
    private var clipboardRestoreToken = 0

    private func injectText(_ text: String) {
        // Inject via clipboard + Cmd+V — the only reliably cross-app insertion method.
        // AXUIElementSetAttributeValue(kAXSelectedText:) returns .success on many apps
        // (Safari address bar, Electron, some native fields) WITHOUT actually inserting
        // the text, so it can never be trusted as a primary path and is not used here.
        recordingTargetElement = nil
        let pb = NSPasteboard.general

        // Snapshot the current clipboard (all items, all types) before overwriting.
        // Only when no restore is already pending, so back-to-back injections keep
        // the ORIGINAL contents rather than snapshotting the previous injected text.
        if savedClipboardItems == nil {
            savedClipboardItems = Self.snapshotPasteboard(pb)
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        pasteViaCmdV()
        NSLog("[InputSa] injectText: pasted via Cmd+V (\(text.count) chars)")

        // Restore the original clipboard after Cmd+V has had time to read it.
        clipboardRestoreToken += 1
        let token = clipboardRestoreToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, token == self.clipboardRestoreToken else { return }
            let items = self.savedClipboardItems
            self.savedClipboardItems = nil
            Self.restorePasteboard(items, to: NSPasteboard.general)
        }
    }

    /// Deep-copy every item on the pasteboard. NSPasteboardItem instances can't be
    /// reused across `clearContents()`, so each type's raw data is copied into a
    /// fresh item that survives the injection.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Write the snapshot back. An empty/nil snapshot means the clipboard was
    /// originally empty — clear it back to empty rather than leaving injected text.
    private static func restorePasteboard(_ items: [NSPasteboardItem]?, to pb: NSPasteboard) {
        pb.clearContents()
        if let items, !items.isEmpty {
            pb.writeObjects(items)
        }
    }

    /// Simulate Cmd+V to paste from clipboard. Text must already be in NSPasteboard before calling.
    /// Clipboard is intentionally left intact so the user can re-paste manually if needed.
    private func pasteViaCmdV() {
        let src   = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)!
        let vUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)!
        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)
        NSLog("[InputSa] injectText: Cmd+V dispatched")
    }

    /// Legacy entry point for callers that don't pre-load the clipboard.
    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pasteViaCmdV()
    }

    // MARK: - Cursor Position
    func getCursorRect() -> NSRect {
        guard let element = focusedElement() else { return fallbackCursorRect() }
        return getCursorRectFor(element) ?? fallbackCursorRect()
    }

    private func getCursorRectFor(_ element: AXUIElement) -> NSRect? {
        var rangeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success,
              let range = rangeVal else { return nil }

        var boundsVal: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsVal
        ) == .success, let boundsRef = boundsVal else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }

        let screenH = NSScreen.screens.first?.frame.height ?? 900
        return NSRect(x: rect.origin.x, y: screenH - rect.origin.y - rect.size.height,
                      width: rect.size.width, height: rect.size.height)
    }

    private func fallbackCursorRect() -> NSRect {
        let m = NSEvent.mouseLocation
        return NSRect(x: m.x, y: m.y - 20, width: 1, height: 20)
    }

    // MARK: - Error Presentation
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Input-sa 錯誤"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Shared diagnostic logger
/// Append a diagnostic line to ~/Library/Logs/InputSa.log (unified log has proven
/// unreliable for post-hoc inspection of this app — a plain file survives and is
/// greppable). Local file only; traces the transcription → correction → polish
/// pipeline so accuracy issues can be diagnosed from real usage.
func inputSaLog(_ msg: String) {
    NSLog("[InputSa] %@", msg)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/InputSa.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(data)
    } else {
        try? data.write(to: url)
    }
}
