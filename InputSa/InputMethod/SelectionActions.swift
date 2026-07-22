import AppKit

/// 劃詞問答 (⌃⌥Q) and 劃詞翻譯 (⌃⌥T) flows. Kept in an extension because
/// InputController's main file is already large; the stored state
/// (qaKeyRecording / qaSelectedText / selectionActionCursor) lives there since
/// extensions can't declare stored properties. Both features read the selection
/// via SelectionReader, run against Gemini, and show the result in the
/// AnswerPanel WITHOUT injecting anything into the user's document.
extension InputController {

    // MARK: - 劃詞問答 (⌃⌥Q, hold to speak)

    /// Q went down: capture the selection now (before the mic opens), then start
    /// recording the spoken question. No selection ⇒ a brief toast, no recording.
    /// Returns whether recording actually started, so the generic hold dispatch
    /// can clear its active-action state when this bails out early.
    @discardableResult
    func startSelectionQA() -> Bool {
        guard let selection = SelectionReader.read() else {
            flashHUDMessage("沒有選取文字")
            return false
        }
        guard micReadyOrExplain() else { return false }
        qaSelectedText = selection
        qaKeyRecording = true
        peakRecordedLevel = 0
        selectionActionCursor = getCursorRect()
        recordingStartTime = Date()

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
        voiceHUD.recordingCaption = "問題錄音中"
        voiceHUD.show(state: .recording, near: selectionActionCursor ?? getCursorRect(),
                      on: NSScreen.main)
        return true
    }

    /// Q released: stop recording, transcribe the question, ask Gemini, show the
    /// answer. QA hard-routes to Gemini (like translation / 口頭修正) — no Gemini
    /// key means a toast, never a silent fallback to another provider.
    func finishSelectionQA() {
        qaKeyRecording = false
        let selection = qaSelectedText ?? ""
        qaSelectedText = nil
        SystemAudioMute.shared.endMute()
        recordingStartTime = nil

        voiceHUD.setState(.processing("轉錄中…"))
        voiceService.stopAndTranscribe { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure:
                    self.voiceHUD.hide()
                    self.flashHUDMessage("轉錄失敗，請再試一次")
                case .success(let transcript):
                    let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard question.count >= 2 else {
                        self.voiceHUD.hide()
                        self.flashHUDMessage("沒聽清楚問題")
                        return
                    }
                    guard !APIKeyStore.shared.geminiKey.isEmpty else {
                        self.voiceHUD.hide()
                        self.flashHUDMessage("劃詞問答需要 Gemini API Key")
                        return
                    }
                    self.askSelectionQuestion(selection: selection, question: question)
                }
            }
        }
    }

    private func askSelectionQuestion(selection: String, question: String) {
        voiceHUD.setState(.processing("思考中…"))
        inputSaLog("qa ask: q=\(String(question.prefix(60))) sel=\(selection.count) chars")
        GeminiPolishService.shared.enhance(
            text: question, mode: .qa(selectedText: selection)
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.voiceHUD.hide()
                switch result {
                case .success(let answer):
                    inputSaLog("qa answer: \(answer.count) chars")
                    AnswerPanelController.shared.show(
                        title: "問答", body: answer,
                        near: self.selectionActionCursor ?? self.getCursorRect())
                case .failure(let err):
                    inputSaLog("qa FAILED: \(err.localizedDescription)")
                    self.flashHUDMessage("問答失敗，請再試一次")
                }
            }
        }
    }

    // MARK: - 劃詞翻譯 (⌃⌥T, single press)

    /// Read the selection, decide the direction (CJK ratio), and translate.
    func triggerSelectionTranslate() {
        guard let text = SelectionReader.read() else {
            flashHUDMessage("沒有選取文字")
            return
        }
        guard !APIKeyStore.shared.geminiKey.isEmpty else {
            flashHUDMessage("劃詞翻譯需要 Gemini API Key")
            return
        }
        selectionActionCursor = getCursorRect()
        let preferredForeign = UserDefaults.standard
            .string(forKey: "com.inputsa.selectionTranslateLang") ?? "英文"
        let target = SelectionTranslateDirection.targetLanguage(
            for: text, preferredForeign: preferredForeign)
        performSelectionTranslate(source: text, target: target)
    }

    /// One translation run — reused by the initial trigger and the 英/泰 toggle.
    private func performSelectionTranslate(source: String, target: String) {
        voiceHUD.show(state: .processing("翻譯中…"),
                      near: selectionActionCursor ?? getCursorRect(), on: NSScreen.main)
        inputSaLog("selection translate → \(target): \(source.count) chars")
        GeminiPolishService.shared.enhance(
            text: source, mode: .selectionTranslate(target: target)
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.voiceHUD.hide()
                switch result {
                case .success(let translated):
                    AnswerPanelController.shared.show(
                        title: "翻譯 → \(target)", body: translated,
                        near: self.selectionActionCursor ?? self.getCursorRect(),
                        toggle: self.makeTranslateToggle(source: source, currentTarget: target))
                case .failure(let err):
                    inputSaLog("selection translate FAILED: \(err.localizedDescription)")
                    self.flashHUDMessage("翻譯失敗，請再試一次")
                }
            }
        }
    }

    /// The 英/泰 toggle only makes sense Chinese → foreign; when translating a
    /// foreign passage into 中文 the target is fixed, so no toggle is shown.
    private func makeTranslateToggle(source: String, currentTarget: String)
        -> AnswerPanelController.LanguageToggle? {
        guard SelectionTranslateDirection.isChineseToForeign(source) else { return nil }
        return AnswerPanelController.LanguageToggle(
            options: ["英文", "泰文"], current: currentTarget
        ) { [weak self] newLang in
            guard let self = self else { return }
            UserDefaults.standard.set(newLang, forKey: "com.inputsa.selectionTranslateLang")
            self.performSelectionTranslate(source: source, target: newLang)
        }
    }
}
