import Foundation
import Security

/// Stores and retrieves API keys from the system Keychain.
final class APIKeyStore {
    static let shared = APIKeyStore()

    private enum Service {
        static let groq      = "com.inputsa.inputmethod.groq"
        static let gemini    = "com.inputsa.inputmethod.gemini"
        static let googleStt = "com.inputsa.inputmethod.googlestt"
    }

    private static let voiceProviderKey = "com.inputsa.voiceProvider"

    // MARK: - Voice Provider

    enum VoiceProvider: String {
        case groq   = "groq"
        case google = "google"
        case sherpa = "sherpa"
    }

    var voiceProvider: VoiceProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.voiceProviderKey) ?? "groq"
            return VoiceProvider(rawValue: raw) ?? .groq
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.voiceProviderKey)
        }
    }

    // MARK: - Groq
    var groqKey: String {
        get { load(service: Service.groq) ?? "" }
        set { save(service: Service.groq, value: newValue) }
    }

    // MARK: - Gemini
    var geminiKey: String {
        get { load(service: Service.gemini) ?? "" }
        set { save(service: Service.gemini, value: newValue) }
    }

    // MARK: - Google STT
    var googleSttKey: String {
        get { load(service: Service.googleStt) ?? "" }
        set { save(service: Service.googleStt, value: newValue) }
    }

    // MARK: - Keychain helpers
    private func save(service: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apikey",
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      "apikey",
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str.isEmpty ? nil : str
    }
}
