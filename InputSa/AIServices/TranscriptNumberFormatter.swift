import Foundation

/// Deterministic number-formatting layer for transcription output.
///
/// This is the belt-and-suspenders companion to the polish prompt's number
/// rules (see `TranscriptionMode`): the Apple on-device 3B model runs those
/// prompt rules unreliably, and when polish fails entirely we inject the raw
/// transcript — so a small, *high-confidence* deterministic pass guarantees the
/// most common spoken-number forms come out as digits regardless.
///
/// Design stance: **rather miss than misfire.** Only two very safe patterns are
/// converted — 「百分之…」 percentages and 「零點…」 decimals — both of which have
/// an unambiguous leading marker (`百分之` / `零點`) that never appears in the
/// mis-fire cases we care about (十分, 三思, 三點半, 一個人, 二話…). General
/// 「中文數字＋單位」 conversion, thousands separators, and CJK/alphanumeric
/// spacing are deliberately left to the prompt layer — the misfire risk of doing
/// them deterministically is too high.
///
/// Idempotent by construction: every conversion emits Arabic digits with no
/// leading `百分之`/`零點` marker, so a second pass finds nothing to change.
/// (Polish output is run through this layer a second time after the dojo
/// correction pass, so `format(format(x)) == format(x)` must hold.)
enum TranscriptNumberFormatter {

    // MARK: - Character tables

    private static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let bigUnits:   [Character: Int] = ["萬": 10000, "億": 100000000]

    private static func isNumberChar(_ c: Character) -> Bool {
        digits[c] != nil || smallUnits[c] != nil || bigUnits[c] != nil
    }

    // MARK: - Public API

    /// Convert the two safe spoken-number patterns to Arabic form. Everything
    /// else is passed through unchanged.
    static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let chars = Array(text)
        let n = chars.count
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < n {
            // 「百分之…」 → N%  (handles a following 「零點…」 decimal too)
            if matches(chars, at: i, "百分之"),
               let (value, consumed) = parsePercentValue(chars, from: i + 3) {
                out += value + "%"
                i += 3 + consumed
                // Colloquial double marker: 百分之三十五點五趴 — swallow the
                // redundant 趴 so the % doesn't end up followed by it.
                if i < n, chars[i] == "趴" { i += 1 }
                continue
            }
            // Colloquial percent suffix: 「三十五趴」→ 35%, 「35.5趴」→ 35.5%.
            // 趴 as a verb (趴著/趴下) never follows a number run, so requiring
            // the run + immediate 趴 keeps this safe (十分感謝/三個人 untouched:
            // their next char is not 趴).
            if let (value, consumed) = parseNumberRun(chars, from: i),
               i + consumed < n, chars[i + consumed] == "趴" {
                out += value + "%"
                i += consumed + 1
                continue
            }
            // 「零點…」 → 0.x  (only 零點-prefixed; 三點半 / 兩點 are never touched)
            if matches(chars, at: i, "零點") {
                let (decimals, consumed) = parseDecimalDigits(chars, from: i + 2)
                if consumed > 0 {
                    out += "0." + decimals
                    i += 2 + consumed
                    continue
                }
            }
            // Cleanup: an already-Arabic percent followed by the colloquial
            // marker (「35%趴」) drops the redundant 趴.
            if chars[i] == "%", i + 1 < n, chars[i + 1] == "趴" {
                out.append("%")
                i += 2
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Number run for the 「N趴」 percent rule: either an Arabic run with an
    /// optional decimal part (35 / 35.5) or a Chinese numeral run with an
    /// optional 點-decimal tail (三十五 / 三十五點五 — via `parsePercentValue`).
    /// Returns nil unless the run starts right at `start`.
    private static func parseNumberRun(_ chars: [Character], from start: Int)
        -> (value: String, consumed: Int)? {
        let n = chars.count
        guard start < n else { return nil }
        if chars[start].isASCII, chars[start].isNumber {
            var j = start
            while j < n, chars[j].isASCII, chars[j].isNumber { j += 1 }
            var end = j
            if j < n, chars[j] == "." {
                var k = j + 1
                while k < n, chars[k].isASCII, chars[k].isNumber { k += 1 }
                if k > j + 1 { end = k }
            }
            return (String(chars[start..<end]), end - start)
        }
        if isNumberChar(chars[start]) || chars[start] == "零" {
            return parsePercentValue(chars, from: start)
        }
        return nil
    }

    /// Positional-value parser for Chinese integers
    /// (零一二兩三四五六七八九十百千萬億). Returns nil on any unrecognised
    /// character so the caller can keep the original text verbatim.
    /// Examples: 三十五 → 35, 一百二十 → 120, 三萬五千 → 35000, 百 → 100.
    static func parseChineseNumber(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        var total = 0        // completed 萬/億 sections
        var section = 0      // current section below 萬
        var current = 0      // pending unit-less digit
        var pendingDigit = false
        var sawAny = false

        for ch in s {
            if let d = digits[ch] {
                current = d
                pendingDigit = true
                sawAny = true
            } else if let u = smallUnits[ch] {
                // A bare unit means one of it: 十 → 10, 百 → 100.
                let base = pendingDigit ? current : 1
                section += base * u
                current = 0
                pendingDigit = false
                sawAny = true
            } else if let b = bigUnits[ch] {
                section += current
                if section == 0 { section = 1 }   // 萬 / 億 with no leading digits
                total += section * b
                section = 0
                current = 0
                pendingDigit = false
                sawAny = true
            } else {
                return nil
            }
        }
        guard sawAny else { return nil }
        return total + section + current
    }

    // MARK: - Sub-parsers

    /// Value that follows 「百分之」: either a 「零點…」 decimal or an integer.
    /// Returns the Arabic string plus how many characters were consumed.
    private static func parsePercentValue(_ chars: [Character], from start: Int)
        -> (value: String, consumed: Int)? {
        let n = chars.count
        guard start < n else { return nil }

        // Decimal sub-case: 百分之零點五 → 0.5
        if matches(chars, at: start, "零點") {
            let (decimals, consumed) = parseDecimalDigits(chars, from: start + 2)
            if consumed > 0 { return ("0." + decimals, 2 + consumed) }
        }

        // Integer sub-case: greedily consume the number-character run.
        // (In real text 百分之 is always immediately followed by a number.)
        var j = start
        while j < n && isNumberChar(chars[j]) { j += 1 }
        guard j > start, let value = parseChineseNumber(String(chars[start..<j]))
        else { return nil }

        // Decimal tail: 百分之三十五點五 → 35.5%. Only a 「點」 followed by bare
        // digits counts — 「百分之五十點名」 keeps 點名 intact and converts the
        // integer alone. Without this, the % would land mid-number (35%點五).
        if j < n, chars[j] == "點" {
            let (decimals, consumed) = parseDecimalDigits(chars, from: j + 1)
            if consumed > 0 {
                return ("\(value)." + decimals, (j - start) + 1 + consumed)
            }
        }
        return (String(value), j - start)
    }

    /// Digit-by-digit run after a decimal point (零點五三 → "53"). Consumes only
    /// bare single digits — a unit character (十百千) stops it, so a malformed
    /// 「零點十…」 converts nothing and the text passes through untouched.
    private static func parseDecimalDigits(_ chars: [Character], from start: Int)
        -> (digits: String, consumed: Int) {
        var result = ""
        var j = start
        while j < chars.count, let d = digits[chars[j]] {
            result += String(d)
            j += 1
        }
        return (result, j - start)
    }

    /// True when `needle` occurs in `chars` starting at `index`.
    private static func matches(_ chars: [Character], at index: Int, _ needle: String) -> Bool {
        let needleChars = Array(needle)
        guard index + needleChars.count <= chars.count else { return false }
        for (offset, nc) in needleChars.enumerated() where chars[index + offset] != nc {
            return false
        }
        return true
    }
}
