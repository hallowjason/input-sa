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

    // Two independent sources, kept separate so the editor can never write shared
    // entries back into the personal file (see `personalEntries` / `save`):
    //   • `_personal` — the user's own dojo_corrections.json (editable)
    //   • `_shared`   — the community-synced dojo_shared.json (read-only cache)
    // `entries` is their merge (personal wins on collision), sorted longest-first,
    // and is the *only* table `correct()` consults.
    private var _personal: [Entry]
    private var _shared: [Entry]
    /// Effective correction table: merged personal + shared, longest-`wrong`-first.
    private var entries: [Entry]

    /// The user's own entries — the source the Preferences editor reads and writes.
    /// Never includes shared entries, so saving the editor's list back can't
    /// pollute the personal file with community entries.
    var personalEntries: [Entry] { _personal }

    /// Community-synced entries — read-only, shown in the UI but not editable
    /// (to override one, the user adds a personal entry with the same `wrong`).
    var sharedEntries: [Entry] { _shared }

    static let shared = DojoCorrectionTable()

    // MARK: - Init

    /// Designated initializer.
    init(personal: [Entry], shared: [Entry]) {
        self._personal = personal
        self._shared = shared
        self.entries = Self.mergeAndSort(personal: personal, shared: shared)
    }

    /// Personal-only convenience (used by unit tests): no shared source.
    convenience init(entries: [Entry]) {
        self.init(personal: entries, shared: [])
    }

    /// Production initializer — loads the personal file (seeding from the bundle
    /// on first run) plus the shared cache. Falls back to empty on any failure.
    convenience init() {
        self.init(personal: Self.loadPersonalEntries(), shared: Self.loadSharedEntries())
    }

    // MARK: - Correction

    /// Apply all applicable corrections to `text`.
    ///
    /// - Parameter dojoMode: when `true`, `dojoOnly` entries are also applied;
    ///   when `false`, only `always` entries apply.
    func correct(_ text: String, dojoMode: Bool) -> String {
        var result = text
        for entry in entries where Self.isActive(entry, dojoMode: dojoMode) {
            if Self.hasNumToken(entry) {
                // `{num}` wildcard entry (e.g. wrong="{num}粒", correct="{num}例"):
                // matches a run of digits and substitutes it verbatim. Malformed
                // wildcards return the text unchanged (never crash).
                result = Self.numWildcardReplace(result, wrong: entry.wrong, correct: entry.correct)
            } else {
                result = result.replacingOccurrences(of: entry.wrong, with: entry.correct)
            }
        }
        for entry in entries
        where Self.isActive(entry, dojoMode: dojoMode) && entry.phonetic && !Self.hasNumToken(entry) {
            // Phonetic (pinyin) matching is meaningless for a wildcard whose
            // `correct` still contains the literal `{num}` token — skip it.
            result = Self.phoneticReplace(result, correct: entry.correct)
        }
        return result
    }

    /// Reload both sources from disk. Called after an in-app edit or after
    /// `DojoSharedSync` refreshes the shared cache.
    func reload() {
        _personal = Self.loadPersonalEntries()
        _shared = Self.loadSharedEntries()
        entries = Self.mergeAndSort(personal: _personal, shared: _shared)
    }

    /// Replace the *personal* table: write `newEntries` to the Application Support
    /// copy (creating it if absent) and re-merge in-memory immediately. Only ever
    /// writes the personal file — shared entries are never persisted here.
    /// Returns `false` on write failure, in which case the in-memory table is
    /// left unchanged.
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
        _personal = newEntries
        entries = Self.mergeAndSort(personal: _personal, shared: _shared)
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

    /// Merge personal + shared into the effective table. Personal wins: a shared
    /// entry is dropped when its dedup key already exists in personal, so a user's
    /// own entry always overrides a colliding community one. Result is
    /// longest-`wrong`-first (substring-safe ordering) for `correct()`.
    private static func mergeAndSort(personal: [Entry], shared: [Entry]) -> [Entry] {
        let personalKeys = Set(personal.map(dedupKey))
        var merged = personal
        for entry in shared where !personalKeys.contains(dedupKey(entry)) {
            merged.append(entry)
        }
        return sortedLongestFirst(merged)
    }

    /// Dedup key: a non-empty `wrong` (distinct from `correct`) keys on the
    /// misheard form; otherwise (empty, or the wrong==correct "no mishearing"
    /// convention) keys on `correct`. This collapses the two ways the same
    /// correct term can be stored so personal correctly shadows shared.
    private static func dedupKey(_ e: Entry) -> String {
        (e.wrong.isEmpty || e.wrong == e.correct) ? "c:\(e.correct)" : "w:\(e.wrong)"
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

    // MARK: - {num} wildcard replacement

    private static let numToken = "{num}"

    /// Characters `{num}` matches: ASCII digits plus common Chinese numerals.
    private static let numChars: Set<Character> = Set("0123456789零〇一二两兩三四五六七八九十百千万萬亿億几幾")

    /// An entry uses the wildcard machinery when its `wrong` mentions `{num}`.
    private static func hasNumToken(_ e: Entry) -> Bool {
        e.wrong.contains(numToken) || e.correct.contains(numToken)
    }

    /// Split a string on a single `{num}` token. Returns (prefix, suffix) only
    /// when the token appears exactly once; `nil` otherwise (0 or ≥2 tokens).
    private static func splitOnNumToken(_ s: String) -> (prefix: String, suffix: String)? {
        let parts = s.components(separatedBy: numToken)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Replace `pattern` occurrences where `{num}` stands for a run of numeric
    /// characters, substituting the matched run verbatim into `replacement`.
    ///
    /// A rule is only applied when BOTH `wrong` and `correct` contain exactly one
    /// `{num}`, and the pattern is anchored (has a non-empty prefix or suffix) —
    /// a bare `{num}` with nothing around it would match every number and is
    /// skipped. Any disqualifying rule returns `text` unchanged (treated as a
    /// no-op literal entry), never a crash.
    static func numWildcardReplace(_ text: String, wrong: String, correct: String) -> String {
        guard let (wp, ws) = splitOnNumToken(wrong),
              let (cp, cs) = splitOnNumToken(correct) else { return text }
        // Bare `{num}` (no surrounding characters) is too greedy — skip it.
        guard !(wp.isEmpty && ws.isEmpty) else { return text }

        let chars = Array(text)
        let wpArr = Array(wp), wsArr = Array(ws)
        let cpArr = Array(cp), csArr = Array(cs)
        var result: [Character] = []
        result.reserveCapacity(chars.count)

        var i = 0
        while i < chars.count {
            if matchLiteral(chars, at: i, pattern: wpArr) {
                let runStart = i + wpArr.count
                var j = runStart
                while j < chars.count && numChars.contains(chars[j]) { j += 1 }
                // Need at least one numeric char, then the suffix must follow.
                if j > runStart && matchLiteral(chars, at: j, pattern: wsArr) {
                    result.append(contentsOf: cpArr)
                    result.append(contentsOf: chars[runStart..<j])   // matched number, verbatim
                    result.append(contentsOf: csArr)
                    i = j + wsArr.count
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return String(result)
    }

    /// True when `pattern` matches `chars` starting at `at`. Empty pattern always
    /// matches (used when a wildcard prefix/suffix is empty).
    private static func matchLiteral(_ chars: [Character], at: Int, pattern: [Character]) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard at + pattern.count <= chars.count else { return false }
        for k in 0..<pattern.count where chars[at + k] != pattern[k] { return false }
        return true
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

    /// Community-synced cache the sync layer writes (`dojo_shared.json`), same
    /// directory and `{"entries":[...]}` shape as the personal file. Owned here
    /// (not in DojoSharedSync) so this file stays self-contained for the
    /// standalone unit tests.
    static var sharedCacheURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("InputSa", isDirectory: true)
            .appendingPathComponent("dojo_shared.json")
    }

    /// Bundled seed shipped inside the app.
    private static var bundledSeedURL: URL? {
        Bundle.main.url(forResource: "dojo_corrections", withExtension: "json", subdirectory: "dojo")
            ?? Bundle.main.url(forResource: "dojo_corrections", withExtension: "json")
    }

    /// Shared (community) cache the sync layer writes. Read-only, no seeding —
    /// absent until the first successful `DojoSharedSync.syncNow()`. Returns `[]`
    /// on any failure (missing / malformed / not yet synced).
    private static func loadSharedEntries() -> [Entry] {
        guard let url = sharedCacheURL,
              FileManager.default.fileExists(atPath: url.path) else { return [] }
        return decodeEntries(at: url)
    }

    /// Resolve the personal file, seeding Application Support from the bundle if
    /// needed, then decode it. Returns `[]` on any failure.
    private static func loadPersonalEntries() -> [Entry] {
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
