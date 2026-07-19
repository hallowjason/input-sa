import AppKit
import AVFoundation
import ApplicationServices

/// Install-environment self-diagnosis and self-repair.
///
/// Root cause this exists for: on machines without an Apple Development
/// certificate, install.sh falls back to ad-hoc signing, so every rebuild
/// changes the app's code signature. macOS TCC ties the microphone grant to
/// that signature — System Settings keeps showing the toggle ON while the
/// running binary is actually unauthorized, and recording silently captures
/// nothing (HUD shows, waveform never moves). Every entry point (launch
/// check, key-down guard, menu-bar 系統診斷) shares this one implementation
/// so the failure is explained and repairable on any user's machine.
enum SelfDiagnostics {

    struct Check {
        let title: String
        let passed: Bool
        let detail: String
    }

    // MARK: - Checks

    static func runChecks() -> [Check] {
        var checks: [Check] = []

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        checks.append(Check(title: "麥克風權限",
                            passed: mic == .authorized,
                            detail: micStatusDescription(mic)))

        let axTrusted = AXIsProcessTrusted()
        checks.append(Check(title: "輔助使用權限",
                            passed: axTrusted,
                            detail: axTrusted ? "已授權"
                                : "未授權——快捷鍵與文字注入無法運作。若開關已開仍無效，請在「輔助使用」清單把 Input-sa 移除（－）再重新加入（＋）"))

        let hasInput = AVCaptureDevice.default(for: .audio) != nil
        checks.append(Check(title: "音訊輸入裝置",
                            passed: hasInput,
                            detail: hasInput ? "已找到預設輸入裝置"
                                : "找不到任何輸入裝置——請檢查「系統設定 › 聲音 › 輸入」"))

        if APIKeyStore.shared.voiceProvider == .sherpa {
            let ok = SherpaVoiceService.modelInstalled
            checks.append(Check(title: "本地語音模型",
                                passed: ok,
                                detail: ok ? "模型檔已隨 App 安裝"
                                    : "找不到 model.int8.onnx / tokens.txt——安裝包不完整，請重新安裝"))
        }
        return checks
    }

    private static func micStatusDescription(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized:    return "已授權"
        case .notDetermined: return "尚未詢問——下次錄音時系統會跳出詢問視窗"
        case .denied:        return "系統回報未授權。若設定裡開關顯示開啟，代表授權紀錄對不上目前的 App 簽章（重新安裝後常見），請用「重置麥克風權限」修復"
        case .restricted:    return "被系統管理政策限制，無法使用"
        @unknown default:    return "未知狀態"
        }
    }

    // MARK: - Repair

    /// Clear this app's microphone TCC record, then re-request access so macOS
    /// shows a fresh system prompt. One-click fix for the "toggle is ON but the
    /// app is not actually authorized" signature-mismatch state that
    /// ad-hoc-signed reinstalls produce.
    static func resetMicPermissionAndReprompt() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.inputsa.inputmethod"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Microphone", bundleID]
        do {
            try p.run()
            p.waitUntilExit()
            inputSaLog("SelfDiagnostics: tccutil reset Microphone \(bundleID) → exit \(p.terminationStatus)")
        } catch {
            inputSaLog("SelfDiagnostics: tccutil launch failed: \(error)")
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            inputSaLog("SelfDiagnostics: re-request after reset → \(granted ? "granted" : "denied")")
            DispatchQueue.main.async {
                let alert = NSAlert()
                if granted {
                    alert.messageText = "麥克風權限已修復"
                    alert.informativeText = "已重新取得麥克風授權，語音輸入可以使用了。"
                } else {
                    alert.messageText = "仍未取得麥克風權限"
                    alert.informativeText = "請完全結束 Input-sa 後重新開啟；若系統沒有再次詢問，請到「系統設定 › 隱私與安全性 › 麥克風」把 Input-sa 關閉再開啟。"
                }
                alert.runModal()
            }
        }
    }

    /// Standard recovery dialog for a denied / mismatched mic grant.
    static func presentMicPermissionRecovery() {
        let alert = NSAlert()
        alert.messageText = "麥克風沒有作用"
        alert.informativeText = """
        系統目前不允許 Input-sa 使用麥克風，所以錄音時不會有聲波反應。

        常見原因：重新安裝後 App 簽章改變，系統設定裡的開關雖然顯示開啟，實際授權已失效。

        建議先按「重置麥克風權限」，讓系統重新詢問一次。
        """
        alert.addButton(withTitle: "重置麥克風權限")
        alert.addButton(withTitle: "開啟系統設定")
        alert.addButton(withTitle: "稍後")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetMicPermissionAndReprompt()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default:
            break
        }
    }

    // MARK: - Report UI（選單列 → 系統診斷…）

    static func presentReport() {
        let checks = runChecks()
        inputSaLog("SelfDiagnostics report: "
                   + checks.map { "\($0.title)=\($0.passed ? "PASS" : "FAIL")" }.joined(separator: " "))

        let alert = NSAlert()
        alert.messageText = checks.allSatisfy(\.passed) ? "系統診斷：一切正常" : "系統診斷：發現問題"
        alert.informativeText = checks
            .map { "\($0.passed ? "✅" : "❌") \($0.title)：\($0.detail)" }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "好")
        let micFailed = checks.contains { $0.title == "麥克風權限" && !$0.passed }
        if micFailed { alert.addButton(withTitle: "重置麥克風權限") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            resetMicPermissionAndReprompt()
        }
    }
}
