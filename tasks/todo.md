# Phase 1 — 最小可跑通 待辦

> 此區為早期 Sherpa 導入清單，未勾選不代表目前未實作；現況以程式碼與 CONTEXT.md 為準。

## 2026-09-20 — 翻譯先看原文、再選語言

- [x] 重現並修正：第二次點按結束後只轉錄，原文保留在面板，點選語言才開始翻譯及送出。
- [x] 每次開始皆無預選語言；錄音／轉錄階段不可誤觸送出，等待選擇期間可取消。
- [x] 譯文置上、中文原文放下一行並包半形括號；貼入、剪貼簿回退與歷史最終文字一致。
- [x] 完整編譯與審查通過；14 套／459 項隔離測試、64 項 controller 整合、42 項翻譯面板及 30 組偏好排版檢查通過。
- [x] 全部四種錄音快捷鍵改為第一次點按開始、第二次點按結束，保留按鍵自訂／衝突保護。
- [x] 偏好設定移除一般／進階二層分組，改單層五入口，完整檢查排版。
- [x] 完成會議紀錄功能規劃（錄音匯入、即時轉錄／潤稿與講者區分；此輪不實作會議功能）。
- [x] v3.2.0/build 13 已發布及安裝，tag f1a758b，公開 ZIP/checksum 大小與 SHA-256 一致；固定簽章、詞庫、模型及主要設定保留，SIGTERM 0.031 秒退出，重啟 event tap 啟用。
- [x] 移除本輪 build 與遠端 digest 已核對的 v3.1.1 舊包，僅留最新包；工作目錄約 562.6 MiB，原素材及獨有模型保留。

## 2026-09-19 — 中英辨識與偏好介面續修

- [x] 查看本次相關原稿，確認 SenseVoice 將 Codex／Claude 合成 Cexcloud，AI 未進一步改動。
- [x] 查證 Talky 的 Codex／Claude 文字整理整合；本機已裝兩種 CLI。
- [x] 中英夾雜與專有名詞辨識提示改善，避免同音全域替換，附隔離測試。
- [x] 偏好設定改為 Talky 風格，保留觀音與 Input-sa 身分、所有既有功能。
- [x] 使用者已明確選擇「一起新增，可自行選擇」：新增 Codex／Claude 整理後端，預設服務保持不變。
- [x] 依使用者預覽回饋，修正長文字、分頁圖示、角色選單內距與快捷鍵對齊；30 組排版及原生操作驗證通過。
- [x] 13 套測試、364 項檢查、兩家 CLI 真實合成句、獨立審查及完整編譯通過。
- [x] 安裝前發現 SIGTERM 終止死結；以獨立 AppKit 程序重現，改由 RunLoop 排程終止，保留既有資料收尾。
- [x] v3.1.1/build 12 已安裝、發布；tag 對應 5b73875，公開 ZIP／checksum SHA-256 比對一致。正式 App SIGTERM 約 0.09 秒退出，重啟後 event tap 啟用，原設定／詞庫／模型保留。
- [x] 工作路徑由 3,390,400 KiB 降至 575,684 KiB（約 3.23 GiB → 562 MiB，減少 83%）：清除可再生 build 及 10 份已逐一核對遠端 digest 的舊 ZIP／2 份 checksum。保留最新版包、原素材、SenseVoice、獨有 Paraformer 備份；模型工具重用 AppSupport 模型。
- [x] 清理後重跑 13 套隔離測試全部通過。安裝前版本備份：`~/Applications/.inputsa-backups/20260919T123724Z-26913/Input-sa.app`。

## 2026-09-19 — 完整翻修、上線與安裝（使用者已授權）

- [x] 接入可選 Whisper large-v3-turbo、官方固定 runtime、模型下載／續傳／驗證與取消。
- [x] 各引擎保留原始與繁轉文字，加入可關閉的本地歷史與原稿／結果比較、複製。
- [x] Whisper 錄音中顯示暫時字幕、結束後完整解碼；原文／輕整理／結構整理三種強度。
- [x] 整合保留觀音角色的 420 × 156 精簡錄音 HUD、編號字詞庫、八語言翻譯、歷史、模型管理介面及取消／跨 App 輸出保護。
- [x] 改善安裝與打包流程：固定簽章、獨立發佈產物、備份與可回復安裝、保留使用者資料。
- [x] 11 套隔離測試、實際 Whisper runtime 與原生 UI 驗證，獨立程式審查通過；打包／安裝 fixture 通過。
- [x] 更新 v3.0.0 版本與文件，準備 `tasks/release-v3.0.0.md` 發布說明。
- [x] 提交 `c2a0a83` 已推送；[v3.0.0 Release](https://github.com/hallowjason/input-sa/releases/tag/v3.0.0) 已公開，zip 16,227,258 bytes，GitHub SHA-256 與本機 checksum 一致。
- [x] 安裝正式版本，確認固定簽章、SenseVoice 模型保留、本機啟動與事件攔截器啟用；Whisper 模型安裝校驗及已簽引擎實測通過。

驗證界線：以合成／公開測試音訊做引擎驗證；使用者未提供錄音正確稿，不能宣稱個人準確率改善，也不依此變更既有引擎偏好。Qwen／Ollama／CLI 屬後續選配。

## 2026-09-19 — Talky 整合研究

- [x] 確認現有版本、主架構、語音服務與介面。
- [x] 沿原始碼定位辨識錯誤與過度改寫的風險，純本地重現三種詞庫誤改。
- [x] 核對 Talky 引擎、介面、詞彙與部署方式。
- [x] 整理比較與本次實作結果，見 `tasks/talky-integration-study.md`。
- [ ] 依使用者實際語音建立基準測試（待取得測試錄音與正確逐字稿）。

### 已確認的本次實作範圍

- [x] 移除道場開關，改通用編號字詞庫；舊詞條保留，停止全域同音硬替換。
- [x] 翻譯浮窗提供八語言切換，各 App 記住語言；保留現有自訂快捷鍵。
- [x] 同段錄音內自然改口，保留更正後內容與未撤回資訊；不處理跨次錄音改字。
- [x] 詞庫／語言記憶／翻譯生命週期測試、完整編譯、介面檢視與程式審查。
- [x] Gemini 合成文字實測：時間、人名改口、普通否定句；修正翻譯保留撤回時間的問題並複測通過。
- [ ] 安裝後實測麥克風、長按快捷鍵、跨 App 貼入及 Apple 本地整理品質；個人錄音品質基準仍待提供測試資料。

---

> 詳見 [PRD-sherpa-voice.md](./PRD-sherpa-voice.md)

## 資產準備（背景 agent 進行中）
- [ ] Paraformer 模型 → `InputSa/Resources/model/`（model.int8.onnx ~240MB + tokens.txt）
- [ ] shared dylib → `vendor/sherpa/lib/`（c-api + onnxruntime）+ `vendor/sherpa/include/`
- [ ] Swift binding → `vendor/sherpa/swift/`（SherpaOnnx.swift + bridging header）
- [ ] opencc s2twp 分階段字典 → `InputSa/Resources/opencc/s2twp_dict.json`

## 程式實作
- [ ] `OpenCCConverter.convert(_:) -> String`（讀 s2twp_dict.json，多階段最長匹配）+ 單元測試（軟件→軟體、头→頭）
- [ ] `SherpaVoiceService`（conform `VoiceServiceProtocol`，沿用 GroqVoiceService 錄音/最短時長守門；16k 錄音→Paraformer 解碼→OpenCC→success；模型 lazy 載入後常駐保溫）
- [ ] `APIKeyStore.VoiceProvider` 加 `case sherpa`
- [ ] `InputController.refreshVoiceService()` 加 `case .sherpa`

## Build / 安裝
- [ ] `build.sh`：加 source、`-import-objc-header`、`-I/-L vendor/sherpa -lsherpa-onnx-c-api`、`-Xlinker -rpath @executable_path/../Frameworks`；複製 2 支 dylib→`Contents/Frameworks/`、model/tokens/dict→`Contents/Resources/`
- [ ] `install.sh`：驗證 `codesign --deep` 涵蓋 Frameworks/dylib（`codesign -v` 通過）

## 驗收
- [ ] 飛航模式端到端：sherpa 模式錄音→繁體注入正確
- [ ] 量測模型載入 / 推理延遲（對照 PoC RTF）
