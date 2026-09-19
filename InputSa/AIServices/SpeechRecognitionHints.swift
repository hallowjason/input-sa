import Foundation

/// Request-side recognition hints only. These functions never edit a transcript.
enum SpeechRecognitionHints {
    // A small spelling reference for the names reported by users. This is not a
    // cloud/code → Claude/Codex replacement table and never examines output text.
    static let builtInTerms = ["Codex", "Claude"]
    // Whisper's API limit is 224 tokens. A 224-byte UTF-8 budget is deliberately
    // more conservative and bounds even mixed-script or uncommon-name prompts.
    static let maximumPromptBytes = 224
    private static let prefix = "繁體中文與英文口述。專有名詞："

    static func whisperPrompt(vocabulary: [String]) -> String {
        prefix + terms(vocabulary: vocabulary).joined(separator: "、") + "。"
    }

    static func groqPrompt(vocabulary: [String]) -> String {
        whisperPrompt(vocabulary: vocabulary)
    }

    static func googleSpeechContexts(vocabulary: [String]) -> [[String: Any]] {
        // Use phrase hints, never transcriptNormalization search/replace. Omit
        // boost until audio evaluation supports it: stronger bias risks false positives.
        [["phrases": terms(vocabulary: vocabulary)]]
    }

    /// Keep the existing AI reference budget and personal/mentioned-term order.
    /// Reserve only two slots for shared spelling context; never infer a mapping
    /// from a homophone or an already valid word such as cloud or code.
    static func polishTerms(vocabulary: [String]) -> [String] {
        var seen = Set(builtInTerms.map { $0.lowercased() })
        var selected: [String] = []
        var remaining = 800 - builtInTerms.joined(separator: "、").count - 1
        for raw in vocabulary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 64, !seen.contains(term.lowercased()) else { continue }
            let cost = term.count + (selected.isEmpty ? 0 : 1)
            guard cost <= remaining else { continue }
            seen.insert(term.lowercased())
            selected.append(term)
            remaining -= cost
            if selected.count == 80 - builtInTerms.count { break }
        }
        return selected + builtInTerms
    }

    private static func terms(vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var selected: [String] = []
        var remaining = maximumPromptBytes - prefix.utf8.count - "。".utf8.count
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " .+#&/_'-"))
        for raw in builtInTerms + vocabulary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep full literal terms. Multiline entries, placeholders, and
            // overlong prose are not useful spelling hints; leave their storage alone.
            guard !term.isEmpty, term.count <= 64,
                  term.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  term.contains(where: { $0.isLetter || $0.isNumber }),
                  !seen.contains(term.lowercased()) else { continue }
            let cost = term.utf8.count + (selected.isEmpty ? 0 : "、".utf8.count)
            guard cost <= remaining else { continue }
            seen.insert(term.lowercased())
            selected.append(term)
            remaining -= cost
            if selected.count == 20 { break }
        }
        return selected
    }
}
