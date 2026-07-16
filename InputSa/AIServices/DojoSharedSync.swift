import Foundation

/// Syncs the 道場共編詞庫 (community-edited dojo vocabulary) with a Google Apps
/// Script endpoint. Deliberately isolated from the transcription hot path: this
/// only fetches/writes a cache file (`dojo_shared.json`) and asks
/// `DojoCorrectionTable` to reload. `DojoCorrectionTable.correct(_:dojoMode:)`
/// never touches the network — sync and input stay separate by design.
///
/// Offline is a normal state: any failure (no connectivity, an HTML error page
/// while the endpoint's OAuth authorization is still pending, an HTTP error)
/// keeps the previous cache, logs a single line, and never shows an alert.
final class DojoSharedSync {

    static let shared = DojoSharedSync()

    /// GAS web-app endpoint (already deployed).
    private static let endpoint = URL(string:
        "https://script.google.com/macros/s/AKfycbzGlQvM-yIr4H0LMjxFwlwkRRDYpNR_tm16tL5bGywfK_UFxkET3hKeHb4xPHL5YyMbkA/exec")!

    // UserDefaults keys (all com.inputsa.* prefixed)
    private static let lastSyncKey = "com.inputsa.sharedVocabLastSync"
    private static let versionKey  = "com.inputsa.sharedVocabVersion"
    static let nicknameKey  = "com.inputsa.communityNickname"

    private static let timeout: TimeInterval = 15

    enum SubmitOutcome { case ok, duplicate }

    private init() {}

    /// The cache file (`dojo_shared.json`) is owned by `DojoCorrectionTable`
    /// (which reads it), so this layer just writes to the same path.
    private static var sharedCacheURL: URL? { DojoCorrectionTable.sharedCacheURL }

    // MARK: - GET: pull approved shared entries

    /// Fetch the approved shared vocabulary and merge it into the local table.
    /// `completion` fires on the main thread with whether the cache was updated.
    func syncNow(completion: ((Bool) -> Void)? = nil) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout

        URLSession.shared.dataTask(with: request) { data, response, error in
            let updated = Self.handleSyncResponse(data: data, response: response, error: error)
            DispatchQueue.main.async {
                if updated { DojoCorrectionTable.shared.reload() }
                completion?(updated)
            }
        }.resume()
    }

    /// Runs on the URLSession background queue. Returns `true` only when a valid
    /// JSON payload was parsed and written to the cache. Any failure keeps the
    /// old cache untouched.
    private static func handleSyncResponse(data: Data?, response: URLResponse?, error: Error?) -> Bool {
        if let error = error {
            inputSaLog("shared sync failed: \(error.localizedDescription) — keeping cached vocab")
            return false
        }
        guard let data = data else {
            inputSaLog("shared sync failed: no data — keeping cached vocab")
            return false
        }
        // Non-JSON body (e.g. the GAS OAuth-consent HTML page) fails to decode and
        // is treated as a no-op — offline / not-yet-authorized is a normal state.
        guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: data),
              payload.status == "ok" else {
            inputSaLog("shared sync: non-JSON or non-ok response — keeping cached vocab")
            return false
        }
        guard let cacheURL = sharedCacheURL else {
            inputSaLog("shared sync: no Application Support dir — cannot cache")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONEncoder().encode(CacheFile(entries: payload.entries))
            try out.write(to: cacheURL, options: .atomic)
        } catch {
            inputSaLog("shared sync: cache write failed — \(error.localizedDescription)")
            return false
        }
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        if let version = payload.version {
            UserDefaults.standard.set(version, forKey: versionKey)
        }
        inputSaLog("shared sync ok: \(payload.entries.count) entries (version \(payload.version ?? "?"))")
        return true
    }

    // MARK: - POST: submit a personal entry to the shared pool for review

    /// Submit one entry to the community pool. `completion` fires on the main thread.
    func submit(entry: DojoCorrectionTable.Entry,
                completion: @escaping (Result<SubmitOutcome, Error>) -> Void) {
        let submitter = UserDefaults.standard.string(forKey: Self.nicknameKey) ?? ""
        // `wrong == correct` is our internal "no mishearing given" convention;
        // send an empty `wrong` so the shared record stays clean.
        let wrong = entry.wrong == entry.correct ? "" : entry.wrong
        let body: [String: Any] = [
            "action": "submit",
            "entry": [
                "correct": entry.correct,
                "wrong": wrong,
                "tier": entry.tier,
                "phonetic": entry.phonetic,
                "note": "",
            ],
            "submitter": submitter,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(.failure(Self.err("無法建立分享請求"))) }
            return
        }
        request.httpBody = httpBody

        // GAS 302-redirects POST → GET; URLSession follows it automatically and the
        // body we receive is doPost's real JSON response. Do NOT disable redirect
        // following — the default behaviour is what makes this work.
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data,
                      let result = try? JSONDecoder().decode(SubmitResult.self, from: data) else {
                    completion(.failure(Self.err("分享服務回應無法解析（可能授權尚未開通）")))
                    return
                }
                switch result.status {
                case "ok":        completion(.success(.ok))
                case "duplicate": completion(.success(.duplicate))
                default:          completion(.failure(Self.err(result.message ?? "分享失敗")))
                }
            }
        }.resume()
    }

    // MARK: - Codable payloads

    private struct SyncPayload: Decodable {
        let status: String
        let version: String?
        let entries: [DojoCorrectionTable.Entry]
    }
    private struct CacheFile: Encodable {
        let entries: [DojoCorrectionTable.Entry]
    }
    private struct SubmitResult: Decodable {
        let status: String
        let message: String?
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "InputSa.DojoSharedSync", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
