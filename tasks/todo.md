# Phase 1 — 最小可跑通 待辦

> 此區為早期 Sherpa 導入清單，未勾選不代表目前未實作；現況以程式碼與 CONTEXT.md 為準。

## 2026-09-19 — 中英辨識與偏好介面續修

- [x] 查看本次相關原稿，確認 SenseVoice 將 Codex／Claude 合成 Cexcloud，AI 未進一步改動。
- [x] 查證 Talky 的 Codex／Claude 文字整理整合；本機已裝兩種 CLI。
- [x] 中英夾雜與專有名詞辨識提示改善，避免同音全域替換，附隔離測試。
- [x] 偏好設定改為 Talky 風格，保留觀音與 Input-sa 身分、所有既有功能。
- [x] 使用者已明確選擇「一起新增，可自行選擇」：新增 Codex／Claude 整理後端，預設服務保持不變。
- [x] 依使用者預覽回饋，修正長文字、分頁圖示、角色選單內距與快捷鍵對齊；30 組排版及原生操作驗證通過。
- [x] 13 套測試、364 項檢查、兩家 CLI 真實合成句、獨立審查及完整編譯通過。
- [x] 安裝前發現 SIGTERM 終止死結；以獨立 AppKit 程序重現，改由 RunLoop 排程終止，保留既有資料收尾。
- [ ] 發布 v3.1.1 修正版、安裝並確認正常退出，保留舊版備份。
- [ ] 依使用者要求整理工作路徑：去除可再生建置產物與已發布封裝，重用既有模型；保留功能與原有素材。

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
