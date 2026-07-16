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
    private static let polishProviderKey = "com.inputsa.polishProvider"

    // Process-wide in-memory cache of Keychain-backed keys. Each dictation reads
    // several keys and every raw SecItemCopyMatching under an ad-hoc signature can
    // trigger a "允許使用鑰匙圈" prompt on a friend's machine — so the first read
    // per service goes to the Keychain, everything after is served from memory.
    // Cached value is the raw string, where "" means a confirmed-empty key (also
    // cached, so users who never set a key don't re-prompt on every dictation).
    // Guarded by a lock: getters may run on both the eventTap thread and main.
    private var keyCache: [String: String] = [:]
    private let cacheLock = NSLock()

    /// Drop the cached Gemini key so the next read goes back to the Keychain.
    /// Called when the Gemini API rejects the key as invalid: an ad-hoc
    /// re-signed binary can read a stale/garbled Keychain value once, and the
    /// cache would otherwise pin that bad value for the whole session
    /// (observed 2026-07-16: "API key not valid" until relaunch).
    func invalidateGeminiKeyCache() {
        cacheLock.lock()
        keyCache.removeValue(forKey: Service.gemini)
        cacheLock.unlock()
    }

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

    // MARK: - Polish Provider

    /// Which service handles dictation polish and Option+P text polish. Defaults
    /// to Gemini (cloud); Apple is the fully-offline on-device option. Translation
    /// and 口頭修正 always use Gemini regardless of this setting.
    enum PolishProvider: String {
        case gemini = "gemini"
        case apple  = "apple"
    }

    var polishProvider: PolishProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.polishProviderKey) ?? "gemini"
            return PolishProvider(rawValue: raw) ?? .gemini
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.polishProviderKey)
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
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        // Keep the cache in sync so a freshly saved key is read from memory
        // immediately (the preferences window must reflect it without a restart).
        // Only on a successful Keychain write: caching an unpersisted value would
        // make the key "work" for this session and silently vanish on relaunch.
        guard status == errSecSuccess else { return }
        cacheLock.lock()
        keyCache[service] = value
        cacheLock.unlock()
    }

    private func load(service: String) -> String? {
        // Serve from the in-memory cache when present (including a cached "" for a
        // key that is known to be unset — avoids re-hitting the Keychain).
        cacheLock.lock()
        if let cached = keyCache[service] {
            cacheLock.unlock()
            return cached.isEmpty ? nil : cached
        }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      "apikey",
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String
        if status == errSecSuccess,
           let data = result as? Data,
           let str = String(data: data, encoding: .utf8) {
            value = str
        } else {
            value = ""
        }

        cacheLock.lock()
        keyCache[service] = value
        cacheLock.unlock()
        return value.isEmpty ? nil : value
    }
}
