import Foundation

/// Dictation strength is separate from the speech engine and the AI provider.
enum DictationCleanupStyle: String, CaseIterable {
    case verbatim, light, structured

    static let preferenceKey = "com.inputsa.dictationCleanupStyle"
    static var selected: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .light }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    var title: String {
        switch self {
        case .verbatim: return "原文"
        case .light: return "輕整理"
        case .structured: return "結構整理"
        }
    }

    var explanation: String {
        switch self {
        case .verbatim: return "保留辨識與繁轉結果，不呼叫 AI，也保留改口過程。"
        case .light: return "補標點、去停頓音、處理同段改口，保留原本用詞。"
        case .structured: return "處理同段改口，依內容分段或列點，保留所有有效細節。"
        }
    }

    var mode: TranscriptionMode {
        switch self {
        case .verbatim, .light: return .standard
        case .structured:
            return .custom(id: "builtin_structured", prompt:
                "將口述依主題分段；只有明確列舉時才改成條列。保留原本用詞、順序與所有有效細節，" +
                "保留人名、英文、時間、數字與否定意思，不摘要、不擴寫、不替使用者下結論。" +
                "只刪除明確撤回的內容及無語意停頓音，使用本段最後更正的值。")
        }
    }
}
