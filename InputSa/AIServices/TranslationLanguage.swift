import Foundation

/// Native labels for the switcher; Chinese names remain compatible with saved
/// preferences and the existing translation prompts.
struct TranslationLanguage: Equatable {
    let promptName: String
    let label: String

    static let targets: [TranslationLanguage] = [
        .init(promptName: "英文", label: "English"),
        .init(promptName: "日文", label: "日本語"),
        .init(promptName: "韓文", label: "한국어"),
        .init(promptName: "泰文", label: "ไทย"),
        .init(promptName: "越南文", label: "Tiếng Việt"),
        .init(promptName: "印尼文", label: "Bahasa"),
        .init(promptName: "西班牙文", label: "Español"),
        .init(promptName: "法文", label: "Français"),
    ]

    static func normalizedPromptName(_ value: String) -> String {
        matching(value)?.promptName ?? "英文"
    }

    static func label(for value: String) -> String {
        matching(value)?.label ?? "English"
    }

    fileprivate static func matching(_ value: String) -> TranslationLanguage? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return targets.first { $0.promptName == value || $0.label == value }
    }
}

/// Remembers the target for the app captured when recording starts. The caller
/// supplies the legacy global preference as a fallback; choosing a chip never
/// changes that global preference or another app's target.
final class TranslationPreferences {
    static let shared = TranslationPreferences()
    private let defaults: UserDefaults
    private let perAppKey = "translationLanguagesByApp"

    init(defaults: UserDefaults = UserDefaults(suiteName: "com.inputsa.inputmethod") ?? .standard) {
        self.defaults = defaults
    }

    func language(for appID: String?, fallback: String) -> String {
        if let appID = validAppID(appID),
           let saved = defaults.dictionary(forKey: perAppKey)?[appID] as? String,
           let language = TranslationLanguage.matching(saved) {
            return language.promptName
        }
        return TranslationLanguage.normalizedPromptName(fallback)
    }

    func setLanguage(_ language: String, for appID: String?) {
        guard let appID = validAppID(appID),
              let target = TranslationLanguage.matching(language) else { return }
        var saved = defaults.dictionary(forKey: perAppKey) ?? [:]
        saved[appID] = target.promptName
        defaults.set(saved, forKey: perAppKey)
    }

    private func validAppID(_ appID: String?) -> String? {
        guard let appID = appID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appID.isEmpty else { return nil }
        return appID
    }
}
