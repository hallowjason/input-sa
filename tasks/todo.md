# Phase 1 — 最小可跑通 待辦

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
