# Input-sa

macOS 語音輸入法。按住右 Option 錄音，放開後自動轉成文字、用 AI 潤飾排版，直接貼到游標所在位置。

## 快速安裝

1. 到 [Releases](../../releases) 頁面下載最新的 `Input-sa-vX.Y.Z.zip`，解壓縮後把 `Input-sa.app` 拖進「應用程式」資料夾。
2. **第一次開啟會被 Gatekeeper 擋下**（因為不是從 App Store 或付費開發者憑證簽的）：在「應用程式」裡對 `Input-sa.app` **按右鍵 → 打開**，跳出的警告視窗再按一次「打開」即可，之後正常雙擊就能開。
3. 系統會跳出「輔助使用功能」授權請求 → 前往 **系統設定 → 隱私權與安全性 → 輔助使用功能**，開啟 `Input-sa`。
4. 選單列會出現 🎙 圖示 → 點開 **偏好設定**（或按 `Ctrl+Option+P`）→ 在「API Keys」分頁填入你自己的 Groq、Gemini API key（見下方申請方式）。
5. 完成！在任何輸入框按住右 Option 說話，放開後文字就會自動出現。

想開機自動啟動：**系統設定 → 一般 → 登入項目與延伸功能** → 點 `+` 選擇 `Input-sa.app`。

## 申請免費 API Key

- **Groq**（語音轉文字，免費額度足夠日常使用）：[console.groq.com/keys](https://console.groq.com/keys) 註冊後建立一組 key。
- **Gemini**（AI 潤飾排版）：[aistudio.google.com/apikey](https://aistudio.google.com/apikey) 用 Google 帳號登入後建立一組 key。

兩組 key 都只存在你自己 Mac 的系統 Keychain（`APIKeyStore.swift`），不會上傳、不會被開發者看到，也不會跟其他人共用額度。

## 進階：本地離線辨識模式（不需要網路，不需要 API key）

預設走 Groq 雲端辨識最簡單。如果你想要離線使用、或希望道場術語辨識更準（本地 SenseVoice 模型對「後學、點傳師、聖賢、賢德班」這類詞的原生辨識率比雲端 Whisper 高），可以手動啟用本地模式：

1. 下載 SenseVoice 模型（[sherpa-onnx-sense-voice-zh-en-ja-ko-yue](https://github.com/k2-fsa/sherpa-onnx/releases) 的 int8 版本，約 228MB）
2. 把 `model.int8.onnx`、`tokens.txt` 放進 `Input-sa.app/Contents/Resources/model/sensevoice/`（在應用程式上按右鍵 → 顯示套件內容 即可進入）
3. 偏好設定 → API Keys 分頁 → Provider 選擇「本地 Sherpa」

## 道場詞彙校正

「道場詞庫」分頁可以開關「道場模式」——開啟後，一貫道相關術語（後學、點傳師、發愿、辦道…）會被自動校正，且不會誤改一般日常用語。詞庫在 `InputSa/Resources/dojo/dojo_corrections.json`，歡迎回報聽錯的詞。

## 給想自己編譯的人

需要 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/hallowjason/input-sa.git
cd input-sa
./install.sh
```

會自動編譯、簽章（找不到開發憑證會自動退回 ad-hoc 簽章）、安裝到 `~/Applications/Input-sa.app` 並啟動。之後要更新，`git pull` 再跑一次 `./install.sh` 即可。

## 更新

回到本頁面的 [Releases](../../releases) 看有沒有新版本，下載新的 zip 蓋掉舊的 `Input-sa.app` 即可，設定（API key、偏好）都存在系統層級，不會遺失。
