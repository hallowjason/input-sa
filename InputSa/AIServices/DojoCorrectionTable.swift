import Foundation

/// Personal and shared vocabulary references. The legacy class name, JSON path,
/// and wire fields are retained so existing dictionaries continue to load.
/// Entries provide bounded context to AI; they never rewrite a transcript.
final class DojoCorrectionTable {
    struct Entry: Codable {
        let wrong: String
        let correct: String
        // Legacy storage/API metadata only. Neither field enables replacement.
        let tier: String
        let phonetic: Bool

        enum CodingKeys: String, CodingKey {
            case wrong, correct, tier, phonetic
        }

        // Shared-vocabulary servers still accept "always"/"dojoOnly" on the wire.
        // New entries use compatible metadata without opting into phonetic rules.
        init(wrong: String, correct: String, tier: String = "always", phonetic: Bool = false) {
            self.wrong = wrong
            self.correct = correct
            self.tier = tier
            self.phonetic = phonetic
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wrong = try c.decode(String.self, forKey: .wrong)
            correct = try c.decode(String.self, forKey: .correct)
            tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? "always"
            phonetic = try c.decodeIfPresent(Bool.self, forKey: .phonetic) ?? false
        }
    }

    // The editor only writes personal entries; shared entries remain a read-only
    // cache. Reference selection merges them without changing either source.
    private var _personal: [Entry]
    private var _shared: [Entry]

    var personalEntries: [Entry] { _personal }
    var sharedEntries: [Entry] { _shared }

    static let shared = DojoCorrectionTable()

    init(personal: [Entry], shared: [Entry]) {
        _personal = personal
        _shared = shared
    }

    convenience init(entries: [Entry]) {
        self.init(personal: entries, shared: [])
    }

    convenience init() {
        self.init(personal: Self.loadPersonalEntries(), shared: Self.loadSharedEntries())
    }

    /// Select whole reference terms without transforming the supplied transcript.
    /// All legacy tiers participate. Explicit mentions in this utterance rank
    /// first; otherwise personal entries precede shared entries. This never uses
    /// wrong-form or homophone matching to infer what the speaker intended.
    ///
    /// Limits bound the vocabulary's contribution to the on-device model's small
    /// context window. Oversized entries stay saved but are skipped, not truncated.
    func preferredTerms(
        for transcript: String,
        maxTerms: Int = 80,
        maxCharacters: Int = 800,
        maxTermCharacters: Int = 64
    ) -> [String] {
        guard maxTerms > 0, maxCharacters > 0, maxTermCharacters > 0 else { return [] }
        let personalKeys = Set(_personal.map(Self.dedupKey))
        let merged = _personal + _shared.filter { !personalKeys.contains(Self.dedupKey($0)) }
        var seen = Set<String>()
        var mentioned: [String] = []
        var remaining: [String] = []
        for entry in merged {
            // Old numeric replacement patterns are not literal vocabulary.
            // Retain them on disk so no user data is silently deleted.
            guard !entry.wrong.contains("{num}"), !entry.correct.contains("{num}") else { continue }
            let term = entry.correct.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maxTermCharacters,
                  seen.insert(term).inserted else { continue }
            if transcript.range(of: term, options: .caseInsensitive) != nil {
                mentioned.append(term)
            } else {
                remaining.append(term)
            }
        }

        var selected: [String] = []
        var usedCharacters = 0
        for term in mentioned + remaining {
            guard selected.count < maxTerms else { break }
            let cost = term.count + (selected.isEmpty ? 0 : 1)
            guard cost <= maxCharacters - usedCharacters else { continue }
            selected.append(term)
            usedCharacters += cost
        }
        return selected
    }

    /// Keep personal overrides of an existing shared mishearing, even though the
    /// wrong form now serves only as metadata rather than a replacement pattern.
    private static func dedupKey(_ entry: Entry) -> String {
        let wrong = entry.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = entry.correct.trimmingCharacters(in: .whitespacesAndNewlines)
        return (wrong.isEmpty || wrong == correct) ? "c:\(correct)" : "w:\(wrong)"
    }

    func reload() {
        _personal = Self.loadPersonalEntries()
        _shared = Self.loadSharedEntries()
    }

    /// Save only the personal table, atomically. Existing legacy metadata is
    /// encoded unchanged, and failed writes leave the in-memory table intact.
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
