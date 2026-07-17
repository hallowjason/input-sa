import Foundation

/// Pure language-direction logic for 劃詞翻譯 (select-and-translate).
///
/// Kept dependency-free (Foundation only) so it can be unit-tested in isolation
/// without pulling in AppKit or the rest of InputController. The UserDefaults
/// read for the preferred foreign language happens at the call site and is
/// passed in as `preferredForeign`, so this function stays deterministic.
enum SelectionTranslateDirection {

    /// Fraction of `text`'s letters/ideographs that are CJK (Han) characters,
    /// in 0...1. Whitespace, punctuation, digits and symbols are ignored so a
    /// short Chinese phrase with lots of punctuation still reads as CJK-dominant.
    /// Empty / letter-less input returns 0 (treated as non-CJK → translate to 中文).
    static func cjkRatio(_ text: String) -> Double {
        var cjk = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if isCJKIdeograph(scalar) {
                cjk += 1
                letters += 1
            } else if isLetter(scalar) {
                letters += 1
            }
        }
        guard letters > 0 else { return 0 }
        return Double(cjk) / Double(letters)
    }

    /// Decide the translation target for the selected text.
    /// - CJK ratio < 0.30  ⇒ the text is foreign (English/Thai/…) → translate to 繁體中文.
    /// - otherwise         ⇒ the text is Chinese → translate to `preferredForeign`.
    static func targetLanguage(for text: String, preferredForeign: String) -> String {
        cjkRatio(text) < 0.30 ? "繁體中文" : preferredForeign
    }

    /// True when the chosen direction is Chinese → foreign, i.e. the foreign-
    /// language toggle (英/泰) is meaningful. False for the foreign → 中文
    /// direction, where the target is fixed and the toggle should hide.
    static func isChineseToForeign(_ text: String) -> Bool {
        cjkRatio(text) >= 0.30
    }

    // MARK: - Scalar classification

    private static func isCJKIdeograph(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(v)   // Extension A
            || (0x20000...0x2A6DF).contains(v) // Extension B
            || (0xF900...0xFAFF).contains(v)   // Compatibility Ideographs
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        // Alphabetic covers Latin, Thai, Hangul, Kana, Han, etc. Excludes digits,
        // punctuation and whitespace so the ratio measures script, not volume.
        s.properties.isAlphabetic
    }
}
