import Foundation

/// Bounded, local-only text history. No audio, API keys, or network operations.
/// Every operation is serialized; observers are notified only after a durable
/// save. Tests inject a temporary directory and never access user storage.
final class TranscriptHistoryStore {
    enum OutputStatus: String, Codable, CaseIterable {
        case sent, copied, failed, cancelled, notSent

        var displayName: String {
            switch self {
            case .sent: return "已送往 App"
            case .copied: return "已複製"
            case .failed: return "輸出失敗"
            case .cancelled: return "已取消"
            case .notSent: return "尚未輸出"
            }
        }
    }

    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let date: Date
        let rawText: String
        let normalizedText: String
        let aiText: String?
        var finalText: String
        let engine: String
        let durationMs: Int
        let fallbackReason: String?
        var status: OutputStatus
        let appName: String?
        let appBundleID: String?

        init(id: UUID = UUID(), date: Date = Date(), rawText: String,
             normalizedText: String, aiText: String?, finalText: String,
             engine: String, durationMs: Int, fallbackReason: String? = nil,
             status: OutputStatus, appName: String? = nil, appBundleID: String? = nil) {
            self.id = id
            self.date = date
            self.rawText = rawText
            self.normalizedText = normalizedText
            self.aiText = aiText
            self.finalText = finalText
            self.engine = engine
            self.durationMs = max(0, durationMs)
            self.fallbackReason = fallbackReason
            self.status = status
            self.appName = appName
            self.appBundleID = appBundleID
        }

        var wasEdited: Bool { normalizedText != finalText }
    }

    private struct Document: Codable {
        var version = 1
        var isEnabled = true
        var entries: [Entry] = []
    }

    private enum StoreError: LocalizedError {
        case invalidStorage, unreadableHistory, unsupportedVersion, oversizedEntry
        var errorDescription: String? {
            switch self {
            case .invalidStorage: return "口述紀錄路徑不是一般資料夾或檔案。"
            case .unreadableHistory: return "既有口述紀錄無法讀取；請先在紀錄視窗檢查，必要時明確清空後再啟用。"
            case .unsupportedVersion: return "此口述紀錄由較新的版本建立，未載入或覆寫。"
            case .oversizedEntry: return "這段口述超過本機紀錄容量上限，未截斷或保存。"
            }
        }
    }

    static let didChangeNotification = Notification.Name("com.inputsa.transcriptHistoryDidChange")
    static let shared = TranscriptHistoryStore()
    static let defaultMaxEntries = 200
    static let defaultMaxBytes = 2_000_000

    let fileURL: URL
    private let directoryURL: URL
    private let maxEntries: Int
    private let maxBytes: Int
    private let lock = NSLock()
    private var document = Document()
    private var writeGeneration = UUID()
    private var loadFailure: String?
    private let fm = FileManager.default

    var entries: [Entry] { locked { document.entries } }
    /// Capture before scheduling an async write. Clearing/disabling invalidates
    /// queued work so old private text cannot reappear after a user action.
    var generation: UUID { locked { writeGeneration } }
    var isEnabled: Bool { locked { document.isEnabled } }
    var loadErrorDescription: String? { locked { loadFailure } }

    init(directoryURL: URL? = nil, maxEntries: Int = defaultMaxEntries,
         maxBytes: Int = defaultMaxBytes) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.directoryURL = directoryURL ?? base.appendingPathComponent("InputSa/History", isDirectory: true)
        self.fileURL = self.directoryURL.appendingPathComponent("entries.json")
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(512, maxBytes)
        do {
            try validateStorage()
            guard fm.fileExists(atPath: fileURL.path) else { return }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directoryURL.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= self.maxBytes else {
                throw StoreError.unreadableHistory
            }
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard decoded.version == 1 else { throw StoreError.unsupportedVersion }
            document = decoded
            document.entries = sorted(decoded.entries).prefix(self.maxEntries).map { $0 }
        } catch {
            document.isEnabled = false
            loadFailure = error.localizedDescription
        }
    }

    /// False means recording is disabled; a failed save throws and leaves the
    /// previous memory/disk contents intact. Raw text is never truncated to fit.
    @discardableResult
    func record(_ entry: Entry, ifGeneration expected: UUID? = nil) throws -> Bool {
        let recorded = try locked {
            guard expected == nil || expected == writeGeneration else { return false }
            try requireReadableHistory()
            guard document.isEnabled else { return false }
            var next = document
            next.entries.removeAll { $0.id == entry.id }
            next.entries.append(entry)
            next.entries = sorted(next.entries).prefix(maxEntries).map { $0 }
            // Check this record alone first, so an oversized new record cannot
            // erase all prior records while trying to satisfy the byte limit.
            var single = next
            single.entries = [entry]
            guard try encoded(single).count <= maxBytes else { throw StoreError.oversizedEntry }
            try saveBounded(&next)
            document = next
            return next.entries.contains { $0.id == entry.id }
        }
        if recorded { notifyChange() }
        return recorded
    }

    @discardableResult
    func updateStatus(id: UUID, status: OutputStatus, finalText: String? = nil) throws -> Bool {
        let updated = try locked {
            try requireReadableHistory()
            guard document.isEnabled,
                  let index = document.entries.firstIndex(where: { $0.id == id }) else { return false }
            var next = document
            next.entries[index].status = status
            if let finalText { next.entries[index].finalText = finalText }
            var single = next
            single.entries = [next.entries[index]]
            guard try encoded(single).count <= maxBytes else { throw StoreError.oversizedEntry }
            try saveBounded(&next)
            document = next
            return true
        }
        if updated { notifyChange() }
        return updated
    }

    func setEnabled(_ enabled: Bool) throws {
        try locked {
            try requireReadableHistory()
            var next = document
            next.isEnabled = enabled
            try saveBounded(&next)
            document = next
            writeGeneration = UUID()
        }
        notifyChange()
    }

    /// Call only after an explicit user clear action. It also permits recovery
    /// of an unreadable file; normal recording never overwrites such a file.
    func clear() throws {
        try locked {
            var next = Document()
            next.isEnabled = document.isEnabled
            try saveBounded(&next)
            document = next
            loadFailure = nil
            writeGeneration = UUID()
        }
        notifyChange()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func requireReadableHistory() throws {
        guard loadFailure == nil else { throw StoreError.unreadableHistory }
    }

    private func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    private func encoded(_ document: Document) throws -> Data {
        try JSONEncoder().encode(document)
    }

    private func saveBounded(_ next: inout Document) throws {
        var data = try encoded(next)
        while data.count > maxBytes, !next.entries.isEmpty {
            next.entries.removeLast()
            data = try encoded(next)
        }
        guard data.count <= maxBytes else { throw StoreError.oversizedEntry }
        try validateStorage()
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let temporary = directoryURL.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Same-directory replacement is atomic. Use the private temporary file's
        // metadata instead of inheriting permissions from an older history file.
        if fm.fileExists(atPath: fileURL.path) {
            _ = try fm.replaceItemAt(fileURL, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temporary, to: fileURL)
        }
    }

    private func validateStorage() throws {
        for (url, expected) in [(directoryURL, FileAttributeType.typeDirectory),
                                (fileURL, FileAttributeType.typeRegular)] {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               attrs[.type] as? FileAttributeType != expected {
                throw StoreError.invalidStorage
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
