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
    private let translationHUD = TranslationHUDController()
    private var translationSession: TranslationSession?
    private var translationSnapshot: VoiceTranscriptionSnapshot?
    private var translationAIText: String?
    private var translationAppName: String?
    private var translationStartedAt = Date()
    private var translationHistoryGeneration = UUID()
    private let dictationHUD = DictationHUDController()
    private var dictationSession: DictationSession?
    private var dictationMode: TranscriptionMode = .standard
    private var dictationStyle: DictationCleanupStyle = .light
    private var dictationPolishProvider: APIKeyStore.PolishProvider = .gemini
    private var dictationPolishRequest: CLITextRequest?
    private var manualPolishRequest: CLITextRequest?
    private var manualPolishToken: UUID?
    private var dictationIsVocabulary = false
    private var dictationHistoryGeneration = UUID()
    private var currentVoiceProvider: APIKeyStore.VoiceProvider = .groq
    private let historyQueue = DispatchQueue(label: "com.inputsa.history.save", qos: .utility)
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
    /// Bumps every time the modifier-hold state changes, so a pending
    /// "was that release real?" re-check (see verifyDebouncedRelease) can tell
    /// it belongs to a session that has since ended and quietly stand down.
    private var modifierDebounceToken = 0
    /// Effective binding for every action, snapshotted from ShortcutSettings and
    /// refreshed on any UserDefaults change (i.e. right after the user edits one).
    private var cachedShortcuts: [ShortcutAction: ShortcutRecorderView.Shortcut] = [:]
    /// Voice-parsed vocabulary entry awaiting the user's Enter (save) / Esc (discard).
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
    private var priorContextAppID: String?
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
        cancelManualPolish()
        if let token = translationSession?.id { cancelTranslation(token: token) }
        if let token = dictationSession?.id { cancelDictation(token: token) }
        voiceService.cancelRecording()
        SystemAudioMute.shared.endMute()
        voiceHUD.hide()
        dictationHUD.hide()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        NotificationCenter.default.removeObserver(self)
    }

    /// Keep the main run loop alive until history is durable and CLI children
    /// have exited. Both drains are asynchronous so UI callbacks can finish.
    func prepareToTerminate(completion: @escaping () -> Void) {
        stop()
        let pending = DispatchGroup()
        pending.enter()
        historyQueue.async { pending.leave() }
        pending.enter()
        CLIProcessRunner.shutdown { pending.leave() }
        pending.notify(queue: .main, execute: completion)
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
        guard !voiceService.isRecording, !isAnyRecordingActive else { return }
        refreshVoiceServiceForRecording()
    }

    private func refreshVoiceServiceForRecording() {
        guard currentVoiceProvider != APIKeyStore.shared.voiceProvider else { return }
        voiceService.onPartialText = nil
        voiceService.onLevelUpdate = nil
        currentVoiceProvider = APIKeyStore.shared.voiceProvider
        switch APIKeyStore.shared.voiceProvider {
        case .groq:   voiceService = GroqVoiceService()
        case .google: voiceService = GoogleVoiceService()
        case .sherpa: voiceService = SherpaVoiceService()
        case .whisper: voiceService = WhisperVoiceService()
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

        // A chip can stop the microphone while its physical shortcut is still
        // held. Keep owning that key through release, including when another
        // window has become key; never leak its autorepeat or keyUp.
        let ownedKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let action = activeKeyHoldAction,
           [.translate, .dictation, .correction].contains(action), ownedKeyCode == activeKeyHoldKeyCode,
           type == .keyDown || type == .keyUp {
            if type == .keyUp {
                clearActiveKeyHoldState()
                stopHoldAction(action)
            }
            return nil
        }
        if type == .flagsChanged {
            // Wait until the event has left this tap before synthesizing a paste.
            DispatchQueue.main.async { [weak self] in
                self?.attemptTranslationDelivery()
                self?.attemptDictationDelivery()
            }
            if let action = activeModifierHoldAction, [.translate, .dictation, .correction].contains(action) {
                handleModifierChordChange(keyCode: ownedKeyCode, flags: event.flags)
                return Unmanaged.passRetained(event)
            }
        }
        if type == .keyDown, ownedKeyCode == kVKEscape,
           let session = translationSession, session.isActive {
            cancelTranslation(token: session.id)
            return nil
        }
        if type == .keyDown, ownedKeyCode == kVKEscape,
           let session = dictationSession, session.isActive {
            cancelDictation(token: session.id)
            return nil
        }
        if type == .keyDown, ownedKeyCode == kVKEscape, manualPolishToken != nil {
            cancelManualPolish()
            return nil
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

        if type == .keyDown { recordKeystrokeForAttribution(keyCode: keyCode, flags: flags, event: event) }

        // ── Modifier-only chord engine (flagsChanged): drives every action bound
        //    to a bare modifier hold. Defaults: right-⌥ dictation, right-⌘
        //    translate, right-⇧ 口頭加詞 — but any of the seven can be rebound to
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
        //    contract as the pending 口頭加詞 entry below).
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

        // ── Pending 口頭加詞 entry: Enter saves, Esc discards, anything else
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

    // MARK: - Keystroke attribution probe

    /// Runaway-repeat tracking: the key currently repeating, how many repeats
    /// have arrived in a row, and whether this run has already been reported.
    private var repeatingKeyCode = -1
    private var repeatingKeyCount = 0
    private var repeatingKeyReported = false

    /// Answers "what just typed that?" for reports of characters appearing on
    /// their own. Two things are worth a log line, both rare enough in normal use
    /// that this costs nothing:
    ///
    ///   • A keystroke that some process *posted*. Real hardware carries source
    ///     PID 0; anything else names the process that synthesized it — which
    ///     settles whether this app (or any other) is typing into the document.
    ///   • A key repeating far past what a human hold produces, i.e. a key stuck
    ///     down somewhere between the hardware and here. Logged once per run, with
    ///     the source, so a runaway stream can be told apart from an injection.
    ///
    /// File I/O is pushed off the tap callback — stalling here risks macOS
    /// disabling the tap for timing out.
    private func recordKeystrokeForAttribution(keyCode: Int, flags: CGEventFlags, event: CGEvent) {
        let srcPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let origin = srcPID == 0
            ? "hardware"
            : (srcPID == Int64(ProcessInfo.processInfo.processIdentifier)
               ? "posted by this app" : "posted by pid \(srcPID)")

        if srcPID != 0 {
            DispatchQueue.main.async {
                inputSaLog("synthetic keyDown: keyCode=\(keyCode) flags=\(flags.rawValue) — \(origin)")
            }
        }

        guard event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
              keyCode == repeatingKeyCode else {
            repeatingKeyCode = keyCode
            repeatingKeyCount = 0
            repeatingKeyReported = false
            return
        }
        repeatingKeyCount += 1
        // ~100 repeats is several seconds of holding — past any real keypress.
        if repeatingKeyCount == 100 && !repeatingKeyReported {
            repeatingKeyReported = true
            DispatchQueue.main.async {
                inputSaLog("runaway key repeat: keyCode=\(keyCode) flags=\(flags.rawValue) — \(origin), 100+ repeats in one run")
            }
        }
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
                    verifyDebouncedRelease(for: active, shortcut: sc)
                    return   // maybe a spurious double event — the re-check decides
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
        modifierDebounceToken += 1   // invalidate any re-check left over from a prior press
        if action.isHold, !startHoldAction(action, keyCode: keyCode) {
            clearActiveHoldState()   // mic guard failed etc. — don't wait for a release
        }
        // Press actions bound to a bare modifier fire on release (handled above).
    }

    /// Decide, shortly after a sub-300 ms release, whether it was macOS' spurious
    /// double flagsChanged (keep recording) or a genuine quick tap (discard).
    ///
    /// The debounce exists because macOS occasionally emits a phantom release in
    /// the middle of a single press-and-hold. But at the instant it fires, a real
    /// tap looks identical — and swallowing a real tap's release used to leave the
    /// hold armed *forever*: the mic kept recording unnoticed, and the next
    /// modifier press (⇧ for a capital letter, ⌘⇥, anything) ended that session,
    /// transcribed whatever ambient noise had accumulated, and pasted the result
    /// at the cursor. That is the "app randomly types characters" symptom.
    ///
    /// The two cases separate a moment later: after a phantom release the key is
    /// still physically down, after a real tap it is up. So re-read the live
    /// modifier state and cancel the recording if the key really is up.
    private func verifyDebouncedRelease(for action: ShortcutAction,
                                        shortcut sc: ShortcutRecorderView.Shortcut) {
        modifierDebounceToken += 1
        let token = modifierDebounceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self,
                  token == self.modifierDebounceToken,
                  self.activeModifierHoldAction == action else { return }
            // Still held ⇒ the release was spurious; the real one is still coming.
            guard NSEvent.modifierFlags.rawValue & sc.modifierFlags == 0 else { return }
            inputSaLog("debounced release confirmed as a real tap — discarding \(action.rawValue) recording")
            self.clearActiveHoldState()
            self.cancelActiveRecording(for: action)
        }
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
        refreshVoiceServiceForRecording()
        if action != .translate { translationHUD.hide() }
        switch action {
        case .dictation:             return handleVoiceKeyDown()
        case .correction:            return handleVoiceKeyDown(correction: true)
        case .translate:             return startTranslationRecording()
        case .selectionQA:                        return startSelectionQA()
        case .manualPolish, .selectionTranslate, .preferences: return false
        }
    }

    private func stopHoldAction(_ action: ShortcutAction) {
        switch action {
        case .dictation:   handleVoiceKeyUp()
        case .translate:   translationShortcutReleased()
        case .correction:  handleVoiceKeyUp(correction: true)
        case .selectionQA: finishSelectionQA()
        case .manualPolish, .selectionTranslate, .preferences: break
        }
    }

    private func firePressAction(_ action: ShortcutAction) {
        switch action {
        // Both of these start by reading the user's selection, which costs an AX
        // round-trip and possibly a synthetic ⌘C with a pasteboard poll behind it.
        // We are inside the event-tap callback here, and the window server holds
        // every keystroke on the machine until it returns — so hand the work to
        // the next main-loop turn and get out. Same thread, microseconds later,
        // but the keyboard is no longer waiting on it.
        case .manualPolish:       DispatchQueue.main.async { [weak self] in self?.triggerManualPolish() }
        case .selectionTranslate: DispatchQueue.main.async { [weak self] in self?.triggerSelectionTranslate() }
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
        if action == .translate, let token = translationSession?.id {
            cancelTranslation(token: token)
            return
        }
        if action == .dictation || action == .correction, let token = dictationSession?.id {
            cancelDictation(token: token)
            return
        }
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
        modifierDebounceToken += 1   // any pending release re-check is now stale
    }

    private func clearActiveKeyHoldState() {
        activeKeyHoldAction = nil
        activeKeyHoldKeyCode = nil
    }

    // MARK: - AXUIElement Helper
    /// Returns the currently focused UI element, or nil if unavailable.
    private func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
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
    private func handleVoiceKeyDown(correction: Bool = false) -> Bool {
        guard micReadyOrExplain() else { return false }
        refreshVoiceServiceForRecording()
        let app = NSWorkspace.shared.frontmostApplication
        let session = DictationSession(appID: app?.bundleIdentifier, appName: app?.localizedName,
                                       processID: app?.processIdentifier)
        let token = session.id
        dictationSession = session
        dictationHistoryGeneration = TranscriptHistoryStore.shared.generation
        dictationIsVocabulary = correction
        dictationMode = TranscriptionMode.activePolishMode
        dictationPolishProvider = APIKeyStore.shared.polishProvider
        dictationStyle = TranscriptionMode.activePolishModeName == nil ? DictationCleanupStyle.selected : .structured
        dictationHUD.onCancel = { [weak self] in self?.cancelDictation(token: token) }
        peakRecordedLevel = 0
        recordingStartTime = Date()   // unified start for usage-stats duration
        recordingTargetElement = focusedElement()  // snapshot before HUD steals focus
        if dictationPolishProvider == .apple {
            ApplePolishService.shared.prewarm()  // wake the local model while the user speaks
        }
        // Mute the speaker while recording so its output can't echo back into the
        // mic (opt-in; endMute on every stop/cancel path is a safe no-op if off).
        if UserDefaults.standard.bool(forKey: "com.inputsa.muteWhileRecording") {
            SystemAudioMute.shared.beginMute()
        }
        voiceService.onLevelUpdate = { [weak self] level in
            DispatchQueue.main.async {
                guard let self = self, self.dictationSession?.id == token,
                      self.dictationSession?.phase == .recording else { return }
                self.peakRecordedLevel = max(self.peakRecordedLevel, level)
                if correction { self.voiceHUD.updateAudioLevel(level) }
                else { self.dictationHUD.setAudioLevel(level) }
            }
        }
        voiceService.onPartialText = { [weak self] partial in
            DispatchQueue.main.async {
                guard let self = self, !correction, self.dictationSession?.id == token,
                      self.dictationSession?.phase == .recording else { return }
                self.dictationHUD.setText(partial, provisional: true)
            }
        }
        voiceService.startRecording()
        if correction {
            voiceHUD.show(state: .recording, near: getCursorRect(), on: NSScreen.main)
        } else {
            voiceHUD.hide()
            dictationHUD.show(styleName: TranscriptionMode.activePolishModeName ?? dictationStyle.title,
                               hasLiveTranscript: currentVoiceProvider == .whisper, on: NSScreen.main)
        }
        return true
    }

    private func handleVoiceKeyUp(correction: Bool = false) {
        guard let token = dictationSession?.id, dictationSession?.phase == .recording else { return }
        SystemAudioMute.shared.endMute()   // restore speaker as soon as recording stops

        // Capture recording duration now — the completion below is async and the
        // start-time property is about to be needed for the next recording.
        let durationMs = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        guard dictationSession?.beginTranscription(token: token, durationMs: durationMs) == true else { return }
        recordingStartTime = nil
        let peak = peakRecordedLevel
        if correction { voiceHUD.setState(.processing("轉錄中…")) }
        else { dictationHUD.setStatus("辨識完整錄音中…") }
        let service = voiceService
        service.stopAndTranscribeDetailed { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.dictationSession?.id == token,
                      self.dictationSession?.phase == .transcribing else { return }
                switch result {
                case .failure(let err):
                    self.cancelDictation(token: token)
                    self.flashHUDMessage(peak < 0.02 ? "麥克風幾乎沒有收到聲音，請檢查輸入裝置" : "轉錄失敗：\(err.localizedDescription)")
                case .success(let snapshot):
                    let transcript = snapshot.normalizedText
                    // Phantom-injection guard. A recording that captured no real
                    // audio still comes back "successful" — STT models answer
                    // silence with a short hallucination (a stray letter, 「嗯」,
                    // 「謝謝觀看」) — and the pipeline would paste that at the
                    // cursor as if the user had asked for it. Nothing the user
                    // never said should reach their document, so drop it here,
                    // ahead of every downstream branch. peak < 0.02 is the same
                    // "mic captured nothing" threshold the failure path uses
                    // (≈ −49 dBFS; real speech peaks far above it).
                    let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if spoken.isEmpty || peak < 0.02 {
                        self.debugLog("discarded silent recording (peak \(self.peakRecordedLevel), \(spoken.count) chars) — nothing injected")
                        self.cancelDictation(token: token)
                        self.flashHUDMessage("沒有收到聲音")
                        return
                    }
                    // Spoken tail commands (「……請幫我翻譯成英文」) were removed
                    // 2026-07-06: dictated content that legitimately ends with such a
                    // phrase is indistinguishable from a command, so translation is
                    // shortcut-only now (right-⌘, target language set in Preferences).
                    if correction {
                        _ = self.dictationSession?.receive(snapshot, token: token)
                        self.runDojoVoiceAdd(transcript, token: token)
                    } else {
                        guard self.dictationSession?.receive(snapshot, token: token) == true else { return }
                        self.saveDictationHistory(status: .notSent)
                        self.dictationHUD.setText(transcript)
                        self.runAIPolish(transcript, token: token)
                    }
                }
            }
        }
    }

    // MARK: - 口頭加詞 (voice-added vocabulary, right-Shift PTT)

    /// Parse the spoken clarification into a vocabulary entry and park it for the
    /// user's Enter/Esc. Nothing is written to the vocabulary until confirmed.
    private func runDojoVoiceAdd(_ transcript: String, token: UUID) {
        guard !APIKeyStore.shared.geminiKey.isEmpty else {
            cancelDictation(token: token)
            showError("口頭加詞需要 Gemini API Key，請在偏好設定（Ctrl+Option+P）填入。")
            return
        }
        voiceHUD.setState(.processing("解析詞條中…"))
        DojoVoiceParser.parse(transcript: transcript) { [weak self] result in
            guard let self = self, self.dictationSession?.id == token,
                  self.dictationSession?.phase == .polishing else { return }
            self.dictationSession?.cancel(token: token)
            switch result {
            case .failure(let err):
                self.voiceHUD.hide()
                self.debugLog("vocabulary voice-add failed")
                self.showError("口頭加詞解析失敗：\(err.localizedDescription)")
            case .success(let entry):
                self.pendingDojoEntry = entry
                self.debugLog("vocabulary voice-add parsed: \(entry.wrong) → \(entry.correct)")
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
        debugLog("vocabulary voice-add saved: \(entry.wrong) → \(entry.correct)\(duplicate ? " (duplicate, skipped)" : "")")

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
                self.debugLog("vocabulary share submit failed: \(err.localizedDescription)")
                msg = "分享失敗，詞條已存在本機"
            }
            self.voiceHUD.updateDojoConfirmMessage(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.voiceHUD.hide()
            }
        }
    }

    // MARK: - Translation recording and delivery

    private func startTranslationRecording() -> Bool {
        guard micReadyOrExplain() else { return false }
        refreshVoiceServiceForRecording()
        // Capture before presenting a panel. Language and target never follow a
        // later foreground app change while this recording is being processed.
        let app = NSWorkspace.shared.frontmostApplication
        let language = TranslationPreferences.shared.language(
            for: app?.bundleIdentifier, fallback: TranscriptionMode.translateTargetLanguage)
        let session = TranslationSession(appID: app?.bundleIdentifier,
                                         processID: app?.processIdentifier, language: language)
        let token = session.id
        translationSession = session
        translationSnapshot = nil
        translationAIText = nil
        translationAppName = app?.localizedName
        translationStartedAt = Date()
        translationHistoryGeneration = TranscriptHistoryStore.shared.generation
        guard !APIKeyStore.shared.geminiKey.isEmpty else {
            translationFailed("語音翻譯需要 Gemini API Key，請在偏好設定填入。", token: token)
            return false
        }
        recordingStartTime = Date()
        recordingTargetElement = focusedElement()
        peakRecordedLevel = 0
        voiceHUD.hide()
        dictationHUD.hide()
        translationHUD.onLanguageSelected = { [weak self] language in
            guard let self = self,
                  self.translationSession?.selectLanguage(language, token: token) == true else { return }
            TranslationPreferences.shared.setLanguage(language, for: self.translationSession?.appID)
            self.finishTranslationRecording(token: token)
        }
        translationHUD.onFinish = { [weak self] in self?.finishTranslationRecording(token: token) }
        translationHUD.onCancel = { [weak self] in self?.cancelTranslation(token: token) }
        voiceService.onLevelUpdate = { [weak self] level in
            DispatchQueue.main.async {
                guard let self = self, self.translationSession?.id == token,
                      self.translationSession?.phase == .recording else { return }
                self.peakRecordedLevel = max(self.peakRecordedLevel, level)
                self.translationHUD.setAudioLevel(level)
            }
        }
        voiceService.onPartialText = { [weak self] partial in
            DispatchQueue.main.async {
                guard let self = self, self.translationSession?.id == token,
                      self.translationSession?.phase == .recording else { return }
                self.translationHUD.setText(partial)
                self.translationHUD.setStatus("暫時字幕 · 放開後辨識完整錄音")
            }
        }
        if UserDefaults.standard.bool(forKey: "com.inputsa.muteWhileRecording") {
            SystemAudioMute.shared.beginMute()
        }
        voiceService.startRecording()
        translationHUD.show(language: language, near: getCursorRect(), on: NSScreen.main)
        return true
    }

    /// Called only by physical key release. A chip/finish click leaves shortcut
    /// ownership intact until this point, so keyUp cannot start a second decode.
    private func translationShortcutReleased() {
        guard let token = translationSession?.id else { return }
        translationSession?.releaseHold(token: token)
        finishTranslationRecording(token: token)
        DispatchQueue.main.async { [weak self] in self?.attemptTranslationDelivery() }
    }

    private func finishTranslationRecording(token: UUID) {
        let durationMs = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        guard translationSession?.beginTranscription(token: token, durationMs: durationMs) == true else { return }
        recordingStartTime = nil
        let peak = peakRecordedLevel
        SystemAudioMute.shared.endMute()
        translationHUD.setProcessing(true)
        translationHUD.setStatus("轉錄中…")
        let service = voiceService
        service.stopAndTranscribeDetailed { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.translationSession?.id == token,
                      self.translationSession?.phase == .transcribing else { return }
                switch result {
                case .failure(let error):
                    let message = peak < 0.02
                        ? "麥克風幾乎沒有收到聲音，請檢查輸入裝置。"
                        : "轉錄失敗：\(error.localizedDescription)"
                    self.translationFailed(message, token: token)
                case .success(let snapshot):
                    let transcript = snapshot.normalizedText
                    let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Keep the same no-audio/phantom-injection guard as dictation.
                    guard !spoken.isEmpty, peak >= 0.02 else {
                        self.debugLog("discarded silent translation (peak \(peak), \(spoken.count) chars)")
                        self.translationFailed("沒有收到聲音", token: token)
                        return
                    }
                    guard self.translationSession?.beginTranslation(token: token) == true else { return }
                    self.translationSnapshot = snapshot
                    self.saveTranslationHistory(status: .notSent)
                    self.translationHUD.setText(spoken)
                    self.runTranslate(spoken, token: token)
                }
            }
        }
    }

    /// Cancel only the matching session. Keep any physical hold owned until its
    /// release; late STT/LLM callbacks cannot update the HUD or insert text.
    private func cancelTranslation(token: UUID) {
        guard let session = translationSession, session.id == token, session.isActive else { return }
        voiceService.cancelRecording()
        recordingStartTime = nil
        saveTranslationHistory(status: .cancelled)
        translationSession?.cancel(token: token)
        SystemAudioMute.shared.endMute()
        recordingTargetElement = nil
        translationHUD.hide()
    }

    private func translationFailed(_ message: String, token: UUID) {
        guard translationSession?.id == token, translationSession?.isActive == true else { return }
        cancelTranslation(token: token)
        saveTranslationHistory(status: .failed, reason: "翻譯未完成，原稿已保留")
        // Preserve the failure on the non-activating panel, without entering a
        // modal alert while the user may still be holding Command or Option.
        guard let language = translationSession?.language else { return }
        translationHUD.show(language: language, near: getCursorRect(), on: NSScreen.main)
        translationHUD.setProcessing(true)
        translationHUD.setStatus(message)
        translationHUD.onCancel = { [weak self] in
            guard self?.translationSession?.id == token else { return }
            self?.translationHUD.hide()
        }
        hideTranslationLater(token: token, after: 6)
    }

    /// Unlike polish, failed translation never injects the source transcript.
    private func runTranslate(_ transcript: String, token: UUID) {
        guard let session = translationSession, session.id == token, session.phase == .translating else { return }
        guard !APIKeyStore.shared.geminiKey.isEmpty else {
            translationFailed("語音翻譯需要 Gemini API Key，請在偏好設定填入。", token: token)
            return
        }
        translationHUD.setStatus("翻譯成\(session.language)…")
        GeminiPolishService.shared.enhance(
            text: transcript,
            mode: .translate(to: session.language),
            onPartial: { [weak self] partial in
                DispatchQueue.main.async {
                    guard let self = self, self.translationSession?.id == token,
                          self.translationSession?.phase == .translating else { return }
                    self.translationHUD.setText(partial)
                }
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.translationSession?.id == token,
                      self.translationSession?.phase == .translating else { return }
                switch result {
                case .success(let translated):
                    self.debugLog("translate OK (\(transcript.count) → \(translated.count) chars)")
                    let out = TranscriptNumberFormatter.format(translated)
                    self.translationAIText = translated
                    guard self.translationSession?.finish(text: out, token: token) == true else {
                        self.translationFailed("翻譯結果為空，沒有輸出文字。", token: token)
                        return
                    }
                    self.translationHUD.setText(out)
                    self.translationHUD.setStatus("翻譯完成，放開快捷鍵後貼上")
                    self.attemptTranslationDelivery()
                case .failure(let err):
                    self.debugLog("translate FAILED: \(err.localizedDescription)")
                    self.translationFailed("翻譯失敗：\(err.localizedDescription)", token: token)
                }
            }
        }
    }

    private func attemptTranslationDelivery() {
        guard let session = translationSession, session.phase == .ready else { return }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let modifiersReleased = NSEvent.modifierFlags.intersection(modifiers).isEmpty
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let delivery = translationSession?.takeDelivery(
            token: session.id, frontmostPID: foregroundPID, modifiersReleased: modifiersReleased) else { return }
        if delivery.destination == .originalApp {
            finishAndInject(delivery.text)
            translationHUD.setStatus("已送出\(session.language)")
        } else {
            // Do not restore an older clipboard over this fallback. A preceding
            // ordinary paste may still have its 300 ms restore timer pending.
            clipboardRestoreToken += 1
            savedClipboardItems = nil
            recordingTargetElement = nil
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(delivery.text, forType: .string)
            translationHUD.setStatus("已切換 App：譯文已複製，請自行貼上")
        }
        saveTranslationHistory(status: delivery.destination == .originalApp ? .sent : .copied,
                               finalText: delivery.text)
        UsageStatsStore.shared.record(chars: delivery.text.count, durationMs: session.durationMs)
        translationHUD.onCancel = { [weak self] in
            guard self?.translationSession?.id == session.id else { return }
            self?.translationHUD.hide()
        }
        hideTranslationLater(token: session.id, after: delivery.destination == .originalApp ? 1.5 : 6)
    }

    private func hideTranslationLater(token: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.translationSession?.id == token,
                  self.translationSession?.isActive == false else { return }
            self.translationHUD.hide()
        }
    }

    private func debugLog(_ msg: String) { inputSaLog(msg) }

    private func cancelDictation(token: UUID) {
        guard dictationSession?.id == token, dictationSession?.isActive == true else { return }
        dictationSession?.cancel(token: token)
        dictationPolishRequest?.cancel()
        dictationPolishRequest = nil
        voiceService.cancelRecording()
        voiceService.onPartialText = nil
        recordingStartTime = nil
        recordingTargetElement = nil
        SystemAudioMute.shared.endMute()
        saveDictationHistory(status: .cancelled)
        dictationHUD.hide()
        voiceHUD.hide()
    }

    private func completeDictation(text: String, aiText: String?, fallbackReason: String? = nil, token: UUID) {
        guard dictationSession?.finish(text: text, aiText: aiText, fallbackReason: fallbackReason, token: token) == true else {
            return
        }
        dictationHUD.setText(text)
        dictationHUD.setStatus("整理完成，放開修飾鍵後送出")
        attemptDictationDelivery()
    }

    private func attemptDictationDelivery() {
        guard let session = dictationSession, session.phase == .ready else { return }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        guard let delivery = dictationSession?.takeDelivery(
            token: session.id, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            modifiersReleased: NSEvent.modifierFlags.intersection(modifiers).isEmpty) else { return }
        let copied = delivery.destination == .clipboard
        if copied { keepInClipboard(delivery.text) }
        else { finishAndInject(delivery.text) }
        saveDictationHistory(status: copied ? .copied : .sent, finalText: delivery.text)
        UsageStatsStore.shared.record(chars: delivery.text.count, durationMs: session.durationMs)
        // Future prompts get recognition context, never a previous AI invention.
        if let snapshot = session.snapshot {
            if priorContextAppID != session.appID { recentUtterances.removeAll() }
            priorContextAppID = session.appID
            recordUtterance(snapshot.normalizedText)
        }
        let message = copied ? "已切換 App：文字已複製，請自行貼上"
            : (session.fallbackReason ?? "已送出")
        dictationHUD.setStatus(message, cancellable: false)
        dictationHUD.onCancel = { [weak self] in
            guard self?.dictationSession?.id == session.id else { return }
            self?.dictationHUD.hide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (copied || session.fallbackReason != nil ? 6 : 1.5)) { [weak self] in
            guard let self = self, self.dictationSession?.id == session.id,
                  self.dictationSession?.isActive == false else { return }
            self.dictationHUD.hide()
        }
    }

    private func keepInClipboard(_ text: String) {
        clipboardRestoreToken += 1
        savedClipboardItems = nil
        recordingTargetElement = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveDictationHistory(status: TranscriptHistoryStore.OutputStatus, finalText: String = "") {
        guard !dictationIsVocabulary, let session = dictationSession, let snapshot = session.snapshot else { return }
        persistHistory(.init(id: session.id, date: session.date, rawText: snapshot.rawText,
                            normalizedText: snapshot.normalizedText, aiText: session.aiText, finalText: finalText,
                            engine: snapshot.engine, durationMs: session.durationMs,
                            fallbackReason: session.fallbackReason, status: status,
                            appName: session.appName, appBundleID: session.appID), generation: dictationHistoryGeneration)
    }

    private func saveTranslationHistory(status: TranscriptHistoryStore.OutputStatus, finalText: String = "",
                                        reason: String? = nil) {
        guard let session = translationSession, let snapshot = translationSnapshot else { return }
        persistHistory(.init(id: session.id, date: translationStartedAt, rawText: snapshot.rawText,
                            normalizedText: snapshot.normalizedText, aiText: translationAIText, finalText: finalText,
                            engine: "\(snapshot.engine) → Gemini（\(session.language)）", durationMs: session.durationMs,
                            fallbackReason: reason, status: status,
                            appName: translationAppName, appBundleID: session.appID), generation: translationHistoryGeneration)
    }

    private func persistHistory(_ entry: TranscriptHistoryStore.Entry, generation: UUID) {
        // Disk I/O must never hold up the global keyboard event tap.
        let store = TranscriptHistoryStore.shared
        historyQueue.async {
            do { try store.record(entry, ifGeneration: generation) }
            catch { inputSaLog("history save failed: \(error.localizedDescription)") }
        }
    }

    /// One switch, two call sites (dictation polish + Option+P): route to the
    /// user's chosen polish provider. All services share the same
    /// `Result<String,Error>` main-thread completion, so the caller's post-pass
    /// and logging are provider-agnostic.
    @discardableResult
    private func dispatchPolish(
        text: String,
        mode: TranscriptionMode,
        provider: APIKeyStore.PolishProvider,
        priorContext: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> CLITextRequest? {
        switch provider {
        case .apple:
            // Apple's on-device 3B is deliberately NOT given prior context: extra
            // prompt length feeds its 詞彙表膨脹幻覺 (short input → invented output).
            // The local provider drops prior context here.
            ApplePolishService.shared.enhance(text: text, mode: mode,
                                              onPartial: onPartial, completion: completion)
            return nil
        case .gemini:
            GeminiPolishService.shared.enhance(text: text, mode: mode, priorContext: priorContext,
                                               onPartial: onPartial, completion: completion)
            return nil
        case .codex, .claude:
            return CLITextService.shared.enhance(text: text, mode: mode, provider: provider,
                priorContext: priorContext, completion: completion)
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
        guard let appID = dictationSession?.appID, priorContextAppID == appID else { return nil }
        let joined = prunedUtterances()
            .map { String($0.text.prefix(120)) }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// AI polish step in the unified pipeline (Gemini cloud or Apple local).
    /// After polishing (or if the provider can't run), injects text directly into
    /// the target element. No preview step required — text appears immediately;
    /// user can Cmd+Z to undo.
    private func runAIPolish(_ transcript: String, token: UUID) {
        guard dictationSession?.id == token, dictationSession?.phase == .polishing else { return }
        if dictationStyle == .verbatim {
            completeDictation(text: transcript, aiText: nil, token: token)
            return
        }
        let provider = dictationPolishProvider
        // Gemini uses an API key; CLI providers use their existing login.
        if provider == .gemini, APIKeyStore.shared.geminiKey.isEmpty {
            completeDictation(text: transcript, aiText: nil,
                              fallbackReason: "未設定 Gemini，已保留辨識原文", token: token)
            return
        }
        let providerTag = provider.displayName
        dictationHUD.setStatus("\(providerTag) 整理中 · \(dictationStyle.title)")
        debugLog("polish started (\(providerTag), \(transcript.count) chars)")
        dictationPolishRequest = dispatchPolish(
            text: transcript,
            mode: dictationMode,
            provider: provider,
            // Cloud providers can use prior context (Apple 3B omits it); compute
            // before this utterance is recorded so it never sees itself.
            priorContext: provider == .apple ? nil : priorContextForPolish(),
            onPartial: { [weak self] partial in
                DispatchQueue.main.async {
                    guard let self = self, self.dictationSession?.id == token,
                          self.dictationSession?.phase == .polishing else { return }
                    self.dictationHUD.setText(partial)
                }
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.dictationSession?.id == token,
                      self.dictationSession?.phase == .polishing else { return }
                self.dictationPolishRequest = nil
                switch result {
                case .success(let polished):
                    // Vocabulary is AI reference context only; no global term replacement.
                    // Keep the deterministic number formatter after polishing.
                    let final = TranscriptNumberFormatter.format(polished)
                    let newlines = final.filter { $0 == "\n" }.count
                    self.debugLog("polish OK (\(transcript.count) → \(final.count) chars, \(newlines) newlines)")
                    self.completeDictation(text: final, aiText: polished, token: token)
                case .failure(let err):
                    // Fall back to the raw transcript, but tell the user polish didn't run —
                    // silent fallback made key/network failures look like a formatting bug.
                    // The deterministic number pass still applies (it's the whole reason it
                    // exists as a rules layer: it must protect the raw-transcript fallback too).
                    self.debugLog("polish FAILED: \(err.localizedDescription) — injecting raw transcript")
                    self.completeDictation(text: transcript, aiText: nil,
                                           fallbackReason: "AI 整理失敗，已保留辨識原文", token: token)
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
            || translationSession?.isActive == true
            || dictationSession?.isActive == true
            || manualPolishToken != nil
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
        // Press actions are queued on main; another action can become active
        // after the event callback's earlier busy check.
        guard !isAnyRecordingActive else { return }
        guard let text = SelectionReader.read() else {
            flashHUDMessage("沒有選取文字")
            return
        }

        let token = UUID()
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = APIKeyStore.shared.polishProvider
        manualPolishToken = token
        voiceHUD.show(state: .processing("整理中 · Esc 取消"), near: getCursorRect(), on: NSScreen.main)
        manualPolishRequest = dispatchPolish(text: text,
                       mode: TranscriptionMode.activePolishMode, provider: provider) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.manualPolishToken == token else { return }
                self.manualPolishToken = nil
                self.manualPolishRequest = nil
                self.voiceHUD.hide()
                switch result {
                case .success(let enhanced):
                    // Match dictation's number formatting, then preview without
                    // replacing terms from the reference vocabulary.
                    let final = TranscriptNumberFormatter.format(enhanced)
                    guard targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                        self.keepInClipboard(final)
                        self.flashHUDMessage("已切換 App：整理結果已複製")
                        return
                    }
                    self.polishPreview.startPreview(original: text, enhanced: final)
                    self.showPolishHUD(final)
                case .failure(let err):
                    self.showError("潤飾失敗：\(err.localizedDescription)")
                }
            }
        }
    }

    private func cancelManualPolish() {
        guard manualPolishToken != nil else { return }
        manualPolishToken = nil
        manualPolishRequest?.cancel()
        manualPolishRequest = nil
        voiceHUD.hide()
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
        let injectedChangeCount = pb.changeCount
        pasteViaCmdV()
        NSLog("[InputSa] injectText: pasted via Cmd+V (\(text.count) chars)")

        // Restore the original clipboard after Cmd+V has had time to read it.
        clipboardRestoreToken += 1
        let token = clipboardRestoreToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, token == self.clipboardRestoreToken else { return }
            let items = self.savedClipboardItems
            self.savedClipboardItems = nil
            guard NSPasteboard.general.changeCount == injectedChangeCount else { return }
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
/// greppable). Local file only; traces the transcription → polish
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
