import Foundation

// Compile: swiftc tests/SelectionTranslateTests.swift \
//            InputSa/AIServices/SelectionTranslateDirection.swift -o /tmp/seltrans_tests
// Run:     /tmp/seltrans_tests

var passed = 0, failed = 0
func check(_ label: String, _ cond: Bool) {
    if cond { passed += 1; print("  PASS: \(label)") }
    else    { failed += 1; print("  FAIL: \(label)") }
}

func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

@main
struct SelectionTranslateTests {
    static func main() {
        // MARK: cjkRatio
        check("pure Chinese ratio = 1.0", approx(SelectionTranslateDirection.cjkRatio("今天天氣很好"), 1.0))
        check("pure English ratio = 0.0", approx(SelectionTranslateDirection.cjkRatio("Hello world"), 0.0))
        check("empty string ratio = 0.0", approx(SelectionTranslateDirection.cjkRatio(""), 0.0))
        check("punctuation/digits ignored (all Chinese letters)",
              approx(SelectionTranslateDirection.cjkRatio("價格 5,000 元！"), 1.0))
        // "AI 人工智慧": 2 latin letters + 4 Han = 6 letters, 4/6 ≈ 0.667
        check("mixed AI 人工智慧 ≈ 0.667",
              approx(SelectionTranslateDirection.cjkRatio("AI 人工智慧"), 0.6667))

        // MARK: targetLanguage — direction
        check("Chinese → preferred foreign (英文)",
              SelectionTranslateDirection.targetLanguage(for: "今天天氣很好", preferredForeign: "英文") == "英文")
        check("Chinese → preferred foreign (泰文)",
              SelectionTranslateDirection.targetLanguage(for: "今天天氣很好", preferredForeign: "泰文") == "泰文")
        check("English → 繁體中文",
              SelectionTranslateDirection.targetLanguage(for: "Hello, how are you?", preferredForeign: "英文") == "繁體中文")
        check("Thai → 繁體中文",
              SelectionTranslateDirection.targetLanguage(for: "สวัสดีครับ", preferredForeign: "英文") == "繁體中文")
        check("empty → 繁體中文",
              SelectionTranslateDirection.targetLanguage(for: "", preferredForeign: "英文") == "繁體中文")

        // MARK: threshold — 30%
        // 3 Han + 8 latin = 11 letters, 3/11 ≈ 0.27 < 0.30 → treated as foreign → 中文
        check("mostly-English mix (<30% CJK) → 繁體中文",
              SelectionTranslateDirection.targetLanguage(for: "使用來 debugging tool", preferredForeign: "英文") == "繁體中文")

        // MARK: isChineseToForeign (toggle visibility)
        check("Chinese isChineseToForeign = true",
              SelectionTranslateDirection.isChineseToForeign("今天天氣很好"))
        check("English isChineseToForeign = false",
              !SelectionTranslateDirection.isChineseToForeign("Hello world"))

        print("")
        if failed == 0 { print("ALL TESTS PASSED (\(passed))") }
        else { print("\(failed) TEST(S) FAILED (\(passed) passed)"); exit(1) }
    }
}
