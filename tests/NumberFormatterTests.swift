import Foundation

// Standalone test runner for TranscriptNumberFormatter.
// Compile together with the formatter source:
//   swiftc tests/NumberFormatterTests.swift \
//          InputSa/AIServices/TranscriptNumberFormatter.swift \
//          -o /tmp/nf_tests && /tmp/nf_tests
//
// Uses an @main entry point (not top-level code) because two source files are
// compiled together and neither is named main.swift.

var failures = 0
func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("  PASS: \(name)")
    } else {
        failures += 1
        print("  FAIL: \(name) \(detail)")
    }
}

func eq(_ input: String, _ expected: String, _ name: String) {
    let got = TranscriptNumberFormatter.format(input)
    check(got == expected, name, "input=\(input) expected=\(expected) got=\(got)")
}

@main
enum NumberFormatterTests {
static func main() {
print("百分之 → N%:")
eq("百分之三十五", "35%", "百分之三十五")
eq("百分之百", "100%", "百分之百")
eq("百分之零點五", "0.5%", "百分之零點五")
eq("百分之一百二十", "120%", "百分之一百二十")
eq("百分之二十", "20%", "百分之二十")
eq("百分之零", "0%", "百分之零")
eq("成長百分之三十五的營收", "成長35%的營收", "百分之 inside a sentence")

print("百分之 with decimal tail → N.d%:")
eq("百分之三十五點五", "35.5%", "百分之三十五點五")
eq("利率百分之二點五", "利率2.5%", "利率百分之二點五")
eq("百分之九十九點九九", "99.99%", "百分之九十九點九九")
eq("百分之五十點名時到場", "50%點名時到場", "點 followed by non-digit keeps 點名 intact")

print("colloquial 趴 → %:")
eq("三十五趴", "35%", "三十五趴")
eq("成長了三十五點五趴", "成長了35.5%", "中文數字+點+趴")
eq("百分之三十五點五趴", "35.5%", "百分之…趴 double marker swallows 趴")
eq("35.5趴", "35.5%", "阿拉伯小數+趴")
eq("漲了120趴", "漲了120%", "阿拉伯整數+趴")
eq("35%趴", "35%", "already-percent + redundant 趴")
eq("他趴著睡", "他趴著睡", "趴 as verb, no preceding number")
eq("三個人趴在地上", "三個人趴在地上", "number run not followed by 趴 unaffected")
eq("零趴", "0%", "零趴")

print("零點 → 0.x:")
eq("零點五", "0.5", "零點五")
eq("零點五三", "0.53", "零點五三")
eq("大約零點五公升", "大約0.5公升", "零點 inside a sentence")

print("misfire protection (must NOT change):")
eq("十分感謝", "十分感謝", "十分感謝")
eq("三思而後行", "三思而後行", "三思而後行")
eq("下午三點半", "下午三點半", "下午三點半")
eq("一個人", "一個人", "一個人")
eq("二話不說", "二話不說", "二話不說")
eq("兩點半開會", "兩點半開會", "兩點半 (time, not decimal)")
eq("三點鐘方向", "三點鐘方向", "三點 (not 零點)")

print("idempotence (format∘format == format):")
for s in ["百分之三十五", "百分之百", "百分之零點五", "零點五三",
          "百分之三十五點五", "百分之五十點名時到場",
          "成長了百分之三十五，大約三萬人", "十分感謝", "下午三點半", ""] {
    let once = TranscriptNumberFormatter.format(s)
    let twice = TranscriptNumberFormatter.format(once)
    check(once == twice, "idempotent: \(s.isEmpty ? "<empty>" : s)",
          "once=\(once) twice=\(twice)")
}

print("edge cases:")
eq("", "", "empty string")
eq("零點", "零點", "零點 with no digits following = passthrough")
eq("百分之", "百分之", "百分之 with no number following = passthrough")

print("mixed sentence (convert only the percentage):")
eq("成長了百分之三十五，大約三萬人", "成長了35%，大約三萬人",
   "百分之三十五 converts, 三萬人 stays")

print("parseChineseNumber positional value:")
check(TranscriptNumberFormatter.parseChineseNumber("三十五") == 35, "三十五 = 35")
check(TranscriptNumberFormatter.parseChineseNumber("一百二十") == 120, "一百二十 = 120")
check(TranscriptNumberFormatter.parseChineseNumber("三萬五千") == 35000, "三萬五千 = 35000")
check(TranscriptNumberFormatter.parseChineseNumber("百") == 100, "百 = 100")
check(TranscriptNumberFormatter.parseChineseNumber("兩") == 2, "兩 = 2")
check(TranscriptNumberFormatter.parseChineseNumber("十") == 10, "十 = 10")
check(TranscriptNumberFormatter.parseChineseNumber("零") == 0, "零 = 0")
check(TranscriptNumberFormatter.parseChineseNumber("蘋果") == nil, "non-number = nil")

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
}
}
