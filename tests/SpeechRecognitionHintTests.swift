import Foundation

@main
struct SpeechRecognitionHintTests {
    static func main() {
        var failed = 0
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failed += 1; print("FAIL: \(label)") }
        }
        let local = SpeechRecognitionHints.whisperPrompt(vocabulary: [])
        let groq = SpeechRecognitionHints.groqPrompt(vocabulary: ["自訂名詞"])
        let google = SpeechRecognitionHints.googleSpeechContexts(vocabulary: ["自訂名詞"])
        check(local.contains("Codex") && local.contains("Claude"), "local Whisper is missing the reported proper-name spellings")
        check(groq.contains("Codex") && groq.contains("Claude") && groq.contains("自訂名詞"), "Groq must receive spellings and the user's vocabulary")
        let phrases = google.first?["phrases"] as? [String] ?? []
        check(phrases.contains("Codex") && phrases.contains("Claude") && phrases.contains("自訂名詞"), "Google must receive request-side phrase hints")
        check(google.first?["boost"] == nil && google.first?["transcriptNormalization"] == nil,
              "phrase hints must not add strong boosting or output replacements")
        let table = DojoCorrectionTable(entries: [
            .init(wrong: "cloud", correct: "Claude"),
            .init(wrong: "code", correct: "Codex"),
            .init(wrong: "wrong spelling", correct: "MyProduct"),
        ])
        let terms = table.preferredTerms(for: "")
        let referenced = SpeechRecognitionHints.googleSpeechContexts(vocabulary: terms).first?["phrases"] as? [String] ?? []
        check(referenced.contains("MyProduct"), "personal correct spelling reaches recognition context")
        check(!referenced.contains("cloud") && !referenced.contains("code") && !referenced.contains("wrong spelling"),
              "legacy wrong forms never become an acoustic replacement instruction")
        let duplicates = SpeechRecognitionHints.googleSpeechContexts(vocabulary: ["codex", " CLAUDE ", "Codex"]).first?["phrases"] as? [String] ?? []
        check(duplicates == ["Codex", "Claude"], "case-insensitive duplicates retain canonical spelling")

        let longName = String(repeating: "LongName", count: 40)
        let unsafe = [longName, "bad\nline", "{num}個", "正常名詞", "C++", "Example.co", "Ångström"]
        let filtered = SpeechRecognitionHints.googleSpeechContexts(vocabulary: unsafe).first?["phrases"] as? [String] ?? []
        check(!filtered.contains(longName) && !filtered.contains("bad\nline") && !filtered.contains("{num}個"),
              "overlong names, multiline prose and templates are omitted whole")
        check(filtered.contains("正常名詞") && filtered.contains("C++") && filtered.contains("Example.co"),
              "literal mixed-script names and useful spelling punctuation survive")
        let crowded = (0..<200).map { "候選名稱\($0)" }
        let bounded = SpeechRecognitionHints.whisperPrompt(vocabulary: crowded)
        check(bounded.utf8.count <= SpeechRecognitionHints.maximumPromptBytes, "UTF-8 bound holds for Chinese terms")
        check(bounded.contains("Codex") && bounded.contains("Claude"), "names remain available even with a crowded vocabulary")
        let selected = SpeechRecognitionHints.googleSpeechContexts(vocabulary: crowded).first?["phrases"] as? [String] ?? []
        check(selected.count <= 20 && selected.allSatisfy({ ["Codex", "Claude"].contains($0) || crowded.contains($0) }),
              "only complete original terms are selected, never cut-up names")
        check(SpeechRecognitionHints.groqPrompt(vocabulary: crowded) == bounded, "local and cloud Whisper share spelling hints")
        print("\(checks - failed)/\(checks) speech recognition hint checks passed")
        if failed > 0 { exit(1) }
    }
}
