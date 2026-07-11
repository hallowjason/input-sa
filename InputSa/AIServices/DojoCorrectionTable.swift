import CoreFoundation
import Foundation

/// Dojo (道場) homophone correction table applied after OpenCC conversion.
///
/// Local Paraformer transcription often mishears dojo-specific terminology
/// (e.g. 「金公祖師」→「金宮祖師」). This table fixes those known mistakes in
/// two passes:
///   1. Exact string replacement (straight `wrong` → `correct`), ordered
///      longest-`wrong`-first so that longer phrases win before their
///      substrings can be touched.
///   2. Phonetic (pinyin) homophone matching against each `correct` term —
///      Paraformer's mishearings of a given phrase are numerous and
///      unpredictable (妙吉大帝／妙計大替／妙急大帝…), so pass 2 slides a
///      window the same character-length as `correct` across the text and
///      replaces it whenever the window is phonetically identical (same
///      pinyin, tones stripped) but not already the correct characters.
///
/// Load strategy (built for a future editing UI):
///   1. Prefer `~/Library/Application Support/InputSa/dojo_corrections.json`.
///   2. If absent, copy the bundled seed (`Resources/dojo/dojo_corrections.json`)
///      into Application Support (creating the directory), then read that copy.
/// The user therefore edits the Application Support copy — changes take effect on
/// the next `reload()` without reinstalling the app.
///
/// Parse failures fall back to an empty table (no correction, never a crash):
/// transcription must keep working even if the file is missing or malformed.
final class DojoCorrectionTable {

    /// A single correction rule.
    struct Entry: Codable {
        let wrong: String
        let correct: String
        let tier: String     // "always" | "dojoOnly"
        let phonetic: Bool   // apply pass-2 pinyin homophone matching against `correct`

        enum CodingKeys: String, CodingKey {
            case wrong, correct, tier, phonetic
        }

        init(wrong: String, correct: String, tier: String, phonetic: Bool = true) {
            self.wrong = wrong
            self.correct = correct
            self.tier = tier
            self.phonetic = phonetic
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wrong = try c.decode(String.self, forKey: .wrong)
            correct = try c.decode(String.self, forKey: .correct)
            tier = try c.decode(String.self, forKey: .tier)
            // Absent in existing seed entries — defaults to on (opt-out, not opt-in).
            phonetic = try c.decodeIfPresent(Bool.self, forKey: .phonetic) ?? true
        }
    }

    private static let alwaysTier = "always"
    private static let dojoOnlyTier = "dojoOnly"

    /// Entries sorted by `wrong` length, longest first (substring-safe ordering).
    private var entries: [Entry]

    static let shared = DojoCorrectionTable()

    // MARK: - Init

    /// Designated initializer. Entries are stored longest-`wrong`-first.
    init(entries: [Entry]) {
        self.entries = Self.sortedLongestFirst(entries)
    }

    /// Production initializer — loads from Application Support (seeding from the
    /// bundle on first run). Falls back to an empty table on any failure.
    convenience init() {
        self.init(entries: Self.loadEntries())
    }

    // MARK: - Correction

    /// Apply all applicable corrections to `text`.
    ///
    /// - Parameter dojoMode: when `true`, `dojoOnly` entries are also applied;
    ///   when `false`, only `always` entries apply.
    func correct(_ text: String, dojoMode: Bool) -> String {
        var result = text
        for entry in entries where Self.isActive(entry, dojoMode: dojoMode) {
            result = result.replacingOccurrences(of: entry.wrong, with: entry.correct)
        }
        for entry in entries where Self.isActive(entry, dojoMode: dojoMode) && entry.phonetic {
            result = Self.phoneticReplace(result, correct: entry.correct)
        }
        return result
    }

    /// Reload entries from disk (for a future "apply edits now" UI action).
    func reload() {
        entries = Self.loadEntries()
    }

    /// Current entries, longest-`wrong`-first — read-only snapshot for a management UI.
    var allEntries: [Entry] { entries }

    /// Replace the entire table: write `newEntries` to the Application Support
    /// copy (creating it if absent) and apply them in-memory immediately.
    /// Returns `false` on write failure (e.g. no Application Support directory),
    /// in which case the in-memory table is left unchanged.
    @discardableResult
    func save(_ newEntries: [Entry]) -> Bool {
        guard let supportURL = Self.applicationSupportURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: supportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(CorrectionFile(entries: newEntries))
            try data.write(to: supportURL, options: .atomic)
        } catch {
            NSLog("[InputSa] DojoCorrectionTable: save failed — \(error)")
            return false
        }
        entries = Self.sortedLongestFirst(newEntries)
        return true
    }

    // MARK: - Helpers

    private static func isActive(_ entry: Entry, dojoMode: Bool) -> Bool {
        switch entry.tier {
        case alwaysTier:   return true
        case dojoOnlyTier: return dojoMode
        default:           return false
        }
    }

    private static func sortedLongestFirst(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.wrong.count > $1.wrong.count }
    }

    // MARK: - Pass 2: phonetic (pinyin) homophone matching

    /// Toneless, space-stripped pinyin for `s`, used purely as a comparison key.
    /// Only ever compared to another key produced by this same function, so
    /// its exact character set does not matter as long as it is consistent.
    private static func pinyinKey(_ s: String) -> String {
        let mutable = NSMutableString(string: s)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().filter { !$0.isWhitespace }
    }

    /// Slide a window the same character-length as `correct` across `text`,
    /// replacing any window that is phonetically identical to `correct` but
    /// not already those exact characters. Only ever compares against the
    /// `correct` whitelist (never `wrong`), so it cannot generalize into
    /// mis-correcting unrelated homophones.
    private static func phoneticReplace(_ text: String, correct: String) -> String {
        let correctKey = pinyinKey(correct)
        guard !correctKey.isEmpty else { return text }

        let chars = Array(text)
        let n = correct.count
        guard chars.count >= n else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if i + n <= chars.count {
                let window = String(chars[i..<(i + n)])
                if window != correct && pinyinKey(window) == correctKey {
                    result += correct
                    i += n
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    // MARK: - Loading

    private struct CorrectionFile: Codable {
        let entries: [Entry]
    }

    /// Application Support copy the user edits.
    private static var applicationSupportURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("InputSa", isDirectory: true)
            .appendingPathComponent("dojo_corrections.json")
    }

    /// Bundled seed shipped inside the app.
    private static var bundledSeedURL: URL? {
        Bundle.main.url(forResource: "dojo_corrections", withExtension: "json", subdirectory: "dojo")
            ?? Bundle.main.url(forResource: "dojo_corrections", withExtension: "json")
    }

    /// Resolve the active file, seeding Application Support from the bundle if needed,
    /// then decode it. Returns `[]` on any failure.
    private static func loadEntries() -> [Entry] {
        let fm = FileManager.default

        guard let supportURL = applicationSupportURL else {
            // No Application Support — fall back to reading the bundle directly.
            return decodeEntries(at: bundledSeedURL)
        }

        if !fm.fileExists(atPath: supportURL.path) {
            seedApplicationSupport(to: supportURL)
        }

        if fm.fileExists(atPath: supportURL.path) {
            return decodeEntries(at: supportURL)
        }
        // Seeding failed (e.g. no bundle resource) — last resort: read the bundle.
        return decodeEntries(at: bundledSeedURL)
    }

    /// Copy the bundled seed into Application Support, creating the directory.
    private static func seedApplicationSupport(to supportURL: URL) {
        let fm = FileManager.default
        guard let seedURL = bundledSeedURL else {
            NSLog("[InputSa] DojoCorrectionTable: bundled seed not found — corrections disabled")
            return
        }
        do {
            try fm.createDirectory(
                at: supportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: seedURL, to: supportURL)
            NSLog("[InputSa] DojoCorrectionTable: seeded %@", supportURL.path)
        } catch {
            NSLog("[InputSa] DojoCorrectionTable: seed copy failed — \(error)")
        }
    }

    private static func decodeEntries(at url: URL?) -> [Entry] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CorrectionFile.self, from: data)
        else {
            NSLog("[InputSa] DojoCorrectionTable: load/parse failed — empty table (no correction)")
            return []
        }
        return decoded.entries
    }
}
