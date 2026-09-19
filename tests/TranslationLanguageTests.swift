import Foundation

// swiftc tests/TranslationLanguageTests.swift InputSa/AIServices/TranslationLanguage.swift \
//   -o /tmp/inputsa_translation_language_tests && /tmp/inputsa_translation_language_tests
@main
struct TranslationLanguageTests {
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ label: String, _ condition: Bool) {
            checks += 1
            if condition {
                print("PASS: \(label)")
            } else {
                failures += 1
                print("FAIL: \(label)")
            }
        }

        let expected = [
            ("英文", "English"), ("日文", "日本語"), ("韓文", "한국어"),
            ("泰文", "ไทย"), ("越南文", "Tiếng Việt"), ("印尼文", "Bahasa"),
            ("西班牙文", "Español"), ("法文", "Français"),
        ]
        check("eight targets", TranslationLanguage.targets.count == 8)
        check("stable prompt-name order", TranslationLanguage.targets.map(\.promptName) == expected.map { $0.0 })
        check("native labels", TranslationLanguage.targets.map(\.label) == expected.map { $0.1 })
        for (promptName, label) in expected {
            check("\(label) maps to \(promptName)", TranslationLanguage.normalizedPromptName(label) == promptName)
            check("legacy \(promptName) remains valid", TranslationLanguage.normalizedPromptName(promptName) == promptName)
            check("label for \(promptName)", TranslationLanguage.label(for: promptName) == label)
        }
        check("unknown target defaults to English", TranslationLanguage.normalizedPromptName("unknown") == "英文")
        check("empty target defaults to English", TranslationLanguage.normalizedPromptName("") == "英文")

        let suite = "com.inputsa.tests.translation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Unable to create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranslationPreferences(defaults: defaults)
        defaults.set("泰文", forKey: "translateTargetLang")

        check("unconfigured app uses legacy target", preferences.language(for: "app.a", fallback: "泰文") == "泰文")
        preferences.setLanguage("日文", for: "app.a")
        preferences.setLanguage("法文", for: "app.b")
        check("first app remembers Japanese", preferences.language(for: "app.a", fallback: "泰文") == "日文")
        check("second app remembers French", preferences.language(for: "app.b", fallback: "泰文") == "法文")
        check("other app still uses fallback", preferences.language(for: "app.c", fallback: "泰文") == "泰文")
        check("global preference unchanged", defaults.string(forKey: "translateTargetLang") == "泰文")
        check("invalid fallback defaults to English", preferences.language(for: "app.c", fallback: "arbitrary prompt") == "英文")
        check("missing app uses fallback", preferences.language(for: nil, fallback: "印尼文") == "印尼文")
        let beforeNilWrite = defaults.persistentDomain(forName: suite) as NSDictionary?
        preferences.setLanguage("韓文", for: nil)
        preferences.setLanguage("韓文", for: " ")
        check("missing/blank app never writes preferences", beforeNilWrite == defaults.persistentDomain(forName: suite) as NSDictionary?)
        preferences.setLanguage("unknown", for: "app.a")
        check("invalid choice cannot overwrite saved choice", preferences.language(for: "app.a", fallback: "泰文") == "日文")
        preferences.setLanguage("Español", for: "app.c")
        check("native-label choice persists prompt name", preferences.language(for: "app.c", fallback: "泰文") == "西班牙文")
        let reloaded = TranslationPreferences(defaults: defaults)
        check("per-app target survives reload", reloaded.language(for: "app.a", fallback: "英文") == "日文")
        defaults.set(["app.a": "untrusted target"], forKey: "translationLanguagesByApp")
        check("corrupt saved choice uses validated fallback", preferences.language(for: "app.a", fallback: "越南文") == "越南文")
        check("corrupt saved choice and fallback use English", preferences.language(for: "app.a", fallback: "unknown") == "英文")

        print("\(checks - failures)/\(checks) passed")
        if failures > 0 { exit(1) }
    }
}
