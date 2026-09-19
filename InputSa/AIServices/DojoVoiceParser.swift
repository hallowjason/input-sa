import Foundation

/// Shared parser for voice-added vocabulary: takes the
/// transcript of a spoken clarification (「陳怡君的怡是怡然的怡…」), asks
/// Gemini to reconstruct the intended term, and returns a ready-to-save
/// `DojoCorrectionTable.Entry`. Used by both entry points — the global
/// right-Shift PTT and the microphone button on the Preferences dojo tab.
enum DojoVoiceParser {

    private struct Parsed: Codable {
        let correct: String
        let wrong: String
    }

    /// Completion fires on the main thread (GeminiPolishService already
    /// dispatches its completion there).
    static func parse(transcript: String,
                      completion: @escaping (Result<DojoCorrectionTable.Entry, Error>) -> Void) {
        GeminiPolishService.shared.enhance(text: transcript, mode: .dojoEntryParse) { result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let raw):
                guard let parsed = decode(raw),
                      !parsed.correct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    completion(.failure(NSError(domain: "InputSa", code: 20, userInfo: [
                        NSLocalizedDescriptionKey: "無法從這段話解析出詞條（模型回傳：\(String(raw.prefix(60)))）",
                    ])))
                    return
                }
                let correct = parsed.correct.trimmingCharacters(in: .whitespacesAndNewlines)
                var wrong = parsed.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
                // Preserve the existing file/editor convention when no common
                // mishearing was supplied. Entries are AI references only.
                if wrong.isEmpty { wrong = correct }
                completion(.success(DojoCorrectionTable.Entry(
                    wrong: wrong, correct: correct, tier: "always", phonetic: false)))
            }
        }
    }

    /// The model is told "no code fences," but defend anyway — fenced or
    /// prefixed output is the most common way this parse would break.
    private static func decode(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fall back to the first {...} span if the model added prose around it.
        if !text.hasPrefix("{"), let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Parsed.self, from: data)
    }
}
