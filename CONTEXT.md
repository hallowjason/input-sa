# Session Context — 最後更新 2026-07-16（深夜）

## 🔵 目前狀態（一句話）
**未 commit 的改動：①道場共編詞庫全功能（verifier 9/9）②偏好設定「Apple 視覺改版 v3」——System Settings 側欄版面＋apple.com 視覺紀律（使用者嫌 v2 retro ledger 廉價，經 HTML mockup 提案核准後全面重做；v2 與抽屜結構已被 v3 完全取代）。已裝機；等使用者親測後一起 commit＋發版。**

## ✅ 2026-07-16 深夜完成（偏好設定 Apple 視覺改版 v3）
- **背景**：使用者對 v2 retro ledger 評價「非常廉價」，指定用 `~/.claude/references/design-md-library/design-md/apple/DESIGN.md` 重新提案、捨棄過去所有視覺基礎。先做互動 HTML mockup（`design-refs/apple-proposal.html`，瀏覽器四分頁×深淺色自驗）獲使用者「這很棒，就這樣改」後才動 Swift
- **設計宣告**：版面骨架＝macOS System Settings（側欄＋分組白卡列）；視覺紀律＝apple.com（#f5f5f7 畫布/#1d1d1f 墨、白卡 10pt 圓角 hairline、**唯一彩色 Apple Blue #0071e3 只給互動元件**、綠/橘點為語意狀態色、徽章單色化：一律套用=墨實心/限道場・同音=淺灰/共編=細框）
- **結構**：視窗 520×640 → **780×560 固定**（.fullSizeContentView＋透明標題列）；`PreferencesSidebar.swift`（新檔：NSVisualEffectView .sidebar 材質、像素觀音 64pt 原尺寸 app 識別、四個手繪 nav 按鈕，選中=accent 圓角 pill；選擇單一真相在 controller.showPane）；四個 pane 各自為 NSScrollView，make…Content() 控制樹照舊
- **控制項替換（同 action 語意）**：PillSegmentedControl → 原生 NSPopUpButton（provider index 0/1/2=groq/google/sherpa、polish 0/1=gemini/apple 不變）；InkPillButton → AccentTextButton 藍字按鈕（卡片 footer「＋新增」「用說的新增」，setTitle 保樣式）；鍵帽改「動作名＋說明左、灰 chip 右」原生排法；API Key 欄移入卡列（mono 11、寬 220）
- **DesignTokens v3**：新 Palette＋groupCard（autoSeparators 參數：條件列自帶 leading hairline 包 wrapper，隱藏時分隔線跟著走）/row/statusRow/group/popup/pushButton/textButton/keycap/badge(BadgeStyle) 工廠；**保留給 HUD**：accentGold、monoFont、BadgePill 舊簽名（新參數全有預設值）；**保留給 EditorSheets**：inkButton/softButton/makeFieldGrid/Spacing/Grid/PillSegmentedControl（sheets 功能元件未動，自動吃新單色 palette）；FlippedView 從 DrawerCardView 搬入
- **CardListView v3**：白卡內 flat rows（48pt＋hairline 分隔）、Row.icon 可選（dojo 無圓徽、AI 模式留 emoji tile）、**高度 hug 內容 cap maxHeight**（無死空間）、hover 灰底＋徽章↔編輯/刪除交叉淡化保留、shared read-only index 映射不變；dojo 列 subtitle 改「常見誤辨：X」、新增 footer 詞條計數（dojoCountLabel，取代 drawer summary）
- **移除**：DrawerCardView.swift（刪檔＋build.sh SOURCES）、refreshDrawerSummaries 全部呼叫點、banner masthead（識別移入側欄）
- **驗證**：./build.sh 乾淨（僅既有 NSUserNotification 棄用警告）；dojo 13 項迴歸全過；離線截圖 harness 重建（**新雷**：離線對 NSScrollView/整 contentView cacheDisplay 全白，要對 documentView 截再手動合成——已寫入全域記憶 reference_appkit_ui_testing.md 第 9 點）四分頁×深淺 8 張逐張人工比對 mockup；fresh verifier 驗證（結果見下次 session 或本次記錄）
- **已知非問題**：快捷鍵錄製框深色偏亮＝既有元件樣式（v2 前就存在）；harness 裡 dojoMode switch 顯示 off＝bundle id 不同的 UserDefaults 假象

## ✅ 2026-07-16 晚間完成（偏好設定視覺大改版 v2 — retro ledger 設計系統）
- **背景**：使用者對早上外包（Codex mockup）做出來的抽屜 UI 成效不滿，附 budgeting-app 參考圖（米色畫布＋莫蘭迪大色塊咬合卡＋Swiss 粗黑編排＋右側數值），指定「這次 Claude 自己做，套 figma 等級設計規範精細度」。方向判讀：視覺走參考圖的復古帳本語言，工程精細度按 figma DESIGN.md 等級（精確 type scale/kern、pill 幾何、chrome 色彩紀律——**chrome 只有 ink 與 paper，彩色只屬於色塊本身，全面禁用 system 色**）
- **DesignTokens.swift 重寫**：`Palette`（canvas/paper/paperHi/ink/inkInverse + sage/camel/butter/red/orange/silver/forest，全部 light/dark 雙組 dynamic）＋語意映射（statusLocal=forest/statusCloud=camel/statusWarn=orange/statusError=red）；type scale 工廠（`uiFont`/`styledLabel` 帶 kern、`sectionLabel` tracked 小標、`caption`）；結構工廠（`hairline`/`settingRow`/`statusRow` dot+值）；控制項（`inkButton` 實心黑 pill/`softButton` ink8%、`InkPillButton` 自繪含 `setTitle` 保樣式、`StatusDotView`/`HairlineView`）。**mono 只留鍵帽與 API Key 欄**，CJK 內文全改 SF Pro/PingFang。舊 API（makeSectionCard/makeFieldGrid/monoFont/accentGold）保留給 HUD
- **DrawerCardView**：header 84pt、圓角 26、白圓徽 44（paperHi 實心，dark 下 glyph 翻 cream）、category kern 2.0/title 22 heavy kern -0.3、**新增 `setSummary` trailing 狀態值**（參考圖 -$35 位置：本地/右 ⌥/標準/54 詞條），`refreshDrawerSummaries()` 在六個變更點推播
- **四 tab 拆嵌套白卡**：改「sectionLabel＋設定列＋hairline」扁平群組；systemGreen/Blue 狀態橫幅改 dot 狀態列；連結按鈕 ink 底線（棄 linkColor）；徽章色票化（一律套用=金/限道場=silver/同音=sage/共編=camel）；emoji 圖示全拿掉改 SF Symbols；文案 CJK 標點全形化（逗號/冒號/斜線）
- **banner**:「偏好設定」27 heavy＋INPUT-SA mono 小標、像素觀音右置;視窗 520×640
- **驗證**:離線截圖 10 張（收合+四抽屜 × 深淺）逐張人工檢查;./build.sh 乾淨;dojo 13 項迴歸全過;fresh verifier 8/8 CONFIRMED（功能鏈/色票紀律/PillTabBar 無殘留/HUD 無破壞/summary 呼叫點/key 未變）
- **順手清掉**:PillTabBar.swift 死碼（檔案移除＋build.sh SOURCES 拿掉——CONTEXT 遺留待辦完成）;`design-refs/`（外包 mockup＋參考圖整包）與截圖 harness 已移入 `~/.Trash/input-sa-*-20260716`,使用者清空垃圾桶即可（本文件中對 design-refs/mockup-v4.html 的引用僅為歷史記錄）
- **已知非問題**:截圖 harness 裡 Gemini API Key 欄顯示亂碼——ad-hoc 重簽後 Keychain ACL 不認,是 harness 環境現象;真 app 裝機版簽章一致不受影響,親測時確認即可

## ✅ 2026-07-16 完成（偏好設定抽屜 UI 改版）
- **流程**：使用者指定「外部 AI 規劃版面、Claude 只驗收、實作嚴禁動功能」。Gemini 三輪（plan+A/B 案+互動 mockup）被使用者退貨；改派 **Codex**（`codex exec --sandbox workspace-write -i 圖.png -`，prompt 走 stdin——**變長 `-i` 會吞掉位置參數 prompt，這是坑**）產 `design-refs/mockup-v4.html`，使用者核准為基底＋「收斂」指示
- **實作**（executor＋我收尾）：移除 PillTabBar/NSTabView 分頁，改四個 `DrawerCardView`（錢包卡堆疊、-18pt 咬合、初始全收合、點頭展開 0.42s cubic-bezier(0.22,1.26,0.36,1)、可多開）；`PreferencesWindowController` 856 行拆成主檔＋四個 tab extension 檔（stored properties 從 private 改 internal——extension 不能放 stored property）；DesignTokens 加莫蘭迪色票（鼠尾草/卡其/鵝黃/紅，深淺各一組）；道場模式 switch 從 Tab1 移到道場詞庫抽屜（同控制項同 action，只搬位置）
- **驗收**：10 張離線截圖（收合+四抽屜 × 深淺）逐張人工檢查；修掉 CardListView 固定高度切半列問題（道場 258→266=4列+半列暗示、AI 模式 268→172=貼合3列）；fresh verifier 8/8 CONFIRMED（控制項/selector/key 一一對應、API Key 雙保險、分享鏈、build 乾淨、DrawerCardView 純 layout、PillTabBar 已死碼）
- **踩雷（新）**：①截圖 harness 的 bundle id 與真 app 不同 → `UserDefaults.standard` 讀到空網域，dojoMode switch 在截圖永遠顯示 off——**是假象不是 bug**，驗 defaults 綁定要用真 app；②codex exec 的 `-i` 是變長參數會吃掉後面的 prompt，prompt 一律走 stdin（`codex exec ... - <<'EOF'`）
- **遺留（低優先）**：PillTabBar.swift 死碼未刪（自包含可編譯，要清就從 build.sh SOURCES 拿掉+刪檔）；Gemini API Key 欄位明碼顯示是**改版前既有行為**，若要改密碼樣式屬功能小改另案；快捷鍵錄製框深色模式偏亮（既有元件樣式）

## ✅ 2026-07-16 完成（道場共編詞庫）
- **雲端**：Google Sheet `1XHEQahuFD5lWM87JQIZGMYNsTdSWtICHFe814SlwMbI`（分頁 vocab，欄位 correct|wrong|tier|phonetic|note|submitter|submitted_at|status；**審核＝把 status 改 approved**）＋ GAS Web App（`tools/gas-dojo-vocab/`，scriptId `1ENJn8VMnPDhYLIpD_TNhUjCFeYQDs8Q1lYhYBWPgJ_aiMbXHVyT_1_10`，endpoint `https://script.google.com/macros/s/AKfycbzGlQvM-yIr4H0LMjxFwlwkRRDYpNR_tm16tL5bGywfK_UFxkET3hKeHb4xPHL5YyMbkA/exec`）。doGet 只回 approved；doPost submit 寫 pending（長度驗證＋每日 200 條全域上限＋同 correct+wrong 去重）。curl 兩步驟法實測三路徑全過
- **App 端**：新檔 `DojoSharedSync.swift`（啟動＋24h Timer 同步→原子寫 `dojo_shared.json`→reload；submit POST）；`DojoCorrectionTable` 拆 personalEntries/sharedEntries/合併表（**個人優先去重**，save() 只寫個人檔——編輯器永不污染個人檔）；`dojoVocabularySection` cap 80 詞（個人優先）；右 Shift 確認改動態尺寸 DojoConfirmView（↩ 加入／⇧↩ 加入並分享／⎋ 取消）；DojoEntrySheet 加分享 switch（預設 off）；偏好設定 Tab1 加「共編暱稱」、道場分頁共享詞條唯讀＋「共編」徽章
- **驗證**：build 乾淨；tests/main.swift 13 項迴歸全過；fresh verifier 九項全 CONFIRMED（轉錄路徑零改動/同步輸入分離/存檔隔離/合併規則/離線韌性/cap/macOS12/build/key 前綴）；確認面板離線截圖淺深色×長短詞條親眼驗收；裝機後啟動同步實測 `shared sync ok: 27 entries`
- ⚠️ **事故與救援（已完全復原）**：verifier 測試時誤用真 save() 覆寫了 runtime `dojo_corrections.json`（27→24 條）。因今早建 Sheet 時匯入的正是該檔原始內容，已從 Sheet seed 列完整還原 27 條（含只在本機的 補員補缺/崇正/崇正寶宮）。教訓：**任何 harness 呼叫 save() 前必須先把 HOME 指到沙盒目錄**
- **踩雷（新）**：DojoConfirmView 操作列（多 pill 橫排）的 intrinsic 寬度不會透過外層 NSStackView 傳播（BadgePill 用內部約束定寬）——卡片要用 `legend.fittingSize.width + 2*inset` 當 minWidth 強制，否則短詞條時操作列溢出卡片右緣（屬「多控制項要算總寬」同類）
- **已知取捨**：endpoint 匿名可寫（URL 將隨開源 repo 公開），防線是審核閘門＋GAS 端驗證；成功但 0 條 approved 的同步會清空快取（無 version-skip 防護，低風險）；repo 種子檔維持 24 條（新增 3 條靠雲端同步分發，不必進安裝包）

## ✅ 2026-07-14～15 完成（Apple 本地潤飾 provider）
- **可行性 spike**（scratchpad/fm-quality/，不進 repo）：`SystemLanguageModel.default` 本機（M5, macOS 26.5.2）可用，同六題道場句對比 Gemini 6/6 vs Apple 自由文字模式 3/6；四輪 prompt 迭代確認 3B 是能力天花板，非 prompt 問題；context window 僅 4096 tokens
- **新檔 `InputSa/AIServices/ApplePolishService.swift`**：介面比照 GeminiPolishService（`enhance`/`polish`，completion 主執行緒回呼）。整檔 `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)` 包裹，`import` 自動弱連結，macOS 12 部署目標不受影響（`otool -L` 確認 weak）
- **`APIKeyStore.swift`** 加 `PolishProvider`（`.gemini`/`.apple`，UserDefaults key `com.inputsa.polishProvider`，預設 `.gemini`）
- **`InputController.swift`** 新增 `dispatchPolish` 單一工廠分流 `runAIPolish`／`triggerManualPolish`；翻譯與口頭修正（dojoEntryParse）**維持硬寫 Gemini 不受影響**；Apple provider 失敗時走「原始轉錄稿＋通知」，**絕不悄悄改送雲端**；`handleVoiceKeyDown` 加 `ApplePolishService.prewarm()`——右 Option 按下的瞬間喚醒本地模型，把暖機時間蓋在講話時間裡
- **`PreferencesWindowController.swift`** Tab 1 新增「AI 潤飾服務」卡（PillSegmentedControl Gemini/Apple 本地），狀態徽章、不可用時橘色警示＋白話原因、註明翻譯與口頭修正固定用 Gemini
- **使用者實測回報「提示詞整段被注入輸出」（3B 自由文字模式的已知不穩定）**，修法三層：
  1. **治本**：改用 FoundationModels 的 guided generation（`@Generable` 表單約束解碼）取代自由文字——模型結構上只能填一個 `text` 欄位，spike 重測 18 次呼叫零污染
  2. **保險網**：輸出過提示詞碎片指紋比對，中招自動重試一次，兩次都不行才丟錯（走既有原稿 fallback，不進雲端）
  3. **防暴走**：`GenerationOptions(maximumResponseTokens: 1024)` 封頂——測試曾抓到一次模型寫了 80 秒，現在會被截斷後由保險網攔下重試
  - 副作用：改用 guided generation 後 HUD 不再逐字串流預覽（一次到位），改維持靜態「AI 潤飾中（本地）…」文字，正常現象
- **`build.sh` 踩雷修復**：CommandLineTools 的 SDK 沒有 FoundationModels 的巨集外掛，`@Generable` 編譯會報 `plugin for module 'FoundationModelsMacros' not found`——改用 `xcrun --sdk macosx --show-sdk-path` 優先取 Xcode SDK（已加註解＋fallback 鏈）
- **驗證鏈**：獨立 fresh-context verifier 七項全 CONFIRMED（範圍紀律/失敗不外洩/零回歸/舊系統相容/主執行緒契約/UserDefaults 無撞名/build 乾淨）；離線截圖驗收法截四張（Gemini/Apple × 淺/深色）親眼核對過；使用者裝機真實聽寫測試通過

## ✅ 2026-07-12 下午完成（UX 研究 + 第三輪重做 + 兩個新功能）

以 ux-designer 流程做過通盤審查後實作，四個 Phase 全過 verifier：
1. **CardListView（新檔 InputSa/UI/）**：取代兩個 NSTableView。一列一圓角卡、字首/emoji 圓徽、tier「一律套用（金）/限道場（灰）」與「同音（藍）」實心膠囊徽章、hover 徽章↔編輯/刪除按鈕 alpha 交叉淡化（不用 isHidden 避免 reflow）。空狀態文字內建。
2. **EditorSheets（新檔 InputSa/Preferences/）**：DojoEntrySheet／PromptEntrySheet 視窗 sheet 取代 NSAlert；AI 指令改多行 NSTextView；道場「常見誤辨」欄改選填（留空＝wrong=correct，只靠同音比對）。自訂 AI 模式終於有「編輯」（UserStyleModel 加 updateCustomPrompt 保序更新）。
3. **Tab 1「語音服務」**：API Key 自動儲存（NSTextFieldDelegate.controlTextDidEndEditing + windowWillClose 雙保險），移除儲存按鈕與確認彈窗。
4. **Tab 2「快捷鍵」**：七行文字牆改鍵帽（BadgePill 重用）+一句話說明的總覽卡；刪除「句尾說請幫我翻譯成英文」過時說明（選單列同步修）；翻譯語言+HUD 角色歸「外觀與語言」卡。視窗 560→620 高。
5. **AI 模式接上真實功能**：選單列「AI 模式」子選單（menuNeedsUpdate 動態重建+勾選），TranscriptionMode.activePolishMode 持久化於 UserDefaults；runAIPolish 與 Option+P 都套用；HUD 顯示「AI 潤飾中（模式名）…」。**順手修掉 .custom prompt 裸拼接的注入漏洞**（現在有 <transcript> 隔離+道場詞彙表）。
6. **口頭修正（右 Shift 長按，新功能）**：說「崇正寶宮的崇是崇高的崇…」→ 現用 STT 轉錄 → Gemini `.dojoEntryParse` few-shot prompt 解析 → HUD「加入詞庫『…』？↩ 確認 ⎋ 取消」→ save 立即生效。偏好設定道場分頁另有「🎙 用說的新增」鈕走同管線預填 sheet。共用解析器 DojoVoiceParser（新檔，含 code-fence/前後綴 JSON 防禦）。
   - **prompt 是用真實 Gemini API 迭代過的**：第一版兩個案例解析錯（保留轉錄錯字、把指認詞串成目標詞），改 few-shot 後三個 held-out 難例全 PASS（測試腳本在 scratchpad，已丟）。
   - **已知取捨**：右 Shift 打大寫時 HUD 會閃現後被 keyDown 取消（字母照常輸出）——與右⌘組合鍵取消同一契約，verifier 確認非缺陷但提醒使用者知悉。若使用者嫌煩，備案是延遲 300ms 才顯示 HUD。

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
- **右 Option 按住**：錄音 → 放開 → 轉錄 → Gemini 潤飾（套用選單列選定的 AI 模式）→ 注入游標處，錄音中 HUD 顯示即時聲波動畫+流動漸層外框，固定在螢幕正中下方
- **右 Command 按住**：錄音 → 翻譯成偏好設定目標語言輸出（英/日/韓/泰/越/印尼六選一）
- **右 Shift 按住**：口頭修正——說詞條釋義（「崇正寶宮的崇是崇高的崇…」）→ Enter 確認加入道場詞庫
- **選單列 🎙 → AI 模式**：切換潤飾模式（標準/IG 貼文/條列重點/正式書信/自訂），聽寫與 Option+P 都套用
- **Ctrl+Option+P**：偏好設定（4 分頁：語音服務/快捷鍵/自訂 AI 模式/道場詞庫）；**Option+P**：選取文字潤飾（彈窗仍跟隨游標位置，跟語音 HUD 定位邏輯不同）

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
InputSa/AIServices/DojoCorrectionTable.swift← 精確替換 + 拼音同音層；24 詞條
InputSa/AIServices/DojoVoiceParser.swift    ← 【下午新檔】口頭修正共用解析器（Gemini JSON + 防禦解碼）
InputSa/UI/CardListView.swift               ← 【v3 重寫】白卡內 flat rows、動態高、單色徽章（BadgePill 舊簽名保留給 HUD）
InputSa/Preferences/EditorSheets.swift      ← 【下午新檔】DojoEntrySheet/PromptEntrySheet 視窗 sheet 編輯器（v3 未動，吃新單色 palette）
InputSa/UI/VoiceHUDController.swift         ← 【大改】液態玻璃 HUD，五尊統一漂浮動畫（拿掉粒子特效）
                                              + 即時聲波 + 動態漸層外框；floatingOrigin 拆成兩個函式
InputSa/UI/WaveformView.swift               ← 【新檔】像素風格滾動音量條
InputSa/UI/HUDCharacter.swift               ← 角色 enum、每尊耳機錨點座標
InputSa/UI/DesignTokens.swift               ← 【v3 重寫】Apple palette＋分組卡列工廠；accentGold/monoFont/BadgePill/inkButton/makeFieldGrid 舊 API 保留
InputSa/UI/PillSegmentedControl.swift       ← 只剩 EditorSheets 在用（自動吃新單色 ink）
InputSa/Preferences/PreferencesSidebar.swift ← 【v3 新檔】System Settings 側欄（sidebar 材質＋像素觀音＋nav 按鈕）
InputSa/Preferences/PreferencesWindowController.swift ← 【v3 重寫】780×560 側欄版面、四 pane 顯隱切換（showPane 單一真相）
InputSa/Preferences/Preferences…Tab.swift ×4 ← 【v3 重寫】分組白卡列版面；控制樹/action/資料流不變
build.sh / install.sh                        ← 裸編譯打包本機安裝（開發者用）
package-release.sh                           ← GitHub Release 打包（雲端優先、強制 ad-hoc 簽章）；讀 Info.plist 版號命名 zip
InputSa/Resources/Info.plist                 ← 【2026-07-13】版本號 2.1.0 (build 3)，改版號在這裡
README.md / .gitignore                       ← 面向 GitHub 公開 repo
```

## 目前發布狀態
- **GitHub repo**：https://github.com/hallowjason/input-sa（public，main branch，最新 commit `f2c570f`）
- **GitHub Release**：`v2.2.0`（2026-07-16 發布，zip 17MB 雲端優先版）https://github.com/hallowjason/input-sa/releases/tag/v2.2.0
- **本機**：`~/Applications/Input-sa.app` 已裝機是含本地模型版（`install.sh` 跑法，跟 Release zip 不同）；`build/` 目錄已重編確認恢復含模型狀態；polishProvider 現在跟著使用者上次在偏好設定的選擇（發版前這個 key 曾被截圖 harness 污染過一次，已用 `defaults delete com.inputsa.inputmethod com.inputsa.polishProvider` 清除歸零）
- **這台機器沒有全域 git 身分**（`~/.gitconfig` 不存在）：本次 commit 前曾跳 `Author identity unknown`，用 `git config --local` 比照本 repo 既有 commit 作者（`維宸 <gooo@weichendeMacBook-Pro.local>`）補上，已寫入全域 `~/.claude/reference/lessons.md`——下次任何全新 repo 第一次 commit 都可能重踩，直接查歷史作者複用即可
- 下次改完程式碼要發新 Release：改版號（`InputSa/Resources/Info.plist` 的 `CFBundleShortVersionString`/`CFBundleVersion`）→ `./package-release.sh` → commit 版號 → push → `gh release create vX.Y.Z ...`

## 待辦 / 未決事項
- **【最優先】使用者親測 Apple 視覺改版 v3**：側欄手感、四分頁內容、深淺色、EditorSheets（未改版，只換色票——若使用者嫌不搭要另案調整）、真 app 的 API Key 欄位顯示；連同道場共編一起驗完就 commit＋發版（Info.plist 建議跳 2.3.0）
- **【次優先，延續中】使用者持續使用回饋**：①Apple 本地潤飾長期使用感受（新詞彙表外的同音錯字仍需右 Shift 口頭修正累積，非模型自動學會）②右 Shift 口頭修正真實錄音流程的長期使用感受（上次只 E2E 測過 Gemini 解析層）③右 Shift 打大寫時 HUD 閃現的取捨若嫌煩，備案是延遲 300ms 才顯示 HUD
- Ollama+Qwen／llama.cpp/MLX 本地潤飾路線目前不打算做（Apple 本地已達成離線需求，額外裝 Ollama 不適合發給朋友）——若未來要重啟評估，查當下最新版本，不要用這份記錄裡的型號當現況
- [ ] P1（舊）：refreshShortcutCache migration 根治 modifier-only 殘留 shortcut bug（歷史遺留）
- [ ] P2（舊）：翻譯模式也注入道場詞彙表（現在只有潤飾有）
- [ ] P2（舊）：用完還原剪貼簿；靜音 VAD
- [ ] `assets_dl/` 暫存需使用者手動清（Claude rm 被權限擋）

## 踩雷點（動手前必看，本輪新增在最上面）
- **vertical NSStackView 的 intrinsic 寬 = 最寬 arranged view 的 fitting 寬**，NSScrollView 回報 0——視窗會整個被縮到 masthead 的 fitting 寬。解法：contentView 鎖明確寬度＋每個 arranged view `widthAnchor = mainStack.widthAnchor`。舊版看似滿寬只是內容 fitting 恰好 = 520 的巧合
- **直接 addSubview 進自訂 view 的 NSTextField 必須手動關 `translatesAutoresizingMaskIntoConstraints`**（stack 內的不用）——漏一個（DrawerCardView 的 valueLabel）整個 header 的約束系統會被 autoresizing 假約束打爆，症狀是所有兄弟元件擠成一團
- **批次全形化 CJK 標點的腳本**：判斷條件用「前後皆 CJK」比「任一側 CJK」安全（後者會誤傷 `NSView(),` 這類程式碼逗號——半形 `)` 誤入 CJK 集合過一次）;replacement 字元一定要用 `，` 或明確變數,heredoc 裡肉眼打的全形字可能其實是半形（發生過一次 no-op）
- **sed `/pattern/d` 會刪整行**——多檔名擠同一行的 build 腳本會被連坐刪掉其他檔（rebuild.sh 曾因此丟了三個 SOURCES）
- **NSTextField 設了 attributed string 後，欄位自己的 lineBreakMode 會被蓋掉**——截尾要 bake 進 attributed string 的 NSParagraphStyle，否則固定高度卡片裡文字折成兩行
- **NSScrollView 裡放垂直卡片堆疊**：documentView 非 flipped 時內容錨定在底部，要包一層 `isFlipped=true` 的容器；documentView 寬度要 pin 到 clipView 寬度才不會橫向滾動
- **CALayer 底色不會跟隨深淺色切換**——在 `viewDidChangeEffectiveAppearance` 用 `effectiveAppearance.performAsCurrentDrawingAppearance` 重新解析 NSColor 再設 cgColor（CardRowView 的做法）
- **標頭列多顆控制項要算總寬**：456pt 的 row 塞 switch+長標籤+兩顆 pill 會把最左元件擠出視窗（label 縮短為「道場模式」解掉）
- **離線截圖 harness 兩個新雷**：①`cacheDisplay` 不含視窗背景，深色模式會截出白底假象（白字看似消失）——contentView 設 layer 背景 windowBackgroundColor；②不指定 appearance 時跟系統走，「light」截圖可能默默變深色——兩種都要顯式指定
- **`.custom` TranscriptionMode 曾是裸拼接**（prompt+transcript），任何新 mode 都要帶 <transcript> 隔離規則，別再開洞
- **Gemini 結構化解析 prompt 一定要 few-shot + 真實 API 迭代**：純規則描述版在「轉錄本身聽錯目標詞」「指認詞 vs 目標字」兩類案例上會錯，範例教會才穩
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
- **`CommandLineTools` 的 SDK 沒有 FoundationModels 巨集外掛**：`@Generable`/`@Guide` 用 `xcrun --show-sdk-path`（不帶 `--sdk macosx`）取到的 SDK 編譯會報 `plugin for module 'FoundationModelsMacros' not found`——`build.sh` 已改用 `xcrun --sdk macosx --show-sdk-path` 優先取 Xcode SDK，任何新 harness/scratchpad 測試也要用這個取法
- **FoundationModels 自由文字模式（`respond(to:)` 不帶 `generating:`）會偶爾把整份 prompt 回吐進輸出**——3B 模型的已知不穩定，實測發生率不算低。根治法是用 guided generation（`@Generable` 表單約束解碼），逼模型只能填結構化欄位；`ApplePolishService.generateClean` 另外疊了碎片指紋比對＋重試＋`maximumResponseTokens` 封頂三層保險，任何新增的本地模型呼叫都建議比照
- **`LanguageModelSession()` 不要重用、不要帶 `instructions:`**：重用會累積 context 撞 4096 token 上限；`instructions:`／`prompt` 分欄會讓防注入指令失效（spike 實測「請幫我翻譯成英文」被真的執行）——整包 prompt 丟 `respond(to:)`／`session.respond(to:generating:)` 是唯一穩定格式

## 下次繼續
```bash
cd /Users/gooo/Desktop/.claude/projects/input-sa
# 對 Claude 說：「讀 CONTEXT.md，繼續 input-sa」
# 現況：三大改動皆完成、已裝機、全部未 commit——①道場共編詞庫②偏好設定抽屜結構③偏好設定視覺大改版 v2（retro ledger 設計系統）
#       ~/Applications/Input-sa.app 已是最新（含本地模型）；build/ 已重編乾淨
# 第一件事：問使用者親測結果（抽屜手感／深淺色／四抽屜內容／API Key 欄顯示）。滿意 → 一次 commit 這三包 + 發新 Release
#          發版流程：改 Info.plist 版號（現 2.1.0 build 3，建議跳 2.3.0）→ ./package-release.sh → commit → push → gh release create
#          commit 前無全域 git 身分，用 git config --local 比照歷史作者「維宸 <gooo@weichendeMacBook-Pro.local>」
# 未決：使用者持續使用回饋（見上方「待辦」）
# 環境：provider=sherpa（STT，本地）、polishProvider=依使用者上次選擇、dojoMode=true；GEMINI_API_KEY 在 ~/.claude/.env（不是 ~/.env）
# 驗證離線 UI 用「離線截圖驗收法」，見全域記憶 reference_appkit_ui_testing.md
#   本次 harness 腳本已丟垃圾桶，要重截需重建（把複製的 .app bundle + main.swift 一起 swiftc，見該記憶檔）
```
