import Foundation

/// Sends text to Gemini for AI enhancement/polishing via the SSE streaming API.
///
/// Streaming buys two things over the old generateContent call:
/// 1. Fail-fast fallback — an overloaded model that would previously eat the full
///    12 s request timeout is abandoned after `firstTokenTimeout` with no token.
/// 2. Partial output for the HUD (`onPartial`) so the user sees text growing
///    instead of a spinner. Injection still happens once, with the full text,
///    because the dojo correction table is a whole-text post-process.
final class GeminiPolishService {

    static let shared = GeminiPolishService()

    /// Tried in order — gemini-2.5-flash-lite regularly rejects requests with
    /// "experiencing high demand" spikes, which used to silently break polishing.
    /// Any failure moves to the next model before giving up.
    /// gemini-2.0-flash was retired 2026-07 (still listed by ListModels but
    /// rejects generate calls) — the tail model must be one that actually answers.
    /// All three verified to accept thinkingConfig.thinkingBudget = 0.
    private let modelChain = [
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-3.1-flash-lite",
    ]

    /// No first token within this window ⇒ the model is overloaded; skip to the
    /// next one immediately instead of waiting out a full request timeout.
    /// 6 s leaves headroom for peak-hour latency; thinking is disabled below so
    /// a healthy model answers well under this.
    private let firstTokenTimeout: TimeInterval = 6
    /// Hard ceiling for one attempt once streaming has started.
    private let overallTimeout: TimeInterval = 30

    // MARK: - Enhance
    /// `onPartial` receives the accumulated text so far, on the main thread.
    func enhance(
        text: String,
        mode: TranscriptionMode,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let apiKey = APIKeyStore.shared.geminiKey
        guard !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "InputSa", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API key not set. Please configure in Preferences."])))
            return
        }
        attempt(text: text, mode: mode, apiKey: apiKey, modelIndex: 0,
                onPartial: onPartial, completion: completion)
    }

    private func attempt(
        text: String,
        mode: TranscriptionMode,
        apiKey: String,
        modelIndex: Int,
        onPartial: ((String) -> Void)?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let model = modelChain[modelIndex]
        let retry: (Error) -> Void = { [weak self] err in
            guard let self = self, modelIndex + 1 < self.modelChain.count else {
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            NSLog("[InputSa] Gemini %@ failed (%@) — falling back to %@",
                  model, err.localizedDescription, self.modelChain[modelIndex + 1])
            self.attempt(text: text, mode: mode, apiKey: apiKey,
                         modelIndex: modelIndex + 1,
                         onPartial: onPartial, completion: completion)
        }

        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = overallTimeout

        let prompt = mode.systemPrompt(transcript: text)
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "temperature": 0.3,
                // Polishing needs no reasoning; without this, 2.5-flash "thinks"
                // for seconds before its first token and trips the fail-fast gate.
                "thinkingConfig": ["thinkingBudget": 0],
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        let stream = SSEStreamTask(
            modelName: model,
            firstTokenTimeout: firstTokenTimeout,
            onPartial: onPartial
        ) { result in
            switch result {
            case .success(let full):
                DispatchQueue.main.async { completion(.success(full)) }
            case .failure(let err):
                retry(err)
            }
        }
        stream.start(request)
    }

    // MARK: - Polish selected text (manual trigger)
    func polish(
        selectedText: String,
        mode: TranscriptionMode,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        enhance(text: selectedText, mode: mode, onPartial: onPartial, completion: completion)
    }
}

// MARK: - SSE streaming task

/// One streaming attempt against one model. URLSession retains its delegate
/// until invalidated, so this object stays alive for the duration of the
/// request without external ownership.
private final class SSEStreamTask: NSObject, URLSessionDataDelegate {

    private let modelName: String
    private let firstTokenTimeout: TimeInterval
    private let onPartial: ((String) -> Void)?
    private let onFinish: (Result<String, Error>) -> Void

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var lineBuffer = Data()
    private var accumulated = ""
    private var httpStatus = 200
    private var errorBody = Data()
    private var firstTokenTimer: DispatchSourceTimer?
    private var timedOutWaitingForFirstToken = false
    private var finished = false

    init(
        modelName: String,
        firstTokenTimeout: TimeInterval,
        onPartial: ((String) -> Void)?,
        onFinish: @escaping (Result<String, Error>) -> Void
    ) {
        self.modelName = modelName
        self.firstTokenTimeout = firstTokenTimeout
        self.onPartial = onPartial
        self.onFinish = onFinish
    }

    func start(_ request: URLRequest) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + firstTokenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.accumulated.isEmpty else { return }
            self.timedOutWaitingForFirstToken = true
            self.task?.cancel()   // completion arrives via didCompleteWithError
        }
        firstTokenTimer = timer
        timer.resume()

        task.resume()
    }

    private func cancelFirstTokenTimer() {
        firstTokenTimer?.cancel()
        firstTokenTimer = nil
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        cancelFirstTokenTimer()
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish(result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard httpStatus == 200 else {
            errorBody.append(data)
            return
        }
        lineBuffer.append(data)
        drainCompleteLines()
    }

    /// SSE frames from Gemini are `data: {json}\n` lines; parse every complete line.
    private func drainCompleteLines() {
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<idx)
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleSSELine(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private func handleSSELine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let jsonData = payload.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return }

        let chunk = parts.compactMap { $0["text"] as? String }.joined()
        guard !chunk.isEmpty else { return }
        if accumulated.isEmpty { cancelFirstTokenTimer() }
        accumulated += chunk

        if let onPartial = onPartial {
            let snapshot = accumulated
            DispatchQueue.main.async { onPartial(snapshot) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if timedOutWaitingForFirstToken {
                finish(.failure(NSError(domain: "InputSa", code: 14,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Gemini(\(modelName)): no token within \(Int(firstTokenTimeout))s — treated as overloaded"])))
            } else {
                finish(.failure(error))
            }
            return
        }

        if httpStatus != 200 {
            var message = "HTTP \(httpStatus)"
            if let json = try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                message = msg
            }
            // Self-heal: a rejected key means the in-memory cache may hold a
            // stale/garbled Keychain read — drop it so the next request re-reads.
            if message.contains("API key not valid") || message.contains("API_KEY_INVALID") {
                APIKeyStore.shared.invalidateGeminiKeyCache()
            }
            finish(.failure(NSError(domain: "InputSa", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Gemini(\(modelName)): \(message)"])))
            return
        }

        let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            finish(.failure(NSError(domain: "InputSa", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Gemini(\(modelName)): empty streaming response"])))
            return
        }
        finish(.success(clean))
    }
}
