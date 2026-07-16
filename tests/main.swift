import Foundation

// Standalone test runner for DojoCorrectionTable.
// Compile together with InputSa/AIServices/DojoCorrectionTable.swift:
//   swiftc tests/DojoCorrectionTableTests.swift \
//          InputSa/AIServices/DojoCorrectionTable.swift -o /tmp/dojo_tests && /tmp/dojo_tests

var failures = 0
func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("  PASS: \(name)")
    } else {
        failures += 1
        print("  FAIL: \(name) \(detail)")
    }
}

let table = DojoCorrectionTable(entries: [
    DojoCorrectionTable.Entry(wrong: "改刀系統", correct: "道務系統", tier: "always"),
    DojoCorrectionTable.Entry(wrong: "金宮祖師", correct: "金公祖師", tier: "always"),
    DojoCorrectionTable.Entry(wrong: "半道",     correct: "辦道",     tier: "dojoOnly"),
    DojoCorrectionTable.Entry(wrong: "一貫到",   correct: "一貫道",   tier: "dojoOnly"),
])

print("dojoMode = false:")
let r1 = table.correct("我們用改刀系統", dojoMode: false)
check(r1 == "我們用道務系統", "always tier applies", "got \(r1)")

let r2 = table.correct("今天去半道", dojoMode: false)
check(r2 == "今天去半道", "dojoOnly does NOT apply when off", "got \(r2)")

print("dojoMode = true:")
let r3 = table.correct("今天去半道", dojoMode: true)
check(r3 == "今天去辦道", "dojoOnly 半道→辦道", "got \(r3)")

let r4 = table.correct("修一貫到", dojoMode: true)
check(r4 == "修一貫道", "dojoOnly 一貫到→一貫道", "got \(r4)")

print("longest-first ordering:")
let r5 = table.correct("拜金宮祖師", dojoMode: false)
check(r5 == "拜金公祖師", "金宮祖師→金公祖師 (long phrase wins)", "got \(r5)")

print("empty table fallback (parse failure simulation):")
let empty = DojoCorrectionTable(entries: [])
let r6 = empty.correct("改刀系統", dojoMode: true)
check(r6 == "改刀系統", "empty table = identity (no crash)", "got \(r6)")

print("phonetic (pinyin) homophone matching:")
let phoneticTable = DojoCorrectionTable(entries: [
    DojoCorrectionTable.Entry(wrong: "妙計大替", correct: "妙極大帝", tier: "always"),
])
let r7 = phoneticTable.correct("今天拜妙吉大帝", dojoMode: false)
check(r7 == "今天拜妙極大帝", "妙吉大帝→妙極大帝 (unseeded variant)", "got \(r7)")

let r8 = phoneticTable.correct("今天拜妙計大替", dojoMode: false)
check(r8 == "今天拜妙極大帝", "妙計大替→妙極大帝 (exact pass still wins)", "got \(r8)")

let r9 = phoneticTable.correct("今天拜妙急大帝", dojoMode: false)
check(r9 == "今天拜妙極大帝", "妙急大帝→妙極大帝 (unseeded variant)", "got \(r9)")

let r10 = phoneticTable.correct("今天拜妙極大帝", dojoMode: false)
check(r10 == "今天拜妙極大帝", "already-correct text is left untouched", "got \(r10)")

print("phonetic=false opt-out:")
let noPhonetic = DojoCorrectionTable(entries: [
    DojoCorrectionTable.Entry(wrong: "妙計大替", correct: "妙極大帝", tier: "always", phonetic: false),
])
let r11 = noPhonetic.correct("今天拜妙吉大帝", dojoMode: false)
check(r11 == "今天拜妙吉大帝", "phonetic:false skips pass 2", "got \(r11)")

print("{num} wildcard:")
let numTable = DojoCorrectionTable(entries: [
    DojoCorrectionTable.Entry(wrong: "{num}粒", correct: "{num}例", tier: "always", phonetic: false),
])
let n1 = numTable.correct("2粒樣品和10粒對照", dojoMode: false)
check(n1 == "2例樣品和10例對照", "{num} matches Arabic digit runs", "got \(n1)")

let n2 = numTable.correct("兩粒樣品", dojoMode: false)
check(n2 == "兩例樣品", "{num} matches Chinese numerals", "got \(n2)")

// Bad rule: pattern has {num} but replacement doesn't → treated as literal no-op,
// must NOT touch any numbers.
let badNumTable = DojoCorrectionTable(entries: [
    DojoCorrectionTable.Entry(wrong: "{num}粒", correct: "例", tier: "always", phonetic: false),
])
let n3 = badNumTable.correct("2粒樣品", dojoMode: false)
check(n3 == "2粒樣品", "malformed {num} rule (no {num} in correct) is a no-op", "got \(n3)")

// Existing non-{num} literal entry behaviour is unchanged alongside {num} rules.
let mixedNumTable = DojoCorrectionTable(entries: [
    DojoCorrectionTable.Entry(wrong: "{num}粒", correct: "{num}例", tier: "always", phonetic: false),
    DojoCorrectionTable.Entry(wrong: "改刀系統", correct: "道務系統", tier: "always"),
])
let n4 = mixedNumTable.correct("改刀系統有3粒", dojoMode: false)
check(n4 == "道務系統有3例", "{num} and literal entries coexist", "got \(n4)")

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
