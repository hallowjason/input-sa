import Foundation

/// Privacy-preserving usage statistics: **counts only, never content.**
///
/// We store how many characters / segments / milliseconds of dictation and
/// translation happened, bucketed per local day — and deliberately never the
/// transcribed text itself. This is a hard privacy decision, not an oversight:
/// the store has no field that could hold a transcript.
///
/// Persistence mirrors the dojo tables: a JSON file in Application Support,
/// written atomically. Reads that fail (missing file, first run, corrupt JSON)
/// start from all-zeros and never crash.
///
/// Threading: `record` is always called from the main thread (it runs inside the
/// same `DispatchQueue.main.async` injection completions as the dojo save), and
/// the dashboard reads on the main thread too, so no locking is needed.
final class UsageStatsStore {

    static let shared = UsageStatsStore()

    /// One local day's totals. `date` is "yyyy-MM-dd" in the local time zone.
    struct DayStat: Codable {
        var date: String
        var chars: Int
        var segments: Int
        var durationMs: Int
    }

    private struct StatsData: Codable {
        var totalChars: Int
        var totalSegments: Int
        var totalDurationMs: Int
        var daily: [DayStat]
        static let empty = StatsData(totalChars: 0, totalSegments: 0,
                                     totalDurationMs: 0, daily: [])
    }

    private static let maxDays = 30

    private var data: StatsData

    private init() { data = Self.load() }

    // MARK: - Recording

    /// Record one completed dictation/translation segment. Accumulates the
    /// lifetime totals and today's bucket, trims history to the last 30 days,
    /// and writes to disk immediately (dictation frequency is low, so a write
    /// per segment is cheap).
    func record(chars: Int, durationMs: Int) {
        data.totalChars += chars
        data.totalSegments += 1
        data.totalDurationMs += durationMs

        let key = Self.dayKey(for: Date())
        if let idx = data.daily.firstIndex(where: { $0.date == key }) {
            data.daily[idx].chars += chars
            data.daily[idx].segments += 1
            data.daily[idx].durationMs += durationMs
        } else {
            data.daily.append(DayStat(date: key, chars: chars,
                                      segments: 1, durationMs: durationMs))
        }

        // Keep only the most recent 30 days (oldest first, then trim the head).
        data.daily.sort { $0.date < $1.date }
        if data.daily.count > Self.maxDays {
            data.daily = Array(data.daily.suffix(Self.maxDays))
        }
        save()
    }

    // MARK: - Queries

    /// Today's bucket, or an all-zero DayStat for today if nothing recorded yet.
    func today() -> DayStat {
        let key = Self.dayKey(for: Date())
        return data.daily.first { $0.date == key }
            ?? DayStat(date: key, chars: 0, segments: 0, durationMs: 0)
    }

    /// The last 7 days, oldest → newest, with missing days zero-filled so the
    /// chart always has exactly 7 bars.
    func last7Days() -> [DayStat] {
        let calendar = Self.calendar
        let startOfToday = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
            let key = Self.dayKey(for: day)
            return data.daily.first { $0.date == key }
                ?? DayStat(date: key, chars: 0, segments: 0, durationMs: 0)
        }
    }

    var totalChars: Int { data.totalChars }
    var totalSegments: Int { data.totalSegments }
    var totalDurationMs: Int { data.totalDurationMs }

    // MARK: - Date helpers (local time zone)

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - Persistence

    /// `~/Library/Application Support/InputSa/usage_stats.json`
    /// (same directory convention as the dojo tables).
    private static var storeURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("InputSa", isDirectory: true)
            .appendingPathComponent("usage_stats.json")
    }

    private static func load() -> StatsData {
        guard let url = storeURL,
              FileManager.default.fileExists(atPath: url.path),
              let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StatsData.self, from: raw)
        else { return .empty }
        return decoded
    }

    private func save() {
        guard let url = Self.storeURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONEncoder().encode(data)
            try out.write(to: url, options: .atomic)
        } catch {
            inputSaLog("usage stats: write failed — \(error.localizedDescription)")
        }
    }
}
