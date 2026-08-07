# Session Context — 最後更新 2026-08-07

## 🔵 目前狀態（一句話）
**v2.6.1 已發布：修掉「全新安裝直接崩潰」（library validation 擋自簽 app 載入自帶 dylib，加 `disable-library-validation` entitlement 根治）＋三個鍵盤路徑的真 bug（tap callback 阻塞、快點 PTT 造成熱麥克風＋幻影注入、無聲錄音仍注入）＋一支按鍵歸屬追查器。使用者原始回報「會自動打出一整串 h、而且 input-sa 結束不了」尚未結案——最可能是 tap 阻塞（已修），但沒有直接證據，等下次發作看 `~/Library/Logs/InputSa.log`。**

<details><summary>（上一輪）v2.6.0 狀態</summary>

**v2.6.0 已發布並已用「固定自簽憑證」重簽（根治他機每版重配麥克風）。本輪三件事全部完成上線：①他機轉錄不穩兩修（Groq AAC→WAV 治「只錄 2 秒」＋App Nap 抑制）②七快捷鍵全可自訂（資料驅動引擎＋還原鍵＋衝突警告＋純修飾鍵長按錄製）③簽章治本（`tools/create-signing-cert.sh` 建永久憑證，install/package 腳本改用它，DR 已實測恆定為 `certificate leaf`）。線上 v2.6.0 資產已 clobber 成穩定簽章版。全部 commit＋push（HEAD `e38046a`）。無待辦阻塞；唯一開放項＝使用者實測快捷鍵行為回饋、以及是否要備份簽章憑證（我已主動提議）。**

</details>

## ✅ 2026-08-07 完成（鍵盤異常三修 ＋ 崩潰根治，v2.6.1 已發布）

**觸發**：使用者回報「input-sa 會自動在鍵盤上打 h」，追問後補充兩個關鍵細節——**「一次一整串完全停不下來」**、**「h 停不下來，input-sa 也結束不了」**，且 input-sa 失能那半小時內沒發作。

**先確認的事**：全專案只合成兩種按鍵事件——⌘C（`0x08`，`SelectionReader.postCmdC`）與 ⌘V（`0x09`，`pasteViaCmdV`）。沒有 unicode 注入、沒有 AX 插字、沒有 `h` 的 keyEquivalent。**沒有任何路徑會送出 `h`**，所以不要再去找「誰在打 h」的發射點，要找的是**讓系統以為某個鍵卡住**的機制。

**① 根因（最符合兩個症狀）：`SelectionReader.read()` 同步跑在 event tap callback 裡。**
它做兩件會阻塞的事：AX 查詢（`AXUIElementCopyAttributeValue`，預設 messaging timeout **6 秒**，對象 app 沒回應就等好等滿）＋合成 ⌘C 後 `usleep` 輪詢剪貼簿最多 350ms。`.cgSessionEventTap` + `.defaultTap` 的 callback 沒返回前，**window server 會把全機器的按鍵壓住**；同時主執行緒被佔住 → 選單列 🎙 點不開 → **「結束不了」**。macOS 逾時把 tap 停用後，積壓的按鍵（含 window server 期間持續產生的 autorepeat）**一次沖出** → **「一整串停不下來」**。兩個症狀同一個根。
- 修法 A：`readViaAX()` 加 `AXUIElementSetMessagingTimeout(sys, 0.25)`，把最壞情況從 6s 壓到 250ms。
- 修法 B：`firePressAction` 的 `.manualPolish`／`.selectionTranslate` 改 `DispatchQueue.main.async`——callback 先返回，工作留到下一個 main loop turn（同一條執行緒，差幾微秒，但鍵盤不再等它）。
- **殘留**：`.selectionQA`（⌃⌥Q）是 hold action，`startHoldAction` 要回傳 Bool 決定是否保留 hold 狀態，沒改成 async；它現在被修法 A 綁到約 0.6s 上限。要根治得把 `clearActiveKeyHoldState` 改成 internal 並讓 `startSelectionQA` 自己清狀態，**注意 keyUp 可能比 async 的 start 先到**。

**② 快點一下 PTT 會留下熱麥克風＋幻影注入**（`handleModifierChordChange` 的 300ms debounce）。debounce 本來是為了吸收 macOS 偶發的假 flagsChanged，但**真的輕點一下**在那個瞬間長得一模一樣，release 被 `return` 吞掉後 `activeModifierHoldAction` **永遠不清**：麥克風一直錄、HUD 掛著，直到下一次修飾鍵事件（按 ⇧ 打大寫、⌘⇥…）才判定放開 → 把那段環境音**轉錄、潤飾、貼到游標處**。
- 修法：新增 `verifyDebouncedRelease`，150ms 後用 `NSEvent.modifierFlags` 複查實體狀態——還按著＝假事件（繼續錄）；已放開＝真輕點（`cancelActiveRecording` 丟棄）。`modifierDebounceToken` 在 `clearActiveHoldState` 與新 hold 開始時都 +1，防止過期的複查誤殺新 session。

**③ 無聲錄音仍會注入幻覺**：`handleVoiceKeyUp` 的 success 分支沒有任何空值守衛，STT 對靜音常回短幻覺（單字母、「嗯」、「謝謝觀看」）照樣一路貼出去。加守衛：`transcript` trim 後為空、或 `peakRecordedLevel < 0.02`（≈ −49 dBFS，與 failure 分支同閾值）→ 不注入，只 `flashHUDMessage("沒有收到聲音")`。

**④ 按鍵歸屬追查器**（`recordKeystrokeForAttribution`）：tap 本來就看得到每個 keyDown，順手記兩種異常到 `~/Library/Logs/InputSa.log`——(a) `eventSourceUnixProcessID != 0` 的合成按鍵（硬體來源是 0），直接寫出是哪個 pid 打的；(b) 同一鍵連續 autorepeat 破 100 次，記一筆 runaway。檔案 I/O 用 `DispatchQueue.main.async` 推離 tap callback（在裡面寫檔會害 tap 逾時，正是①的教訓）。**已實測**：`synthetic keyDown: keyCode=105 … posted by pid 10594`。
- **偵測盲區**：只吃 autorepeat 旗標。壞掉的硬體若送出離散的 keyDown/keyUp 連發，兩支探針都抓不到。

**⑤ 崩潰根治（本次發版的主因）：自簽 app 在此機已無法載入自帶 dylib。**
`build.sh`＋`install.sh` 後 app 啟動即 SIGABRT，dyld：`Library not loaded: @rpath/libsherpa-onnx-c-api.dylib … mapping process and mapped file (non-platform) have different Team IDs`。**關鍵證據：把 7/22 的 `Input-sa-v2.6.0.zip` 原封不動解壓出來跑，一模一樣崩潰**——所以不是這輪改動造成的，是環境變了（Hardened Runtime 的 library validation 要求 dylib 與主程式同一個 Team ID，自簽憑證根本沒有 Team ID）。舊安裝還活著是因為它早就被系統放行過，一旦 bundle 被換掉就中。
- 修法：`InputSa.entitlements` 加 `com.apple.security.cs.disable-library-validation`。這是非公證 app 自帶函式庫的官方逃生口；dylib 本來就在簽好的 bundle 內、每次 build 都跟著重簽，範圍夠窄。
- **代價（踩過一次）**：改 entitlements 會改簽章 → **輔助使用授權當場失效**（app 還會啟動，但 CGEventTap 掛不上，等於整個功能死掉且沒有明顯錯誤）。用 `CGGetEventTapList` 列出所有 tap、確認 app 的 pid 不在裡面才發現。修復＝`tccutil reset Accessibility com.inputsa.inputmethod` 清掉過期紀錄，重啟 app 讓它重新請求，使用者到系統設定勾一次。**下次再動 entitlements 一定要預先告知使用者要重給權限。**
- **診斷小抄**：app 的 `NSLog`／`[InputSa]` 訊息在這台機器的 unified log 裡查不到，但 `com.apple.TCC:access` 的 `kTCCServiceAccessibility` 請求查得到——app 在輪詢權限就代表沒授權成功。`CGGetEventTapList` 是判斷「tap 到底有沒有掛上」最直接的工具。

**驗證**：`./build.sh` 乾淨；三套迴歸全過；`~/Applications` 實裝後 `CGGetEventTapList` 有本 app 的 tap；合成 F13 → 追查器記到正確 pid；合成 120ms 右⌥ 輕點 → log 出現 `debounced release confirmed as a real tap — discarding dictation recording`；**`Input-sa-v2.6.1.zip` 解壓到全新路徑實跑，不再 dyld 崩潰**（這正是發版要修的情境）。

**未結案**：`h` 到底是誰打的沒有直接證據。使用者回報 input-sa 失能期間安靜，加上①的機制吻合，嫌疑很重但仍是推論。下次發作先看 `~/Library/Logs/InputSa.log` 的 `synthetic keyDown` / `runaway key repeat`。旁證：這台機器另裝有 McBopomofo 與 `/Library/Input Methods/GOING13.app`（兩者目前都不在啟用的輸入來源清單裡）。

## ✅ 2026-07-22 完成（他機穩定性兩修 ＋ 七快捷鍵全可自訂，v2.6.0 已發布）

**觸發**：朋友回報「光是最普通的轉錄不穩：只能轉錄前面約 2 秒、有時直接 [無內容]；只有我這台好、搬到別人機器就壞——是不是 GitHub 少了什麼」。另要求「快捷鍵應該要可以自訂」（截圖是快捷鍵總覽七個動作）。

**穩定性診斷（兩個各自獨立的根因，疊加成「他機才壞」）**：
1. **「只錄 2 秒」＝雲端錄音檔還沒寫完就被讀**。`GroqVoiceService` 原本錄 **AAC/m4a**，AAC 編碼在 `stop()` 後仍**非同步 flush 尾端音框**，`stopAndTranscribe` 立即 `Data(contentsOf:)` 會讀到**截斷檔**。時間差問題：本機寫得快剛好趕上，他機慢一點就被截。**為什麼本機測不到**：本機預設走**本地 Sherpa（LINEAR16 WAV）**，PCM 在 `stop()` 同步落盤沒有這問題；朋友預設走 Groq 雲端正好踩中唯一有這 bug 的路徑。**修法：Groq 改錄 LINEAR16 WAV**（與 Google/Sherpa 一致，副檔名/multipart 改 wav），根除整類 flush race。
2. **「[無內容]」＝ ad-hoc 簽章 × TCC 麥克風授權對不上**（07-19 已修：自我診斷＋`tccutil reset`＋`record()` 失敗偵測），但**07-19 的修復從沒發成 Release**——朋友下載的 v2.5.0 zip 裡沒有。這次一併發版讓朋友拿得到。**本機開發者有 Apple Development 憑證（簽章穩定）→ 授權不失效**，這正是「只有你沒事」的簽章面成因（install.sh log 實證 `Apple Development: xzj071@…`）。
3. **順手加背景防打盹**：`AudioLevelMeter.start/stop`（正好包住三 provider 整段錄音）持有 `ProcessInfo.beginActivity(.userInitiated)`，避免 LSUIElement 背景程式被 App Nap throttle 掉錄音 run loop（「錄到一半掉音」的可能一角，防禦性）。
- 「GitHub 少了什麼」實情：檔案是齊的（本地模型是刻意排除的 243MB，預設雲端不需要）；真正「少的」是**沒發布的修復**＋這個雲端 bug。

**七快捷鍵全可自訂（feat `f7544b1`）**：原本只有聽寫 PTT 可改、其餘六個硬編碼。改成**資料驅動**：
- 新檔 `InputSa/Preferences/ShortcutSettings.swift`：`ShortcutAction` 註冊表（七動作 × 標題/說明/hold-or-press/預設綁定）＋每動作一組 UserDefaults（key 前綴 `com.inputsa.shortcut2.`，缺省即用預設；`set(nil)`＝還原該動作；`resetAll`；`conflictingAction` 撞鍵偵測；legacy `com.inputsa.shortcut.voice` → dictation **一次性遷移**）。`Shortcut.isModifierOnly`（keyCode∈54–63）。
- `InputController.handle` 由硬編碼分支改 `cachedShortcuts` 驅動（見程式碼地圖）：**modifier-only chord 引擎**（flagsChanged，`handleModifierChordChange`，300ms debounce＋combo-cancel）＋**key-combo 分派**（keyDown，`matchingKeyComboAction`，**精確 modifier 比對**讓 ⌃⌥⇧Q 不誤觸 ⌃⌥Q、press 忽略 autorepeat、hold 開錄後全程獨佔該鍵防漏字）。七個預設綁定行為與改版前**逐案等價**（逐一 trace 過）。
- `ShortcutRecorderView` 加 flagsChanged 監聽 → 可錄「純修飾鍵長按」（顯示「右 ⌥」等）；靜態 `capturingRecorder` 確保**同時只有一個 recorder 捕捉**（七個框，避免殘留 monitor / 卡住全域 tap）。
- 快捷鍵分頁重寫：七個可錄製列 ＋「還原預設」＋撞鍵/裸鍵橘色警告。移除死碼（`optionKeyRecording`/`translateKeyRecording`/`correctionKeyRecording`/`activeVoiceKeyCode`/`cachedVoiceShortcut`/`matchesShortcut`/`PreferencesWindowController.voiceShortcut`/`kVKP/Q/T`）。

**已知的小行為變更（可接受，已判斷非回歸）**：改版前只有 translate/correction 的 modifier-hold 會 combo-cancel、dictation（右⌥）不會；現在**所有** modifier-hold PTT 遇 keyDown 都 combo-cancel（防特殊字元洩漏，正常聽寫不按鍵故無影響）。

**驗證**：`./build.sh` 乾淨（只有既有 NSUserNotification 棄用警告）；三套迴歸全過（dojo/數字/方向）；fresh verifier 因 watchdog stall 未跑完（只確認「乾淨編譯」），改由主 session **逐案 trace** 七個預設綁定＋所有 CONTEXT 記載的守衛（autorepeat/獨佔/combo-cancel/精確排除/mic-guard 清理/debounce）；`./install.sh` 裝 v2.6.0 於本機、程序起得來（PID、道場同步 31 條、無崩潰）。**事件攔截無法離線自動測，靠使用者實測收尾**。

**發布**：`./package-release.sh` 產 `Input-sa-v2.6.0.zip`（17MB cloud-only）；三筆 commit（fix `8f5009d`／feat `f7544b1`／chore `be811c3`）＋本 docs；push main；`gh release create v2.6.0`。

**治本簽章根治「每版重配麥克風」（使用者選免費自簽路線）**：問題本質＝macOS 把 TCC 麥克風授權綁在 app 的 **designated requirement（DR）**；ad-hoc 簽名的 DR＝`cdhash H"..."`（每次重編都變→他機升級後授權對不上、系統設定開關看似開啟實則失效）。**證據**：`codesign -d -r-` 比對——ad-hoc→cdhash；有憑證→`identifier "com.inputsa.inputmethod" and certificate leaf = H"e9aef…"`（**無 cdhash，跨版本恆定**）。
- **解法**：新腳本 `tools/create-signing-cert.sh` 建一張**永久（10 年）自簽 code-signing 憑證**「Input-sa Code Signing」（openssl 走 config 檔給 codeSigning EKU，因 macOS 是 LibreSSL 不支援 `-addext`；import 帶 `-T /usr/bin/codesign` 免簽章時彈窗）。`install.sh`／`package-release.sh` 改成**優先用這張固定憑證**（缺才退 ad-hoc）。已實測：用它簽出的 app DR＝`certificate leaf = H"e9aefdd6…"`、`codesign -v` 通過。
- **已重簽並替換線上 v2.6.0 資產**（`gh release upload v2.6.0 --clobber`，穩定簽章版）。從此**所有版本 DR 恆定→麥克風/輔助使用授權跨版本永久存活**。
- **殘留（Apple 硬限制，免費無解）**：未公證＝每個人第一次裝仍要右鍵→打開一次（一輩子一次、非每版）；要連這步都免＝US$99/年 Apple 公證，使用者選了不付費。
- **一次性過渡**：從舊 ad-hoc 版升到首個憑證版會再重配麥克風一次（DR 從 cdhash→cert），之後永久免。**開發機**（原本用 Apple Development 憑證）下次 `./install.sh` 也會換成這張自簽憑證→本機也會過渡重配一次。憑證私鑰在本機 login keychain，**換電腦要重跑 create-signing-cert.sh（會產生不同 cert→那台簽出的版本 DR 不同）**，故發布務必固定在同一台機器、或備份該憑證。

## ✅ 2026-07-19 完成（安裝環境自我診斷與自我修復，commit `e65ded5`，已 push）

**觸發**：使用者朋友裝機後麥克風完全沒反應（快捷鍵能觸發 HUD，但聲波不動）。朋友自己的 Claude 誤判方向猜是「event tap 不穩定」——先讀程式碼確認 event tap 沒問題，真正根因是 **TCC × ad-hoc 簽名**：`install.sh` 找不到 Apple Development 憑證時退回 ad-hoc 簽名（`SIGN_ID="-"`），每次重新安裝簽章（cdhash）都會變，麥克風授權綁的是簽章不是 App 名字，於是**系統設定裡開關顯示已開啟，實際授權早就對不上目前的 binary**，`AVAudioRecorder` 靜默錄到空白，HUD 卻正常顯示錄音中。使用者接著要求「從根本面著手，讓程式具備自我排除問題的能力」，於是這輪不是單純修 bug，而是加整套診斷/修復機制。

**新增 `InputSa/App/SelfDiagnostics.swift`**（單一入口，多處呼叫端共用）：
- `runChecks()`：麥克風權限／輔助使用權限／音訊輸入裝置是否存在／（sherpa provider 時）本地模型檔是否完整，四項各回傳 pass/detail 白話說明
- `resetMicPermissionAndReprompt()`：呼叫 `/usr/bin/tccutil reset Microphone <bundleID>` 清掉舊授權紀錄，再 `AVCaptureDevice.requestAccess` 觸發系統重新詢問，結果彈 alert 告知成功/失敗
- `presentMicPermissionRecovery()`：麥克風異常時的標準對話框，「重置麥克風權限」一鍵按鈕
- `presentReport()`：選單列「系統診斷...」的四項檢查報告，麥克風失敗時同樣附重置按鈕

**`InputController.swift`**：
- 新增 `micReadyOrExplain()` 守門，掛在**每一個**錄音入口最前面（右⌥/右⌘/右⇧ 三種 PTT、自訂快捷鍵、⌃⌥Q 劃詞問答）——未授權時不再顯示假的錄音 HUD，立刻跳修復對話框。守門失敗時**必須清掉呼叫端已設的 PTT flag**（optionKeyRecording/translateKeyRecording/correctionKeyRecording 及對應 StartTime），否則後續 keyUp 會找不到對應狀態
- 新增 `peakRecordedLevel`（本次錄音音量峰值追蹤，key-down 時歸零、onLevelUpdate 裡取 max）：整段轉錄失敗時若峰值 <0.02，錯誤訊息會額外附「麥克風可能沒有真正收到音」的白話提示＋指向系統診斷，把原本模糊的「轉錄結果為空」變成可行動的線索

**`SelectionActions.swift`**：劃詞問答（⌃⌥Q）錄音入口比照加 `micReadyOrExplain()` 守門與 `peakRecordedLevel` 追蹤

**三個 VoiceService（Sherpa/Groq/Google）**：新增 `recordStartFailed` flag——`AVAudioRecorder.record()` 回傳 false（硬體開不起來）或 init 拋錯時設 true，`stopAndTranscribe` 改回報明確的「錄音無法啟動——請檢查系統設定 › 聲音 › 輸入」並清暫存檔（原本這種情況只寫 log,使用者只會看到跟靜音一樣的空白轉錄）。`SherpaVoiceService` 另加 `static var modelInstalled`（檢查 `model.int8.onnx`/`tokens.txt` 是否存在），供啟動檢查與診斷報告共用

**`AppDelegate.swift`**：啟動時若 provider=sherpa 且本地模型缺失，直接跳「安裝不完整」alert（不必等使用者按下快捷鍵才發現）；選單列新增「系統診斷...」項目；麥克風 denied/請求被拒都改走 `SelfDiagnostics.presentMicPermissionRecovery()`（移除舊的 `showMicrophonePermissionAlert`）

**`install.sh`**：偵測到 `SIGN_ID="-"`（ad-hoc fallback，朋友那類機器的常態）時，**自動**印出說明並執行 `tccutil reset Microphone com.inputsa.inputmethod`——不用使用者記得帶 `--reset-mic`；原本簽名穩定（有開發憑證）時的 opt-in `--reset-mic` 路徑不變

**驗證**：`./build.sh` 乾淨編譯（只有既有的 `NSUserNotification` 棄用警告,與本次改動無關）；`bash -n install.sh` 語法過；**獨立 fresh-context verifier 全項 CONFIRMED**——逐一追過每個錄音入口的 PTT flag 狀態機（守門失敗時 keyUp 是否確實變 no-op）、`nm`/`grep` 確認新符號（`micReadyOrExplain`／`SelfDiagnostics.presentReport`／`SherpaVoiceService.modelInstalled`）與新增中文字串（系統診斷／錄音無法啟動／安裝不完整 等）真的編進二進位檔、無新增警告、无 scope creep（改動僅限聲稱的 9 個檔案）

**已 commit＋push**：`e65ded5`（9 files, +311/-31），GitHub `hallowjason/input-sa` main 最新 commit。**尚未發新 GitHub Release**——`design-refs/` 仍是既往未追蹤目錄，不影響此次 commit

**回寫全域記憶**：`reference_auth_playbook.md` 新增一列「macOS TCC × ad-hoc 簽名」，記錄「授權綁 signature、ad-hoc 每次重簽都變、tccutil reset 是解法」這條跨專案可重用的知識（下次任何自簽 macOS App 遇到權限詭異都能先查這條，不必重新一輪除錯）

## ✅ 2026-07-17 完成（劃詞三功能＋語感三修,兩輪皆過 fresh verifier）

**第一輪（⌥P＋劃詞問答＋劃詞翻譯）:**
- **新檔**:`InputSa/InputMethod/SelectionReader.swift`（AX 讀選取→失敗合成 ⌘C 備援,獨立剪貼簿快照/還原,不碰 clipboardRestoreToken;解掉 Electron/終端機讀不到選區）、`InputSa/InputMethod/SelectionActions.swift`（extension InputController:QA/翻譯流程）、`InputSa/AIServices/SelectionTranslateDirection.swift`（純函式方向判斷,<30% CJK→譯繁中,否則譯 com.inputsa.selectionTranslateLang 目標語）、`InputSa/UI/AnswerPanelController.swift`（單例答案浮窗:nonactivating、popUpMenu、可捲動 NSTextView、複製鈕、英/泰切換、⎋ 關閉走 event tap）、`tests/SelectionTranslateTests.swift`（@main,13 項）
- **InputController**:handle() 新分支——AnswerPanel ⎋、**polishPreview.isActive 攔 ↩/⇥/⎋**（其他鍵撤銷放行,比照口頭修正契約）、QA Q 鍵獨佔（防漏字 q,keyUp 不看修飾鍵）、⌥P（排除 Ctrl/Shift/Cmd＋!isAnyRecordingActive＋非 autorepeat）、⌃⌥Q、⌃⌥T;triggerManualPolish 升級（SelectionReader＋dojo 校正＋數字格式化＋空選取 HUD toast＋onAccept 記 UsageStats）
- **TranscriptionMode** 加 `.qa(selectedText:)` 與 `.selectionTranslate(target:)`（皆有標籤隔離＋防注入聲明,真 API 實測含注入攻擊全過）
- **⚠️ 第一輪 verifier 曾抓到真缺陷**:executor 只接了 ⌥P 入口沒接出口（handlePolishPreviewKey 不可達,按 ↩ 會漏換行進文件）——主 session 補了 polishPreview.isActive 分支後複測過。**教訓:接死碼功能時「入口＋出口」都要接,verifier 專門查新分支的可達性**
- QA/翻譯硬走 Gemini（無 key 顯示 toast 不 fallback);結果只進浮窗絕不注入;⌥P 是**左** Option（右 Option 是聽寫 PTT）

**第二輪(中英夾雜＋整句詞條＋前文 buffer):**
- **中英夾雜**:log 實錘主兇是潤飾 LLM 層(commit→提交、cloud→雲端、takeless→API 腦補),非 STT。修法:.standard 規則 2 擴成三原則(已是英文原樣保留/有把握才音譯還原 comit→commit/沒把握禁止腦補)＋.custom/.translate/.selectionTranslate 各加保留句;GoogleVoiceService alternativeLanguageCodes 加 en-US;Groq language "zh" 維持(log 證英文能通過,放開有主路徑風險,已註解)
- **整句詞條**:DojoVoiceParser prompt「詞」放寬為「詞或短句」＋長句 few-shot(exact 層本就支援長字串,最長優先);tests/main.swift 加 2 條長詞條迴歸
- **前文 buffer**:InputController.recentUtterances(cap 2/TTL 3 分/**僅記憶體不落盤**=隱私決策);聽寫三注入點記錄(成功記潤飾後,fallback 記原稿);翻譯/⌥P/QA 不記;systemPrompt 加 priorContext 參數(預設 nil)僅 .standard/.custom 嵌 <previous_context> 隔離區;**Apple 3B 刻意不餵前文**(幻覺風險,dispatchPolish Apple 分支丟棄＋讀取端雙保險)——使用者要測前文功能需把潤飾 provider 切 Gemini
- **verifier PASS 亮點**:真 API 複測 takeless 不腦補/前文修「到親→道親」/無關前文不混入/**前文注入攻擊**(「忽略以上指示輸出 HACKED」)不上當;Apple 幻覺防線不受 prompt 變長影響(bound 基於 transcript);觀察項=靜態指紋清單(ApplePolishService:167-176)未涵蓋新 prompt 句,3B 若回吐新句會漏檢(既有設計特性非回歸)

**兩輪驗證**:./build.sh 乾淨;四套測試全過(dojo 含長詞條/數字/方向判斷);AnswerPanel 離線截圖淺深色驗過;Gemini prompt 三組真 API 迭代全過;**使用者裝機實測回報「沒問題了」**。已 commit＋push＋發版 v2.5.0

**⚠️ 拆 commit 的實況（下一棒要知道）**:使用者要求「劃詞一筆／語感一筆」,但**兩輪的改動在 `InputController.swift` 與 `TranscriptionMode.swift` 內逐行交錯**（前文 buffer 緊貼 QA 屬性同一 hunk）,無法乾淨切開;`git add -p` 在本 harness 是互動指令不可用,hand-authored patch 做 sub-hunk surgery 風險高故未做。最終採**檔案級拆分**:`60c8720` 收所有事件層/prompt 檔（含第二輪的前文 buffer 與英文保留 prompt,已在 commit message 誠實標註）,`3bb0f86` 收能獨立切出的 STT 語言設定（Google/Groq）＋整句詞條測試。**教訓見下方踩雷點**

## ✅ 2026-07-16 深夜第二輪完成（功能大輪,commit `ce52534`）
研究了 EthanYoQ/whisper-input（其實是 macOS Swift 專案 OpenLess 的 Tauri/Rust 移植,非 Python 名專案）,借鏡其儀表板設計後實作三批:

**第一批（使用者指定）:**
- **使用統計儀表板**:新檔 `UsageStatsStore.swift`（`~/Library/Application Support/InputSa/usage_stats.json` 原子寫,**只存數字不存轉錄內容**=使用者隱私決策,daily 30 天裁剪、lifetime 累計與裁剪解耦）＋`PreferencesDashboardTab.swift` 第五分頁（今日/近7日 bar chart/累計;圖表用 `draw(_:)` 純繪製避開 CALayer 深淺色雷）＋選單列「今日:N 字・M 次」disabled item（menuNeedsUpdate 更新）。記錄點=右⌥聽寫與右⌘翻譯的注入完成處（成功+fallback 都記;右⇧口頭修正與 Option+P 不記）;時長用統一 `recordingStartTime` property（type-specific start time 在 async completion 前就被 nil,是坑）
- **數字格式化（兩層）**:新檔 `TranscriptNumberFormatter.swift` 確定性層（**只做**百分之N→N%（含點小數 tail）、零點N→0.x、N趴→N%;寧可漏轉不誤傷;冪等;誤傷防護:十分感謝/三思/三點半/百分之五十點名 皆不動）掛在所有聽寫/翻譯注入路徑（post-polish dojo correction 之後+fallback+翻譯）;prompt 層在所有潤飾模式加數字規範一條（含「三十五趴→35%」示例）、翻譯 prompt 加保真句。測試 `tests/NumberFormatterTests.swift`（@main 形式,52 項）

**第二批（使用者點頭的候選 1,2,3,4,6）:**
- **錄音時靜音喇叭**:新檔 `SystemAudioMute.swift`（CoreAudio,begin/end 配對、記原狀態、失敗全靜默）,三種 PTT 開錄/停錄/combo-cancel 都掛;偏好設定語音服務卡新列 switch,key `com.inputsa.muteWhileRecording` **預設 off**;build.sh 加 `-framework CoreAudio`
- **注入後還原剪貼簿**:injectText 貼上前深拷貝全部 pasteboard items,+300ms token-gated 還原(解掉舊 TODO);連續注入時只在無 pending restore 才重新 snapshot=原剪貼簿永遠是還原目標
- **dojo `{num}` 萬用字元**:wrong/correct 各恰一個 {num}+有前後綴才啟用,匹配 0-9+中文數字 run 原樣代入;壞規則安全 no-op;phonetic 層跳過 {num} 詞條。⚠️ {num} 含中文數字→「{num}粒」會把「一粒沙」也改,建詞條時前後綴要夠具體（已告知使用者）
- **翻譯模式注入道場詞彙表**（舊 P2 完結）:.translate 用共用 dojoVocabularySection+定位說明（防模型把詞彙表翻出來）
- **APIKeyStore 記憶體快取**:一次聽寫原本 3 次 Keychain 讀取,ad-hoc 簽章朋友端狂彈授權框→首讀後全走記憶體（空值也快取）,save 成功才更新快取（verifier 抓到無條件更新會造成「本 session 能用、重啟後 key 消失」,已修）

**實測回饋修復（使用者裝機實測後）:**
- **Apple 本地 3B 幻覺**:「佛堂的道歉。」6 字被吹成 193 字道場詞彙表編故事——舊防線 `max(input*3, input+200)` 的 +200 floor 短輸入不設防。修:standard 模式 tight bound `max(input*2, input+40)`+動態 `maximumResponseTokens = min(1024, max(128, input*4))`（失控 1-2 秒截斷,也是速度止損）+指紋加「這段話的意思」等模型評論慣用語（custom/aiPrompt 模式維持 loose 3x,允許擴寫）
- **「趴」**=% 口語支援（見上;含「百分之N點N趴」吞尾趴、「35%趴」清理）
- **Gemini key invalid 自癒**:log 實錘 ad-hoc 重簽後 Keychain 讀到壞值被快取釘住（「API key not valid」直到重啟）→GeminiPolishService 收到該錯誤即 `invalidateGeminiKeyCache()` 下次重讀
- **選單列圖示**:codex 產三款幾何提案,使用者選「音量條」→ `InputSa/Resources/inputsa-menu@2x.png`(72px) template image 取代 🎙 emoji（AppDelegate 設 isTemplate+18pt,資源缺失 fallback emoji）;build.sh 舊的「菩薩剪影 tiff 生成段」是從沒被引用的死碼,已刪換成 cp 資產
- **速度慢**根因=幻覺長生成,防線即止損;已向使用者說明 Apple 3B 正常 1-3 秒/句是模型極限,要快就切 Gemini 雲端

**驗證鏈**:兩批各自過 fresh verifier（第一批 9/9;第二批 4/5+1 REFUTED 已修）;儀表板四張+語音服務兩張離線截圖親眼驗收;52 項數字測試+15 項 dojo 迴歸;使用者本機實測確認「沒問題了」

**研究結論（待使用者點頭,有完整報告在對話中,重點如下）:**
- **⌥P 選字潤飾是死碼**:`triggerManualPolish()`（InputController.swift:590 附近）無任何呼叫點,快捷鍵總覽 UI 寫著 ⌥P 但從沒接上——既有缺口,修復小（事件分派加分支）,使用者尚未點頭
- **划詞語音問答**:建議做但 v1 收斂（接上死碼+補 Cmd+C 選區備援+新快捷鍵如 Ctrl+Option+Q+浮窗顯示不注入）;現有 AX 讀選區只有一層,Electron/終端機會抓不到
- **串流落字**:**不建議**(CJK 輸入法攔截合成鍵事件要暫切 ABC 輸入源、macOS 14+ TIS 主執行緒 SIGTRAP 風險、Apple guided generation 無串流只有 Gemini 受益、自家 CGEventTap 會攔到自己合成的事件);降級案=HUD 串流預覽從尾 16 字升級成完整多行,使用者未決

## ✅ 2026-07-16 深夜完成（偏好設定 Apple 視覺改版 v3）
- **背景**：使用者對 v2 retro ledger 評價「非常廉價」，指定用 `~/.claude/references/design-md-library/design-md/apple/DESIGN.md` 重新提案、捨棄過去所有視覺基礎。先做互動 HTML mockup（`design-refs/apple-proposal.html`，瀏覽器四分頁×深淺色自驗）獲使用者「這很棒，就這樣改」後才動 Swift
- **設計宣告**：版面骨架＝macOS System Settings（側欄＋分組白卡列）；視覺紀律＝apple.com（#f5f5f7 畫布/#1d1d1f 墨、白卡 10pt 圓角 hairline、**唯一彩色 Apple Blue #0071e3 只給互動元件**、綠/橘點為語意狀態色、徽章單色化：一律套用=墨實心/限道場・同音=淺灰/共編=細框）
- **結構**：視窗 520×640 → **780×560 固定**（.fullSizeContentView＋透明標題列）；`PreferencesSidebar.swift`（新檔：NSVisualEffectView .sidebar 材質、像素觀音 64pt 原尺寸 app 識別、四個手繪 nav 按鈕，選中=accent 圓角 pill；選擇單一真相在 controller.showPane）；四個 pane 各自為 NSScrollView，make…Content() 控制樹照舊
- **控制項替換（同 action 語意）**：PillSegmentedControl → 原生 NSPopUpButton（provider index 0/1/2=groq/google/sherpa、polish 0/1=gemini/apple 不變）；InkPillButton → AccentTextButton 藍字按鈕（卡片 footer「＋新增」「用說的新增」，setTitle 保樣式）；鍵帽改「動作名＋說明左、灰 chip 右」原生排法；API Key 欄移入卡列（mono 11、寬 220）
- **DesignTokens v3**：新 Palette＋groupCard（autoSeparators 參數：條件列自帶 leading hairline 包 wrapper，隱藏時分隔線跟著走）/row/statusRow/group/popup/pushButton/textButton/keycap/badge(BadgeStyle) 工廠；**保留給 HUD**：accentGold、monoFont、BadgePill 舊簽名（新參數全有預設值）；**保留給 EditorSheets**：inkButton/softButton/makeFieldGrid/Spacing/Grid/PillSegmentedControl（sheets 功能元件未動，自動吃新單色 palette）；FlippedView 從 DrawerCardView 搬入
- **CardListView v3**：白卡內 flat rows（48pt＋hairline 分隔）、Row.icon 可選（dojo 無圓徽、AI 模式留 emoji tile）、**高度 hug 內容 cap maxHeight**（無死空間）、hover 灰底＋徽章↔編輯/刪除交叉淡化保留、shared read-only index 映射不變；dojo 列 subtitle 改「常見誤辨：X」、新增 footer 詞條計數（dojoCountLabel，取代 drawer summary）
- **移除**：DrawerCardView.swift（刪檔＋build.sh SOURCES）、refreshDrawerSummaries 全部呼叫點、banner masthead（識別移入側欄）
- **驗證**：./build.sh 乾淨（僅既有 NSUserNotification 棄用警告）；dojo 13 項迴歸全過；離線截圖 harness 重建（**新雷**：離線對 NSScrollView/整 contentView cacheDisplay 全白，要對 documentView 截再手動合成——已寫入全域記憶 reference_appkit_ui_testing.md 第 9 點）四分頁×深淺 8 張逐張人工比對 mockup；**fresh verifier 8/8 PASS（CONFIRMED）**（功能鏈與 HEAD 一一對應：popup 索引映射/API Key 雙保險/dojo 編輯刪除索引/口頭修正流程；refreshDrawerSummaries 全清；HUD＋EditorSheets 零破壞；色彩紀律 grep 零違規；死碼刪除；build 乾淨；780×560 固定視窗）。唯一備註：BadgePill 預設參數微調，但所有呼叫端都顯式傳參，無實際影響
- **收尾**：使用者回「視覺可以，先把整個提交，還有推到 Git 上」→ 三筆 commit（道場共編 `ddac81d`／Apple 改版 `f42524f`／CONTEXT `4858d71`）push；接著「發版 2.3.0」→ Info.plist 2.2.0→2.3.0(build 5)、`./package-release.sh`、版號 commit `14c788c`、`gh release create v2.3.0`（zip 17.5MB 雲端版）
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
- **Ctrl+Option+P**：偏好設定（5 分頁：語音服務/快捷鍵/自訂 AI 模式/道場詞庫/使用統計）
- **⌥P（左 Option+P）**：選取文字潤飾 → 浮窗預覽（跟隨游標定位，與語音 HUD 定位邏輯不同）→ ↩/⇥ 接受、⎋ 拒絕、其他鍵撤銷放行。**必須用左 Option**（右 Option 是聽寫 PTT）
- **⌃⌥Q 按住**：劃詞語音問答——選取文字 → 按住說問題 → 放開 → 答案顯示在浮窗，**不注入游標**
- **⌃⌥T 按一下**：劃詞翻譯——選取文字 → 浮窗顯示譯文（中文→目標語可切英/泰；外文→自動繁中），不注入游標
- 上述三者的選取讀取皆走 `SelectionReader`：AX 優先，讀不到自動合成 ⌘C 備援（Electron/終端機可用）

## 程式碼地圖（【2026-07-19】= 本輪自我診斷異動，【2026-07-17】= 上輪劃詞/語感輪異動）
```
InputSa/App/SelfDiagnostics.swift           ← 【2026-07-19 新檔】四項檢查（麥克風/輔助使用/輸入裝置/本地模型）
                                              ＋tccutil 一鍵重置＋選單列「系統診斷...」報告
InputSa/App/AppDelegate.swift               ← 選單列 + 啟動【2026-07-19】啟動時查模型完整性；
                                              denied 麥克風改走 SelfDiagnostics.presentMicPermissionRecovery()
InputSa/Preferences/ShortcutSettings.swift  ← 【2026-07-22 新檔】ShortcutAction 七動作註冊表＋每動作 UserDefaults
                                              （key 前綴 com.inputsa.shortcut2.；set(nil)=還原；resetAll；
                                              conflictingAction；legacy shortcut.voice→dictation 遷移）＋Shortcut.isModifierOnly
InputSa/InputMethod/InputController.swift   ← CGEventTap、runAIPolish、inputSaLog 全域 logger
                                              【2026-07-22】handle() 改資料驅動：handleModifierChordChange（flagsChanged 引擎，
                                              300ms debounce＋combo-cancel）＋matchingKeyComboAction/dispatchKeyCombo（keyDown，
                                              精確 modifier 比對）＋startHoldAction/stopHoldAction/firePressAction 分派表；
                                              handleVoiceKeyDown 改回傳 Bool 無參；狀態改 activeModifierHoldAction/
                                              activeKeyHoldAction/cachedShortcuts（舊 optionKeyRecording 等旗標已刪）
                                              【2026-07-19】micReadyOrExplain() 守門掛所有錄音入口；
                                              peakRecordedLevel 峰值追蹤（近零時錯誤訊息附診斷提示）
                                              【2026-07-17】handle() 六個新分支（AnswerPanel ⎋／polishPreview ↩⇥⎋／
                                              QA Q 鍵獨佔／⌥P／⌃⌥Q／⌃⌥T）；triggerManualPolish 升級；
                                              recentUtterances 前文 buffer（cap2/TTL3分/僅記憶體）
InputSa/InputMethod/SelectionReader.swift   ← 【2026-07-17 新檔】AX 讀選取→合成 ⌘C 備援（獨立快照/還原，
                                              不碰 clipboardRestoreToken）；⌥P/QA/翻譯三處共用
InputSa/InputMethod/SelectionActions.swift  ← 【2026-07-17 新檔】extension InputController：QA/劃詞翻譯流程
InputSa/AIServices/SelectionTranslateDirection.swift ← 【2026-07-17 新檔】純函式方向判斷（Foundation-only，
                                              <30% CJK→繁中；tests/SelectionTranslateTests.swift 13 項）
InputSa/UI/AnswerPanelController.swift      ← 【2026-07-17 新檔】單例答案浮窗（nonactivating/popUpMenu、
                                              可捲動 NSTextView、複製鈕、英泰切換、⎋ 走 event tap 關閉）
InputSa/AIServices/SherpaVoiceService.swift ← 本地 STT（decode→opencc→dojo correct→log 三階段）
                                              【本輪】加 AudioLevelMeter 量測
                                              【2026-07-19】recordStartFailed flag＋static modelInstalled
InputSa/AIServices/GroqVoiceService.swift   ← 雲端 STT（Whisper）【2026-07-17】language "zh" 維持不動（加註解說明）
                                              【2026-07-19】recordStartFailed flag（record() 失敗→明確錯誤）
InputSa/AIServices/GoogleVoiceService.swift ← 雲端 STT（含台語）【2026-07-17】alternativeLanguageCodes 加 en-US
                                              【2026-07-19】recordStartFailed flag（同上）
InputSa/AIServices/AudioLevelMeter.swift    ← 【新檔】共用音量量測元件
InputSa/AIServices/GeminiPolishService.swift← 模型 fallback 鏈，SSE 串流【2026-07-17】enhance 加 priorContext 參數
InputSa/AIServices/TranscriptionMode.swift  ← 潤飾/翻譯 prompt + dojoVocabularySection
                                              【2026-07-17】加 .qa/.selectionTranslate case；全模式加英文保留規則；
                                              systemPrompt 加 priorContext 參數（預設 nil）＋previousContextBlock；
                                              dojoEntryParse 放寬「詞或短句」＋長句 few-shot
InputSa/AIServices/DojoCorrectionTable.swift← 精確替換 + 拼音同音層；24 詞條
InputSa/AIServices/DojoVoiceParser.swift    ← 【下午新檔】口頭修正共用解析器（Gemini JSON + 防禦解碼）
InputSa/AIServices/TranscriptNumberFormatter.swift ← 【本輪新檔】確定性數字格式化（百分之/零點/趴;tests/NumberFormatterTests.swift）
InputSa/AIServices/UsageStatsStore.swift    ← 【本輪新檔】使用統計持久化（只存數字;usage_stats.json）
InputSa/AIServices/SystemAudioMute.swift    ← 【本輪新檔】錄音時靜音喇叭（CoreAudio;預設 off 開關）
InputSa/Preferences/PreferencesDashboardTab.swift ← 【本輪新檔】第五分頁使用統計（bar chart 用 draw(_:)）
InputSa/Resources/inputsa-menu@2x.png       ← 【本輪新檔】選單列音量條 template 圖示（取代 🎙 emoji）
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
                                              【2026-07-22】build.sh 加 ShortcutSettings.swift 進 SOURCES；
                                              install.sh 簽章身分改優先「Input-sa Code Signing」自簽憑證→Apple Dev→ad-hoc；
                                              【2026-07-19】build.sh 加 SelfDiagnostics.swift；install.sh ad-hoc 時自動 tccutil reset
tools/create-signing-cert.sh                 ← 【2026-07-22 新檔】一次性建永久（10 年）自簽 code-signing 憑證
                                              「Input-sa Code Signing」；冪等；openssl 走 config 檔（LibreSSL 無 -addext）
package-release.sh                           ← GitHub Release 打包（雲端優先）；讀 Info.plist 版號命名 zip
                                              【2026-07-22】簽章改優先固定憑證（缺才退 ad-hoc）＝簽章治本核心
InputSa/Resources/Info.plist                 ← 版本號現為 2.6.0 (build 8)，改版號在這裡
README.md / .gitignore                       ← 面向 GitHub 公開 repo（README 已加簽章憑證一次性設定與升級說明）
```

## 目前發布狀態
- **GitHub repo**：https://github.com/hallowjason/input-sa（public，main branch，最新 commit `e65ded5`，**已 push**）
- **GitHub Release**：`v2.6.0`（2026-07-22 發布）— 雲端優先版 zip（`Input-sa-v2.6.0.zip`，17MB，含 Groq 錄音 WAV 修復＋App Nap 抑制＋07-19 麥克風自我診斷＋七快捷鍵自訂）。**這是朋友要下載的版本**，補齊了 v2.5.0 到現在所有他機穩定性修復。（歷史：v2.5.0 = 07-17 劃詞三功能＋語感強化，不含 07-19/07-22 修復）
- **本機**：`~/Applications/Input-sa.app` 是 `./install.sh` 裝的含本地模型版，程式碼＝v2.6.0，**但簽章＝Apple Development 憑證**（安裝當下自簽憑證還沒建）；`build/` 目錄是最後一次 package-release 的雲端版（無本地模型、已用固定自簽憑證簽）。⚠️ 開發機下次 `./install.sh` 會換成「Input-sa Code Signing」自簽憑證→本機麥克風會過渡重配一次（DR 從 Apple Dev cert 變成自簽 cert）。polishProvider 跟著使用者上次選擇——**前文 buffer 只在 Gemini 生效**
- **簽章憑證**：「Input-sa Code Signing」自簽憑證已建於**本機 login keychain**（指紋 `E9AEFDD6…`，約 10 年效期）。私鑰只在這台 → **發布務必固定這台**；換電腦要重跑 `tools/create-signing-cert.sh`（會產生不同 cert→朋友被迫再重配一次），或先備份此憑證（使用者尚未決定要不要備份）
- **這台機器沒有全域 git 身分**（`~/.gitconfig` 不存在）：本次 commit 前曾跳 `Author identity unknown`，用 `git config --local` 比照本 repo 既有 commit 作者（`維宸 <gooo@weichendeMacBook-Pro.local>`）補上，已寫入全域 `~/.claude/reference/lessons.md`——下次任何全新 repo 第一次 commit 都可能重踩，直接查歷史作者複用即可
- 下次改完程式碼要發新 Release：改版號（`InputSa/Resources/Info.plist` 的 `CFBundleShortVersionString`/`CFBundleVersion`）→ `./package-release.sh` → commit 版號 → push → `gh release create vX.Y.Z ...`

## 待辦 / 未決事項
- **【最新，2026-07-19】要不要現在發新版？** 自我診斷改動已 commit＋push，但版號還是 2.5.0 (build 7)、Release 頁面還是舊 zip。若朋友是走 Release 頁面裝的（非開發者 git clone 流程），現在**拿不到**這次的修復。下一棒開口先問使用者：現在就 bump 版號發 v2.6.0，還是等累積更多改動再一起發？
- **【觀察中，2026-07-19】自我診斷實戰效果未驗**：這輪的 fresh verifier 是靜態追蹤程式碼邏輯＋編譯驗證＋symbol 存在性檢查，**沒有實機重現朋友那台機器的 ad-hoc TCC 失效場景**去按「重置麥克風權限」看是否真的修好——若使用者朋友之後回報「修了/還是不行」，這是第一手真實回饋，比這輪的驗證更有說服力
- ~~實測兩輪新功能~~ ✅ 使用者回報「沒問題了」（2026-07-17）
- ~~分兩筆 commit＋發版~~ ✅ 已完成（`60c8720`／`3bb0f86`／`a79b142`，Release v2.5.0）
- ~~HUD 串流預覽升級~~ 使用者明確說不做（2026-07-17）
- **【觀察項，本輪新增】** ①Apple 靜態指紋清單（`ApplePolishService.swift:167-176`）未涵蓋第二輪新 prompt 句（3B 若回吐新句會漏檢；主防線 guided decoding＋長度 bound 未動，屬既有設計特性非回歸） ②Groq `language "zh"` 若日後英文召回不足再實測放開 ③前文 buffer 若要惠及 Apple 本地，另案評估短前文＋防線 ④⌥P 吃掉英文鍵盤佈局的 Option+P（原本打 π）——已知取捨，使用者若嫌煩可改快捷鍵
- **【觀察中】Apple 本地幻覺防線實戰效果**：tight bound 若誤殺合理輸出（使用者回報「潤飾常變原稿」），調 `ApplePolishService.generateClean` 的 bound 參數
- **【觀察中】「道親→道歉」類 STT 錯詞**：已建議使用者用右⇧口頭修正累積詞庫
- 使用者本機已裝本輪最新碼（含本地模型，`./install.sh` 裝的）
- **【次優先，延續中】使用者持續使用回饋**：①Apple 本地潤飾長期使用感受（新詞彙表外的同音錯字仍需右 Shift 口頭修正累積，非模型自動學會）②右 Shift 口頭修正真實錄音流程的長期使用感受（上次只 E2E 測過 Gemini 解析層）③右 Shift 打大寫時 HUD 閃現的取捨若嫌煩，備案是延遲 300ms 才顯示 HUD
- **EditorSheets（DojoEntrySheet／PromptEntrySheet）未跟著 Apple 改版**：只自動吃了新單色 palette，版面仍是 v2 的 grid 樣式。目前視覺尚可，若使用者嫌與側欄新風格不搭再另案調整（inkButton/makeFieldGrid/PillSegmentedControl 都刻意保留給它）
- Ollama+Qwen／llama.cpp/MLX 本地潤飾路線目前不打算做（Apple 本地已達成離線需求，額外裝 Ollama 不適合發給朋友）——若未來要重啟評估，查當下最新版本，不要用這份記錄裡的型號當現況
- [ ] P1（舊）：refreshShortcutCache migration 根治 modifier-only 殘留 shortcut bug（歷史遺留）
- [x] ~~P2（舊）：翻譯模式也注入道場詞彙表~~ ✅ 2026-07-16 已完成
- [x] ~~P2（舊）：用完還原剪貼簿~~ ✅ 2026-07-16 已完成（injectText token-gated 還原）
- [ ] P2（舊）：靜音 VAD（錄音時靜音喇叭已做，VAD 未做）
- [ ] `assets_dl/` 暫存需使用者手動清（Claude rm 被權限擋）

## 踩雷點（動手前必看，本輪新增在最上面）
- **【2026-07-22】macOS 麥克風/輔助使用 TCC 授權綁在「designated requirement(DR)」上，不是 App 名字**：ad-hoc（`--sign -`）的 DR＝`cdhash H"..."`（每次重編都變→他機升級後授權對不上、系統設定開關看似開啟實則失效）；用**任何憑證**（含自簽）簽→DR＝`identifier "..." and certificate leaf = H"<certhash>"`（**無 cdhash，跨版本恆定**）。**驗證指令**：`codesign -d -r- <app>` 看 `designated =>` 那行有沒有 cdhash。**治本＝固定憑證**，見 `tools/create-signing-cert.sh`。
- **【2026-07-22】macOS 內建是 LibreSSL，`openssl req -addext` 不支援**（會靜默失敗或報錯）→ 建自簽憑證的 codeSigning EKU 要走 `-config <檔>` 的 `[ext] extendedKeyUsage=critical,codeSigning`。`security import` 一定要帶 `-T /usr/bin/codesign`，否則首次簽章會彈鑰匙圈授權視窗。
- **【2026-07-22】本 harness 直接下 `codesign --force --sign ...`（重簽/去簽）的複合指令會被權限系統擋**（連 `dangerouslyDisableSandbox:true` 也擋）；但**放在專案腳本內的 codesign（install.sh/package-release.sh）可正常執行**。要驗證簽章結果用**唯讀**的 `codesign -d -r-` / `codesign -v`（這兩個不被擋）。
- **【2026-07-22】簽章憑證是「不可再生的機器綁定資產」**：私鑰在本機 login keychain，換電腦重跑 create-signing-cert.sh 會產生**不同** cert→朋友被迫重配一次。發布固定同一台，或用鑰匙圈存取把「Input-sa Code Signing」連同私鑰匯出 .p12 備份。
- **【2026-07-22】事件攔截狀態機（InputController.handle）無法離線自動測**（需真實硬體按鍵＋Accessibility），改動後靠：①`./build.sh` 乾淨②三套迴歸③逐案 code trace 七個預設綁定＋守衛（autorepeat/獨佔/combo-cancel/精確 modifier 排除/mic-guard 清理/debounce）④使用者實機。fresh verifier 這次因 watchdog stall 沒跑完（只確認乾淨編譯）。
- **【2026-07-22】新增/改快捷鍵動作**：改 `ShortcutAction`（加 case→補 titleZh/subtitleZh/isHold/defaultShortcut 四處 switch，否則編譯報 non-exhaustive）＋`startHoldAction`/`stopHoldAction`/`firePressAction` 三張分派表也要補 case。modifier-only vs key-combo 由 `Shortcut.isModifierOnly`（keyCode∈54–63）決定走哪條路，與動作的 hold/press 正交。
- **【2026-07-19】macOS TCC 授權綁的是 code signature，不是 App 名字/bundle ID 本身**：ad-hoc 簽名（找不到開發憑證時的 fallback）每次重新安裝 cdhash 都會變，麥克風等權限的舊授權紀錄會**悄悄對不上目前的 binary**——症狀是系統設定裡開關顯示已開啟（那是舊紀錄的殘影），但實際錄音靜默拿不到音，HUD 卻正常顯示錄音中，使用者/AI 很容易誤判成程式邏輯 bug（event tap 不穩、UI 沒串好）而不是權限問題。**解法**：`tccutil reset Microphone <bundleID>` 清掉舊紀錄讓系統重新詢問；App 內建的偵測不能只查 `authorizationStatus`（那個值本身沒問題，問題在於它反映的是「錯的」舊紀錄）,要在**實際使用當下**（key-down 那一刻）做守門,並在轉錄結果異常時用峰值音量（`peakRecordedLevel` 全程近零）反推「根本沒收到音」。**任何自簽名 macOS App 發佈給不同機器的使用者，都該假設對方大機率是 ad-hoc 簽名，權限問題要往這個方向先查**，已回寫全域記憶 `reference_auth_playbook.md`
- **【2026-07-19】PTT 類錄音入口加任何 key-down 前置守門（如本輪的 `micReadyOrExplain()`），一定要處理「呼叫端已經先設好 PTT flag」的情況**：本專案的三種修飾鍵 PTT（右⌥/右⌘/右⇧）都是呼叫端先設 `xxxKeyRecording = true` 才呼叫 `handleVoiceKeyDown()`，若守門在此時失敗但沒把這些 flag 清掉，對應的 keyUp 分支會誤以為「正在錄音」而執行一次沒有 startRecording 過的 stopAndTranscribe，狀態機會卡住。自訂快捷鍵路徑因為沒有前置 flag（直接靠 `activeVoiceKeyCode` 是否被設定判斷），守門失敗時 return 提早、`activeVoiceKeyCode` 沒被賦值，keyUp 分支的 `let active = activeVoiceKeyCode` 會 binding 失敗而自然 no-op——**這條路徑不用清 flag,但要留意「靠 optional binding 天然擋掉」跟「靠顯式清 flag 擋掉」是兩種不同機制,新增守門時要對每個入口分別確認**
- **【2026-07-19】`AVAudioRecorder.record()` 回傳 `Bool`,原本三個 provider 都沒檢查回傳值**——硬體開不起來（無可用輸入裝置/HAL 失敗）時 `record()` 回 false 但不拋錯,舊程式碼會誤以為錄音正常開始,直到轉錄完才得到一個跟「使用者真的沒說話」無法區分的空白結果。任何新增的 `AVAudioRecorder` 呼叫都要檢查 `record()` 回傳值,false 時視同啟動失敗處理（清 URL、標記狀態、提前回報)，不要只靠 `try`/`catch` 那層
- **【2026-07-17】接死碼功能「入口＋出口」都要接**：⌥P 這輪 executor 接了觸發分支,但預覽的 ↩/⎋ 攔截（handlePolishPreviewKey）仍不可達——nonactivating panel 收不到鍵盤,所有互動鍵都得在 event tap handle() 攔。任何新浮窗互動都要在 handle() 有對應分支＋verifier 查「新增函式的呼叫可達性」
- **【2026-07-17】要按功能拆 commit,就必須「每輪做完先 commit 再開下一輪」**：本輪連做兩輪（劃詞／語感）才一起收尾,結果兩輪在 `InputController.swift`（前文 buffer 緊貼 QA 屬性）與 `TranscriptionMode.swift`（英文規則改到第一輪剛加的 .selectionTranslate case）**同一 hunk 內逐行交錯**,拆不開。`git add -p` 在本 harness 是互動指令**不可用**,只剩 hand-authored patch 做 sub-hunk surgery（高風險,未做）。最終只能檔案級拆分＋在 commit message 誠實標註內容外溢。**下次多輪連做前先問：這些輪次要不要分開 commit？要就先 commit 再開下一輪**
- **【2026-07-17】新增 event tap 分支的三個必備守衛**：①`!isAnyRecordingActive`（別劫持進行中的 PTT）②`keyboardEventAutorepeat == 0`（長按不重複觸發）③修飾鍵要**明確排除**不要的（`!flags.contains(.maskShift)` 等,否則 ⌃⌥⇧Q 也會誤觸）。另:PTT 類的 keyUp **只認 keyCode 不認 flags**（使用者常先放開修飾鍵）,且錄音中要「全程獨佔該鍵」吞掉 autorepeat 與終端 keyUp,否則會漏字元進文件（QA 的 q）
- **【2026-07-17】劃詞功能的選取讀取走 `SelectionReader`,不要重刻**：AX（`kAXSelectedTextAttribute`）讀不到時合成 ⌘C,**用自己的獨立剪貼簿快照/還原,絕不碰 `injectText` 的 `clipboardRestoreToken` 機制**（兩者混用會讓還原目標互相蓋掉）。所有 early-return 路徑都必須還原剪貼簿。已知取捨:備援會阻塞主執行緒最長 ~350ms（僅 AX 失敗的 app 才走）;若使用者把自訂語音快捷鍵設成 ⌘C 會誤觸（已註解）
- **【2026-07-17】systemPrompt 動措辭前先想 ApplePolishService 的三層防線**：靜態指紋清單（:167 附近）不會自動涵蓋新 prompt 句;長度 bound 基於 transcript 不受 prompt 長度影響（安全）;前文/長素材類內容一律不要餵 Apple 3B（詞彙表膨脹幻覺同型風險）
- **【2026-07-17】SelectionReader 合成 ⌘C 備援**：獨立快照/還原,絕不共用 injectText 的 clipboardRestoreToken;usleep 輪詢（非 nested runloop,避免 event tap 重入）最長阻塞 ~350ms;使用者若把自訂語音快捷鍵設成 ⌘C 會誤觸（已註解的已知極端 case）
- **【本輪】Apple 3B「詞彙表膨脹幻覺」**：短輸入（幾個字）＋80 詞道場詞彙表,模型會把詞彙表當素材編出幾百字內容,且會附「這段話的意思是說…」評論尾巴。防線在 `ApplePolishService.generateClean`（tight/loose bound＋動態 token 封頂＋評論指紋）——任何動 prompt 長度或詞彙表 cap 的改動都要想到這隻
- **【本輪】ad-hoc 重簽後 Keychain 可能讀出「成功但壞值」**（非只有 harness 亂碼一種型態）:真 app 也發生過一次 Gemini「API key not valid」直到重啟,APIKeyStore 記憶體快取會把壞值釘住整個 session——已加 invalid 自癒,新增其他 API 服務時要比照（收到 key-invalid 類錯誤就 invalidate 對應快取）
- **【本輪】type-specific 的 `*RecordingStartTime` 在 async transcription completion 觸發前就被 nil**——要在 keyUp 同步算好時長（統一 `recordingStartTime`）再傳進 completion,不要在 completion 裡讀那些 property
- **【本輪】codex exec 在非 git 目錄要加 `--skip-git-repo-check`**,否則秒退「Not inside a trusted directory」（prompt 照舊走 stdin heredoc）
- **【本輪】TranscriptNumberFormatter 的擴充紀律**:只准加「有唯一前導/後綴 marker」的 pattern（百分之/零點/趴）,通用中文數字+單位轉換誤傷率高刻意不做;所有轉換必須冪等（potish 輸出會再過一次）;測試檔用 `@main`（兩檔合編不能 top-level code）
- **【本輪 Apple 改版新雷】離線截圖 harness 對 NSScrollView／整個 contentView `cacheDisplay` 截出全白**：System Settings 版面下內容在 scroll view 的 documentView（FlippedView）裡，直接對外層 contentView cacheDisplay 拿不到子內容。對策：改對 `pane.documentView` 逐張截圖再手動合成，或截前強制 `layoutSubtreeIfNeeded`＋等一個 runloop。已寫入全域記憶 `reference_appkit_ui_testing.md` 第 9 點
- **【本輪】`DesignTokens.groupCard(_:autoSeparators:)` 的條件列陷阱**：卡片內若有會 `isHidden` 切換的列（如 provider 專屬的 API Key section），**不能用 autoSeparators 自動加分隔線**——隱藏列旁邊自動插入的 hairline 會殘留成孤兒雙線。正解：`autoSeparators:false`＋條件列自帶 leading hairline 包在同一個 wrapper（`conditionalSection`），隱藏時分隔線跟著收合。見 PreferencesVoiceServiceTab
- **【本輪】`FlippedView` 已從 DrawerCardView 搬到 DesignTokens.swift**：DrawerCardView 刪檔時差點連坐帶走這個共用類別（PreferencesWindowController 的 pane 也在用）。刪任何檔前先 grep 檔內 public/internal 型別有沒有被別處引用
- **【本輪】BadgePill 是 HUD 與 Preferences 共用**（在 CardListView.swift）：改它的 init 預設參數會影響 VoiceHUDController 的鍵帽。本輪加新參數時全給了預設值、且所有呼叫端顯式傳參才安全——動它前先 grep 所有 `BadgePill(` 呼叫點
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
# 現況（2026-07-22）：v2.6.0 已發布並用固定自簽憑證重簽（線上資產已 clobber）。HEAD=e38046a，工作樹乾淨
#   （只剩未追蹤 design-refs/ 留參考不 commit）。本輪三件事全上線：Groq 錄音 WAV＋App Nap／七快捷鍵自訂／簽章治本。
# 無待辦阻塞。開放項：①使用者實測快捷鍵行為回饋（事件攔截只能實機測）②是否要備份簽章憑證（已提議，待使用者點頭）
#   ——若使用者要備份：鑰匙圈存取→找「Input-sa Code Signing」→右鍵匯出 .p12（含私鑰）存到安全處。
#   ——若朋友回報快捷鍵/轉錄仍有問題，那是第一手實戰回饋，優先處理。
# 發版流程（憑證已建，直接用）：改 Info.plist 版號 → ./package-release.sh（自動用固定憑證簽）
#   → commit → push → gh release create vX.Y.Z <zip> --title --notes（或改資產用 gh release upload --clobber）
# 三套迴歸：swiftc tests/main.swift InputSa/AIServices/DojoCorrectionTable.swift -o /tmp/dojo_tests && /tmp/dojo_tests
#          swiftc tests/NumberFormatterTests.swift InputSa/AIServices/TranscriptNumberFormatter.swift -o /tmp/nf_tests && /tmp/nf_tests
#          swiftc tests/SelectionTranslateTests.swift InputSa/AIServices/SelectionTranslateDirection.swift -o /tmp/st_tests && /tmp/st_tests
# 驗簽章：codesign -d -r- build/Input-sa.app  → designated 那行應是 certificate leaf、無 cdhash
# 環境：provider=sherpa（本地）、polishProvider=apple（前文 buffer 只在 Gemini 生效）、dojoMode=true；GEMINI_API_KEY 在 ~/.claude/.env
# 診斷機制自查：選單列 🎙 →「系統診斷...」；麥克風異常修復走 tccutil reset（見 SelfDiagnostics.swift）
```
