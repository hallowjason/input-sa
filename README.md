# Input-sa

macOS 語音輸入法。按住右 Option 錄音，放開後自動轉成文字、用 AI 潤飾排版，直接貼到游標所在位置。

v3.1 將偏好設定改為柔和圓角與一般／進階分組，新增可選 Codex／Claude 文字整理，補上中英夾雜的專有名詞提示；保留本地 Whisper、觀音錄音面板、三種整理強度與原稿紀錄。支援 Apple Silicon Mac；主程式最低 macOS 12，本地 Whisper 需 macOS 14 以上，Apple 本地整理需 macOS 26 與 Apple Intelligence。[本版變更](tasks/release-v3.1.1.md)

## 快速安裝

1. 到 [Releases](../../releases) 頁面下載最新的 `Input-sa-vX.Y.Z.zip`，解壓縮後把 `Input-sa.app` 拖進「應用程式」資料夾。
2. **第一次開啟會被 Gatekeeper 擋下**（因為不是從 App Store 或付費開發者憑證簽的）：在「應用程式」裡對 `Input-sa.app` **按右鍵 → 打開**，跳出的警告視窗再按一次「打開」即可，之後正常雙擊就能開。
3. 系統會跳出「輔助使用功能」授權請求 → 前往 **系統設定 → 隱私權與安全性 → 輔助使用功能**，開啟 `Input-sa`。
4. 選單列圖示 → **偏好設定**（或按 `Ctrl+Option+P`）→「進階 → 語音服務」選擇引擎。雲端服務填入自己的 API Key；本地 Whisper 可從「管理模型…」下載，無需語音 API Key。
5. 完成！在任何輸入框按住右 Option 說話，放開後文字就會自動出現。

想開機自動啟動：**系統設定 → 一般 → 登入項目與延伸功能** → 點 `+` 選擇 `Input-sa.app`。

## 設定 API Key

- **Groq**（雲端語音轉文字）：[console.groq.com/keys](https://console.groq.com/keys) 建立一組 key；額度與費率以服務商當前方案為準。
- **Gemini**（AI 潤飾排版）：[aistudio.google.com/apikey](https://aistudio.google.com/apikey) 用 Google 帳號登入後建立一組 key。

Key 儲存在這台 Mac 的系統 Keychain，只用於對應服務的請求驗證，不會分享給開發者或其他使用者。選擇雲端辨識時，錄音會送給所選服務；選擇 Gemini 整理／翻譯時，文字與有限詞庫參考會送給 Gemini。

## 選擇文字整理服務

「偏好設定 → 進階 → 語音服務 → 用什麼整理」可選 Gemini、Apple 本地、Codex CLI 或 Claude Code。此選項用於口述整理與選字潤飾；翻譯、劃詞問答與口頭加詞仍使用 Gemini。升級保留原本選擇，點選 CLI 不會自動安裝或登入。

Codex／Claude 需先在這台 Mac 安裝對應官方 CLI，並在終端機完成登入。設定內的「已找到 CLI」只表示找到執行檔；按「測試連線」才會送出一段內建測試句，確認登入及文字處理可用。CLI 使用自己的服務帳號與額度，仍屬雲端文字整理，並非離線辨識模型。

本版 Codex 接法固定驗證 CLI **0.154.0**，使用 `gpt-5.5` 整理；其他版本會停止處理並提示更新 Input-sa。CLI 整合限未受組織政策管理的個人登入；企業／團隊／受管理環境會提示不相容，口述保留辨識稿，不自動修改公司的設定或帳號。

選用 CLI 後，辨識文字、有限詞庫與必要前文會交給該服務整理；每次使用獨立程序，不延續 CLI 對話。原稿從標準輸入傳入，具有輸入／輸出上限、整理階段 90 秒逾時與取消處理；登入及版本預檢另有短逾時。整理失敗時口述功能保留辨識稿；按 Esc 取消後不貼字。「原文」強度不呼叫任何整理服務。

## 本地辨識與模型管理

「語音服務」→「管理模型…」下載 Whisper large-v3-turbo（約 1.6 GB）。下載支援暫停續傳，通過大小與 SHA-256 驗證後才可使用；模型存於 `~/Library/Application Support/InputSa/models/`，升級 App 不必重新下載。完成後選「本地 Whisper Turbo」。

Whisper 錄音時定期顯示尾段的暫時字幕，放開後重新辨識完整錄音；暫時字幕不當作最終輸出。Groq／Google／既有 SenseVoice 於停止後顯示辨識結果。

原有 SenseVoice／Paraformer 支援保留。本機從原始碼建置會包含原有模型；公開 zip 不包含大型模型，可在 App 內下載 Whisper。不要修改已簽章 App 內部檔案。語音與整理服務各自選擇；完全離線可搭配「原文」或可用的 Apple 本地整理。

中英夾雜時可試用已下載的 Whisper Turbo：它支援辨識階段的專有名詞提示。SenseVoice／Paraformer 的現有解碼方式不支援這類提示，仍可由後續 AI 整理參考詞庫。提示不等於模型訓練；口音與錄音品質仍需實際比較，升級不會自動更換你選定的引擎。

## 整理強度與原稿紀錄

- **原文**：直接輸出辨識／繁體轉換結果，不呼叫 AI、不改寫數字，也保留改口過程。
- **輕整理**（預設）：補標點、去停頓音、理解同段改口，保留原本用詞。
- **結構整理**：依內容分段或列點，保留有效細節；也可沿用自己的 AI 模式。

選單列「口述紀錄…」可比較模型原文、繁體原稿、AI 結果與實際輸出，並複製任一階段。紀錄僅存在這台 Mac，最多 200 筆／2 MB，不保存錄音，可停用或清空；清空後排隊中的舊寫入不會重新出現。取消後不貼字，處理期間切換 App 時只留剪貼簿。AI 失敗會明確提示並保留辨識稿；翻譯失敗不會把中文原稿當譯文貼出。

## 字詞庫

「字詞庫」分頁統一管理人名、專有名詞與常用字詞，以編號列出，說話時不必切換道場模式。可以手動新增，或按住右 Shift「口頭加詞」、確認後儲存；現有詞條會保留。

詞庫提供給 AI 作為拼寫參考，本地 Whisper、Groq 與 Google STT 也會收到限量的專有名詞辨識提示，包括 Codex／Claude 的拼寫；不對全文強制做同音替換。詞多時，與本句明確相關的詞優先進入 AI 提示。舊的 `tier`、`phonetic` 欄位與 `dojo_corrections.json` 路徑保留以相容存檔，不再代表模式或自動替換規則。

## 翻譯面板與自然改口

按住翻譯快捷鍵（預設右 Command）說話，面板提供英、日、韓、泰、越南、印尼、西班牙、法文八種語言。點語言即可結束錄音並翻譯；放開快捷鍵則使用已選語言。每個 App 會記住上次選擇，未選過的 App 使用偏好設定中的預設語言。取消後不貼字；若處理期間切到其他 App，結果留在剪貼簿並顯示提示。

同一段錄音中可直接改口，例如「明天下午三點開會，啊不對，是四點，地點在二樓」。AI 整理／翻譯會依明確的改口標記，保留更正後的時間與其他資訊。一般否定句和引用不應被當成改口。這個功能需要 AI 處理；若 AI 不可用而退回原稿，仍可能保留完整改口過程。它不會回頭改動上一次已貼出的文字。

## 給想自己編譯的人

需要完整 Xcode／macOS SDK（FoundationModels 巨集使用 Xcode 提供的工具）。重新建置 Whisper runtime 另需 CMake；倉庫內附固定版本的 arm64 執行程式。

```bash
git clone https://github.com/hallowjason/input-sa.git
cd input-sa
./tools/create-signing-cert.sh   # 只需跑一次：建立固定的簽章憑證
./install.sh
```

本地測試：`bash tools/test.sh`（13 套隔離測試，不讀個人資料或使用麥克風）。重新建立 Whisper：`bash tools/prepare-whisper-runtime.sh`；模型下載工具：`bash tools/prepare-whisper-model.sh`。真實音訊測試見 `tests/WhisperRuntimeTests.swift`。

日常編譯直接使用 `vendor/whisper/` 的現成引擎，不必重抓 CMake 或重編 whisper.cpp。模型工具預設重用 App 的 `~/Library/Application Support/InputSa/models/`，經相同 SHA-256 驗證後直接使用；需要隔離測試時仍可明確傳入另一個目錄。`build/` 是可重建的輸出與開發暫存；已完成安裝與發布後可清除，原始碼、`vendor/` 的引擎／函式庫與 `InputSa/Resources/model/` 的本地模型要保留。

工作目錄只需保留最新版封裝。舊 ZIP 與 checksum 在確認 GitHub 同版附件的檔名、大小、SHA-256 全部一致後才清除；`vendor/models-backup/` 或個人素材若沒有其他可靠副本，繼續保留。App 的模型、詞庫與紀錄位於使用者資料目錄，不列入建置暫存清理。

`create-signing-cert.sh` 會建立一張**永久（約 10 年）的自簽程式簽章憑證**，之後 `./install.sh` 與 `./package-release.sh` 都會自動用它。用同一張固定憑證簽章，是讓「升級後麥克風授權不失效」成立的關鍵——ad-hoc 簽章每次重編都會變，授權就會對不上（詳見該腳本開頭註解）。第一次用它簽章時，系統可能跳「codesign 想使用鑰匙圈金鑰」，按【總是允許】一次即可。

之後更新可 `git pull` 再跑 `bash install.sh`。安裝會驗證新版符合舊版簽章身分，備份於 `~/Applications/.inputsa-backups/`；缺少原簽章身分時停止，不默默改成 ad-hoc。發布執行 `bash package-release.sh`，使用獨立的 `build/release/`，產生含 Whisper runtime 的 zip 與 SHA-256 檔；不移動原始模型、不覆蓋本機完整建置。

## 更新

回到本頁面的 [Releases](../../releases) 看有沒有新版本，下載新的 zip 蓋掉舊的 `Input-sa.app` 即可，設定（API key、偏好）都存在系統層級，不會遺失。

官方更新沿用固定簽章身分，以保留既有麥克風與輔助使用授權；若從不同簽章來源升級，可能需要重新授權。錄音有問題時，可從選單列「系統診斷…」檢查。

Whisper 使用 [whisper.cpp](https://github.com/ggml-org/whisper.cpp)；版本與第三方授權隨 `vendor/whisper/` 及 App 一併提供。介面與操作參考 [Talky](https://github.com/intentionltd888/talky)，保留 Input-sa 品牌。模型準確率須以實際錄音評估，不因換引擎而保證提升。
