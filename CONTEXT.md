# Session Context — 最後更新 2026-07-12 13:04

## 🔵 目前狀態（一句話）
**已成功開源分發（public repo，朋友已裝機使用）+ HUD 大幅精簡（拿掉五尊各自的粒子特效，改成即時聲波動畫+動態漸層外框）+ 偏好設定從「陽春原生視窗」徹底改成手刻自訂視覺（深色 pill 分頁列/金色膠囊控制項）。全部已 build + 裝機 + 自我截圖驗證過，等使用者親眼看過最終效果回饋滿不滿意。**

**✅ 2026-07-12：本輪所有改動已 commit + push 到 GitHub**（commit `07af34d`，使用者明確授權）。朋友端 `git pull` 可拿到新功能；Release zip 仍是 v2.0.0，若要讓一般朋友拿到需另發新 Release（未做）。

---

## ✅ 2026-07-12 完成（本輪，順序記錄）

### 1. GitHub 開源分發
- Public repo：**https://github.com/hallowjason/input-sa**（帳號 hallowjason）
- 清掉打字鍵盤時期的死碼（`BopomofoEngine.swift`／`KeyMapping.swift`／`CandidateWindowController.swift`／`UserDictionary/`／`AutoDetect/`／`tsi.db`／`bpmf_chars.db`）→ 備份在 `~/Desktop/.claude/projects/input-sa-legacy-backup/`（沒進 git 歷史）
- 新增 `package-release.sh`：build 前**暫時搬走**本機的 228MB SenseVoice 模型（`InputSa/Resources/model/sensevoice/*.onnx`）避免打進公開發布包、強制 ad-hoc 簽章（不管本機有沒有開發憑證）、build 完**自動搬回**模型，本機自己的離線功能不受影響
- 新增 `README.md`（面向朋友的安裝指南：下載 Release zip → 右鍵開啟繞過 Gatekeeper → 申請 Groq/Gemini key）、`.gitignore`（排除 build/、模型 .onnx、vendor/models-backup/、.claude/）
- 首個 Release `v2.0.0`（17MB，雲端優先不含本地模型）已發布
- **朋友端更新流程**：`git pull` 再重跑 `install.sh`（開發者），或回 Release 頁面抓新 zip（一般朋友）

### 2. Dojo 校正表新增 4 條（用真實模型比對抓出的，非猜測）
拿 Input-sa 實際打包的 SenseVoice 模型（不是 Whisper）跑一段真實道場訪談錄音，比對出這個模型真正會聽錯的詞：
`道物→道務`、`休班→修辦`、`證人→聖人`、`全勝→全聖`（都是 `dojoOnly` 層級）。已同步 `InputSa/Resources/dojo/` 種子檔 + `~/Library/Application Support/InputSa/` 運行時。

### 3. HUD 動畫大精簡
`InputSa/UI/VoiceHUDController.swift` 從 632 行砍到 ~260 行：
- **全部拿掉**：觀音的飄字入耳+甘露水噴泉、彌勒的字吸入肚+泡泡、關公的刀光+義字印章、耶穌的光環脈動、孔子的亂字入/齊字出——五尊神佛現在**統一只留漂浮/彈跳待機動畫**（`startIdleMotion()`，彌勒維持 belly-bounce 變體，其餘用垂直 float）
- 原因：使用者要求精簡＋要空間留給新的即時聲波動畫當視覺焦點

### 4. 新增即時聲波視覺化（Pixel 風格）
- `InputSa/AIServices/AudioLevelMeter.swift`（新檔）：共用元件，接在既有 `AVAudioRecorder`（Groq/Google/Sherpa 三個 provider 都有）上，用內建 `isMeteringEnabled`/`averagePower` 量測，**沒有改動錄音本身**，~30Hz 輪詢回呼
- `InputSa/UI/WaveformView.swift`（新檔）：像素風格「滾動音量歷史條」（18 欄 × 5 列低解析度點陣圖 + nearest 放大 3x），跟專案既有像素繪製慣例一致
- `VoiceServiceProtocol` 加 `onLevelUpdate` callback，`InputController.handleVoiceKeyDown` 接上轉給 `voiceHUD.updateAudioLevel`
- ⚠️ **如實告知使用者過的限制**：這是「音量隨講話跳動的像素長條」，不是逐樣本真實波形圖（三個 provider 都是錄到檔案再讀取，錄音當下沒有原始樣本可用）。若嫌不夠像真波形，要改用 `AVAudioEngine.installTap` 讀原始樣本，是更大幅的改動。

### 5. 翻譯語言選單擴充
`PreferencesWindowController.translateLanguages` 從 `["英文","泰文"]` 擴充成 `["英文","日文","韓文","泰文","越南文","印尼文"]`。純資料層改動，Gemini 翻譯 prompt 本來就吃動態字串。

### 6. HUD 視窗固定定位（仿 Typeless）
`VoiceHUDController.swift` 底部的 `floatingOrigin` **拆成兩個函式**：
- `floatingOrigin(size:below:screen:)`——游標相對定位，**保留給選字潤飾預覽視窗**（Option+P 那個 accept/reject 彈窗，它就是要跟著選取文字位置才合理）
- `fixedBottomCenterOrigin(size:screen:)`——**新的**，語音聽寫 HUD 專用，固定在螢幕正中下方，不再跟著文字游標跑
- ⚠️ 踩雷記錄：一開始想直接覆寫共用的 `floatingOrigin`，結果弄壞了潤飾預覽視窗的定位——**這兩個是不同語意的定位需求，不要合併成一個函式**。

### 7. HUD 動態漸層外框
`makeGradientBorder()`：`CAGradientLayer`（`.conic` 類型）+ `CAShapeLayer` 描邊遮罩，沿面板圓角邊緣畫一圈流動色彩（金→橘→粉→紫→青，非死板全彩虹）。
⚠️ **踩雷記錄（重要，AppKit CALayer mask 概念）**：一開始想直接旋轉整個 gradient layer 的 `transform.rotation.z`，結果整個矩形邊框（含遮罩）會一起轉，跟實際非正方形面板邊緣對不齊。**正解**：只動畫 `endPoint` 繞中心點轉（`CAKeyframeAnimation` on `"endPoint"`），遮罩幾何形狀完全靜止不動，只有底下的顏色映射在轉——因為 masking 是在 layer 自己的 bounds 空間計算，layer 的 `transform` 只影響「整坨已經 mask 完的結果」怎麼被放進 superlayer，不會讓遮罩形狀本身跟著轉。

### 8. 偏好設定視窗兩輪重做

**第一輪（排版 bug 修復，非視覺升級）**：加了 `DesignTokens.makeSectionCard()`（扁平卡片）想把「語音轉錄服務」「AI 潤飾服務」分成兩張卡片，結果卡片內部 `NSBox.contentView = contentStack` 完全沒配 Auto Layout 約束，導致第一張卡片被撐成空的巨大方框、第二張卡片內容跟外面文字重疊。使用者截圖抓到後修正，過程踩出一組完整的 AppKit hugging-priority 教訓（已寫入全域記憶 `reference_appkit_ui_testing.md`，摘要：box 和 contentStack 兩邊都要設 required hugging；就算兩邊都設了，外層被 NSTabView 撐開時 required hugging 仍然會輸；真正解法是加一個裸 `NSView()` 當彈簧吸收多餘空間）。

**第二輪（真正的視覺改造）**：使用者看過第一輪成果後回饋「還是很陽春，只是原生控制項套灰框，不是大改革」，附了健身 App／Cardy Pay 金融 App 的參考圖（大塊實心色彩、粗圓角、自訂膠囊控制件）。確認主色維持暖金色（跟 HUD 一致，不跟參考圖換紅色）後動手：
- **`InputSa/UI/PillTabBar.swift`（新檔）**：手刻 NSView，取代 NSTabView 原生分頁列。深色膠囊底 + 選中分頁實心金色 pill。`NSTabView` 本身設 `tabViewType = .noTabsNoBorder` 隱藏原生分頁列，由 PillTabBar 的點擊回呼驅動 `tabView.selectTabViewItem(at:)`
- **`InputSa/UI/PillSegmentedControl.swift`（新檔）**：手刻取代 NSSegmentedControl，用在 Groq/Google/本地 三選一（金色選中 pill）
- **`DesignTokens.swift` 新增**：`makeSolidBadge()`（實心色徽章，取代柔和色調提示框）、`makeSolidButton()`（實心金色 pill 按鈕，取代系統 rounded bezel）；`cardCornerRadius` 10→18
- 「道場模式」checkbox 換成 `NSSwitch`（原生膠囊滑動開關，免手刻）
- 兩個 `NSTableView`（自訂AI模式／道場詞庫）拿掉交替灰底、row height 加到 26
- ⚠️ **踩雷記錄**：PillTabBar 跟 NSTabView 的選中狀態是**兩個獨立的真相來源**——加了 `NSTabViewDelegate.tabView(_:didSelect:)` 同步回 `pillTabBar.select(idx)`，否則任何繞過點擊直接呼叫 `tabView.selectTabViewItem` 的路徑會讓畫面顯示的選中分頁跟實際內容不一致
- ⚠️ **踩雷記錄**：`makeSolidBadge()` 一開始給固定高度（`calloutHeight=44`），文字是完整句子（「目前使用：本地 Paraformer — 完全離線運算...」）比參考圖的短標籤長很多，兩行時第二行被擠出膠囊外——跟第一輪同一類 bug，同一種解法（pin 內容到 box + 兩邊 required hugging，不用固定高度）。另外 badge 沒有明確寬度約束時，`preferredMaxLayoutWidth` 隨便設一個比實際渲染寬度更窄的值會讓文字提早換行——寬度約束要跟卡片系統的 456pt 一致，`preferredMaxLayoutWidth` 要設得比它寬（讓真正的寬度約束說了算，而非 label 自己猜）

### 驗證方式（這次全程用的技術，比純讀程式碼可靠）
建了一支獨立離線渲染 harness（技術細節已寫入全域記憶 `reference_appkit_ui_testing.md`「離線截圖驗收法」章節）：把 `PreferencesWindowController` 相關程式碼跟自己寫的 `main.swift` 一起編譯進複製出來的 `.app` bundle，用 `cacheDisplay(in:to:)` 截圖存 PNG，自己用 Read 工具實際看過畫面（含淺色/深色模式各一輪），抓到 3-4 個真的排版 bug 才動手修，不是憑感覺交差。**這個方法論以後任何 AppKit 視覺工作都能重用**，不需要使用者截圖回報才能抓 bug。

---

## 背景目標
macOS 語音輸入法（仿 Windows SpeakSlow 聲聲慢）。Swift CGEventTap 裸編譯（無 SPM），
本地 sherpa-onnx STT（SenseVoice）+ OpenCC 簡轉繁 + 道場糾正表 + Gemini 潤飾/翻譯 + Groq/Google 雲端 STT 備選。
已開源：https://github.com/hallowjason/input-sa（public，朋友可自行安裝）。

## 操作方式（現況）
- **右 Option 按住**：錄音 → 放開 → 轉錄 → Gemini 潤飾（typeless 排版）→ 注入游標處，錄音中 HUD 顯示即時聲波動畫+流動漸層外框，固定在螢幕正中下方
- **右 Command 按住**：錄音 → 翻譯成偏好設定目標語言輸出（英/日/韓/泰/越/印尼六選一）
- **Ctrl+Option+P**：偏好設定（4 分頁，深色 pill 分頁列驅動）；**Option+P**：選取文字潤飾（彈窗仍跟隨游標位置，跟語音 HUD 定位邏輯不同）

## 程式碼地圖（本輪異動標記）
```
InputSa/App/AppDelegate.swift               ← 選單列 + 啟動
InputSa/InputMethod/InputController.swift   ← CGEventTap、右⌥/右⌘ PTT、runAIPolish、inputSaLog 全域 logger
                                              【本輪】接上 voiceService.onLevelUpdate → voiceHUD.updateAudioLevel
InputSa/AIServices/SherpaVoiceService.swift ← 本地 STT（decode→opencc→dojo correct→log 三階段）
                                              【本輪】加 AudioLevelMeter 量測
InputSa/AIServices/GroqVoiceService.swift   ← 雲端 STT（Whisper）【本輪】同上加量測
InputSa/AIServices/GoogleVoiceService.swift ← 雲端 STT（含台語）【本輪】同上加量測
InputSa/AIServices/AudioLevelMeter.swift    ← 【新檔】共用音量量測元件
InputSa/AIServices/GeminiPolishService.swift← 模型 fallback 鏈，SSE 串流
InputSa/AIServices/TranscriptionMode.swift  ← 潤飾/翻譯 prompt + dojoVocabularySection
InputSa/AIServices/DojoCorrectionTable.swift← 精確替換 + 拼音同音層；24 詞條（本輪+4）
InputSa/UI/VoiceHUDController.swift         ← 【大改】液態玻璃 HUD，五尊統一漂浮動畫（拿掉粒子特效）
                                              + 即時聲波 + 動態漸層外框；floatingOrigin 拆成兩個函式
InputSa/UI/WaveformView.swift               ← 【新檔】像素風格滾動音量條
InputSa/UI/HUDCharacter.swift               ← 角色 enum、每尊耳機錨點座標
InputSa/UI/DesignTokens.swift               ← 【新檔】偏好設定共用視覺常數/工廠函式
InputSa/UI/PillTabBar.swift                 ← 【新檔】自訂深色分頁列
InputSa/UI/PillSegmentedControl.swift       ← 【新檔】自訂金色選中分段控制項
InputSa/Preferences/PreferencesWindowController.swift ← 【大改】PillTabBar 驅動、4 分頁全部改用卡片系統
build.sh / install.sh                        ← 裸編譯打包本機安裝（開發者用）
package-release.sh                           ← 【新檔】GitHub Release 打包（雲端優先、強制 ad-hoc 簽章）
README.md / .gitignore                       ← 【新檔】面向 GitHub 公開 repo
```

## 待辦 / 未決事項
- **【最優先】本輪所有改動尚未 commit 到 git**——`git status` 有 8 個 modified + 5 個新檔案。使用者確認滿意後才 commit + push（GitHub public repo 才會更新，朋友端才拿得到）
- **【次優先】使用者尚未親眼確認最終視覺效果**——本輪全部改動都已 build/裝機/自我截圖驗證過排版正確，但「好不好看、滿不滿意」這個主觀判斷還沒收到使用者回饋。下一棒開場如果使用者說「還是不喜歡」，先問清楚具體是哪個元件（分頁列/選擇器/徽章/按鈕/卡片）不對，不要整套重來
- Preferences Phase 2（上一輪計畫裡明確列為「這次不做」，未來若使用者要）：自訂 AI 模式／道場詞庫兩個表格改成真正的卡片式列表（現在只是拿掉交替灰底+加大行高，底層還是原生 NSTableView 網格）
- [ ] P1（舊）：refreshShortcutCache migration 根治 modifier-only 殘留 shortcut bug（歷史遺留，本輪未動）
- [ ] P2（舊）：翻譯模式也注入道場詞彙表（現在只有潤飾有）
- [ ] P2（舊）：用完還原剪貼簿；靜音 VAD
- [ ] `assets_dl/` 暫存需使用者手動清（Claude rm 被權限擋）

## 踩雷點（動手前必看，本輪新增在最上面）
- **AppKit 卡片/徽章高度動態撐開的完整解法**：pin 內容到 box 四邊約束 + box 和內容 view 兩邊都設 `.required` vertical hugging + 若外層容器（如 NSTabView）仍會撐開就加裸 `NSView()` 彈簧吸收多餘空間。完整技術細節見全域記憶 `reference_appkit_ui_testing.md`
- **自訂控制元件跟原生元件混用時，選中狀態可能有兩個真相來源**（如 PillTabBar vs NSTabView）——任何繞過使用者點擊路徑的程式化切換都要另外同步，用 delegate callback 統一
- **CAGradientLayer 動畫「流動邊框」效果，不要旋轉 layer 的 transform**（會連遮罩形狀一起轉，非正方形面板會對不齊）——只動畫 `endPoint`（conic 類型）繞中心點轉
- **離線截圖驗收法**（screencapture 被 TCC 擋時）：完整流程見全域記憶 `reference_appkit_ui_testing.md`「離線截圖驗收法」章節。重點：harness 檔名必須叫 `main.swift`、要塞進複製的 `.app` bundle 讓 Bundle.main 生效、截圖前務必 `window.makeFirstResponder(nil)` 否則會截到 field editor 假重疊
- **SourceKit「Cannot find type」全是 false positive**（裸編譯無 module），看 `./build.sh` 結果為準
- **build.sh 資源複製已加 rm 前置**：重複 build 時 `cp -R dir existing-dir` 會巢狀
- **rm 被權限系統擋**時改用 `mv` 到 scratchpad
- **NSAlert runModal 在 showError**：轉錄失敗會跳 modal alert
- 偏好視窗需 `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]`
- **改詞條要同步兩處**：`InputSa/Resources/dojo/` 種子 + `~/Library/Application Support/InputSa/` 運行時
- `~/Library/Logs/InputSa.log`：STT raw → dojo corrected → polish out 三階段，錯詞先看這個檔判斷哪層漏
- **zsh 內建 `log` 指令會蓋掉 `/usr/bin/log`**，查 unified log 必須用 `/usr/bin/log`

## 下次繼續
```bash
cd /Users/gooo/Desktop/.claude/projects/input-sa
# 對 Claude 說：「讀 CONTEXT.md，繼續 input-sa」
# 現況：GitHub 開源分發完成、HUD 精簡+聲波動畫+漸層外框完成、偏好設定兩輪重做完成，全部已 build/裝機/自我截圖驗證
# 未決：① 使用者對偏好設定最終視覺、HUD 聲波/漸層動畫的實際觀感回饋（最優先，見上方待辦）
#       ② 舊 P1/P2 項目、Preferences Phase 2（表格卡片化）等使用者指示優先序
# 環境：provider=sherpa（本地）、dojoMode=true；GEMINI_API_KEY 在 ~/.env 可供 curl 測試
# 驗證離線 UI 用「離線截圖驗收法」，見全域記憶 reference_appkit_ui_testing.md
```
