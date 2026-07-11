import Foundation

/// Persists voice-accept/reject stats and custom prompts to UserDefaults.
final class UserStyleModel {

    static let shared = UserStyleModel()
    private let defaults = UserDefaults(suiteName: "com.inputsa.inputmethod") ?? .standard

    private enum Keys {
        static let voiceAcceptCount = "voice_accept_count"
        static let voiceRejectCount = "voice_reject_count"
        static let lastUsedMode     = "last_used_transcription_mode"
        static let customPrompts    = "custom_prompts"
    }

    // MARK: - Voice Stats
    func recordVoiceAccepted() { defaults.set(defaults.integer(forKey: Keys.voiceAcceptCount) + 1, forKey: Keys.voiceAcceptCount) }
    func recordVoiceRejected() { defaults.set(defaults.integer(forKey: Keys.voiceRejectCount) + 1, forKey: Keys.voiceRejectCount) }

    // MARK: - Last Used Mode
    var lastUsedModeID: String {
        get { defaults.string(forKey: Keys.lastUsedMode) ?? "standard" }
        set { defaults.set(newValue, forKey: Keys.lastUsedMode) }
    }

    // MARK: - Custom Prompts
    struct CustomPrompt: Codable {
        var id: String
        var name: String
        var emoji: String
        var prompt: String
    }

    var customPrompts: [CustomPrompt] {
        get {
            guard let data = defaults.data(forKey: Keys.customPrompts),
                  let prompts = try? JSONDecoder().decode([CustomPrompt].self, from: data)
            else { return defaultPrompts }
            return prompts
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.customPrompts)
            }
        }
    }

    private let defaultPrompts: [CustomPrompt] = [
        CustomPrompt(id: "social_ig", name: "IG 貼文", emoji: "📸",
                     prompt: "請將以下文字改寫成適合 Instagram 的貼文風格，加入相關 emoji，分段呈現，保持自然親切的語氣，只回傳結果文字："),
        CustomPrompt(id: "bullet_points", name: "條列重點", emoji: "📋",
                     prompt: "請將以下文字整理成清楚的條列式重點，每點以「•」開頭，只回傳結果："),
        CustomPrompt(id: "formal", name: "正式書信", emoji: "✉️",
                     prompt: "請將以下文字改寫為正式的繁體中文書信風格，保持禮貌專業，只回傳結果："),
    ]

    func addCustomPrompt(_ prompt: CustomPrompt) {
        var prompts = customPrompts; prompts.append(prompt); customPrompts = prompts
    }

    func removeCustomPrompt(id: String) {
        customPrompts = customPrompts.filter { $0.id != id }
    }
}
