# PRD — 本地語音轉錄 SherpaVoiceService

> 建立日期：2026-06-30　|　狀態：Phase 1 開工中

## 目標
- 在 input-sa 內新增全本地、arm64 的 `SherpaVoiceService`，管線：**Paraformer → opencc `s2twp` 簡轉繁 → 分級道場糾正表 → 注入**。
- 飛航模式完整可用，必經步驟零雲端依賴；延遲維持 PoC 等級（~43x 即時）。
- 道場專有術語（神尊聖號、經典名、辦道/了愿…）辨識後可精準同音糾正。
- 用既有 `VoiceServiceProtocol` 接入，Groq 留 fallback、Gemini 潤飾降為可選進階模式。

## 範圍
- 新 provider `.sherpa`（`APIKeyStore.VoiceProvider` + `InputController.refreshVoiceService`）。
- Paraformer 解碼（沿用 PoC 已驗證的 `SherpaOnnx.swift` + bridging header + shared dylib）。
- 純 Swift 簡轉繁、分級糾正表、句末標點、長音檔切段。
- build.sh / install.sh 擴充 bundle 與簽章。

## 非範圍
- Intel / universal2（M5 自用 arm64-only）。
- 即時 hotword 偏置（Paraformer 不支援，走後處理糾正）。
- 重寫 HUD / 按鍵 / injectText（P0 已穩定）。
- 雲端必經步驟、線上糾正表同步。

## 已拍板決策（2026-06-30）
1. **opencc → 純 Swift 多階段字典**（build 時匯出 s2twp TSV 為分階段 JSON，Swift 做最長匹配；免 C++ 連結、可單元測試）。
2. **標點 → 先句末規則**（Phase 3），ct-transformer 模型延後（Phase 4 可選）。
3. **糾正表 → 兩級信心 + 道場模式開關**：
   - Tier A（always，全域安全）：錯形非常用詞 → 月會菩薩→月慧菩薩、金宮→金公、禮韻→禮運、改刀系統→道務系統、六祖談經→六祖壇經。
   - Tier B（dojoOnly，需開道場模式）：錯形是合法常用詞 → 半道→辦道、一貫到→一貫道、學傭→學庸、院力→愿力。
   - 越長的詞越安全優先精確替換；1–2 字高歧義鎖道場模式後。
4. **道場模式預設關**。
5. **VAD/切段 → 封裝在 SherpaVoiceService 音訊層**，Phase 1 不做。
6. Groq 保留為使用者可見選項；270MB .app 體積自用可接受。

## 分期

### Phase 1 — 最小可跑通（Paraformer + 簡轉繁 + 注入）
- 目標：選 `.sherpa` provider，按住 Option 說話 → 繁體文字注入，全離線。
- 涉及檔案：新增 `SherpaVoiceService.swift`、`SherpaOnnx.swift`+bridging header、`OpenCCConverter.swift`+`s2twp_dict.json`；改 `APIKeyStore.swift`(加 `.sherpa`)、`InputController.swift`(refreshVoiceService case)、`build.sh`(連結+bundle)、`install.sh`(codesign 驗證)。
- success：飛航模式 sherpa 模式錄音→正確繁體注入；RTF 與 PoC 相當；`codesign -v` 通過、無 DYLD 環境變數可啟動。
- 風險：dylib rpath × `codesign --deep`（中）；240MB 模型首次載入延遲 → service 常駐、lazy 載入後保溫（中）。

### Phase 2 — 分級道場糾正表 + 道場模式開關
- 涉及：`DojoCorrectionTable.swift`+`dojo_corrections.json`；`SherpaVoiceService` opencc 後插入糾正；偏好設定加道場模式 toggle；種子由 data.txt 提取 + 補神尊聖號/經典名（**開工前向用戶要完整清單**）。
- success：72 秒測試錄音 13 個錯詞於道場模式全數糾正；模式關閉時「半道而廢/一直到」不誤改。

### Phase 3 — 句末標點 + 輕量清理
- 涉及：`PunctuationFormatter.swift`，管線末端；（可選）去贅字。

### Phase 4 — 長音檔切段 + 可選模型
- 涉及：固定視窗切段；（可選）ct-transformer 標點 / Silero VAD + 偏好開關。

> Gemini 進階模式現成（`runAIPolish` 以 `geminiKey` 空值判斷自動跳過），不需新工作。

## 關鍵 API 簽名
- `final class SherpaVoiceService: NSObject, VoiceServiceProtocol`（`startRecording()` / `stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void)`）
- `OpenCCConverter.convert(_ simplified: String) -> String`
- `DojoCorrectionTable.correct(_ text: String, dojoMode: Bool) -> String`（Phase 2）

## 資產落地路徑（Phase 1）
- `InputSa/Resources/model/`：model.int8.onnx + tokens.txt
- `vendor/sherpa/lib/`：libsherpa-onnx-c-api.dylib + libonnxruntime.*.dylib
- `vendor/sherpa/include/`：c-api 標頭
- `vendor/sherpa/swift/`：SherpaOnnx.swift + bridging header
- `InputSa/Resources/opencc/s2twp_dict.json`：分階段字典
