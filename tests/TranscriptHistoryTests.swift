import Foundation

// swiftc tests/TranscriptHistoryTests.swift InputSa/AIServices/TranscriptHistoryStore.swift -o /private/tmp/history_tests
@main
enum TranscriptHistoryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("inputsa-history-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if condition { print("PASS: \(name)") }
            else { failures += 1; print("FAIL: \(name)") }
        }
        func entry(_ seconds: TimeInterval, text: String = "原始辨識", id: UUID = UUID()) -> TranscriptHistoryStore.Entry {
            .init(id: id, date: Date(timeIntervalSince1970: seconds), rawText: text,
                  normalizedText: "繁體原稿", aiText: "AI 整理", finalText: "最終輸出",
                  engine: "local-test", durationMs: 3500, fallbackReason: "合成測試原因",
                  status: .sent, appName: "測試 App", appBundleID: "test.example")
        }
        let directory = root.appendingPathComponent("roundtrip")
        let store = TranscriptHistoryStore(directoryURL: directory, maxEntries: 3)
        check(store.isEnabled && store.entries.isEmpty, "new store records by default without existing data")
        let first = entry(1)
        check(try store.record(first), "record succeeds")
        let loaded = TranscriptHistoryStore(directoryURL: directory, maxEntries: 3)
        check(loaded.entries == [first], "all text stages and metadata survive disk round trip")
        let directoryMode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        check(directoryMode?.intValue == 0o700 && fileMode?.intValue == 0o600, "history directory and file are private")
        _ = try store.record(entry(3))
        _ = try store.record(entry(2))
        _ = try store.record(entry(4))
        check(store.entries.map(\.date) == [4, 3, 2].map { Date(timeIntervalSince1970: $0) }, "bounded history keeps newest entries in date order")
        let replacementMode = try fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        check(replacementMode?.intValue == 0o600, "atomic replacements retain private file permissions")
        let current = store.entries[0]
        check(try store.updateStatus(id: current.id, status: .failed, finalText: ""), "existing output status can be updated")
        check(store.entries[0].status == .failed && store.entries[0].finalText.isEmpty, "status update keeps the original text stages")
        check(store.entries[0].rawText == current.rawText, "status update never changes the raw transcript")
        _ = try store.record(entry(5, id: current.id))
        check(store.entries.count == 3 && store.entries[0].id == current.id, "recording the same id updates rather than duplicates")
        try store.setEnabled(false)
        check(!(try store.record(entry(6))), "disabled store ignores new records")
        check(!(try store.updateStatus(id: current.id, status: .sent, finalText: "新內容")), "disabled store does not append text to existing records")
        let disabled = TranscriptHistoryStore(directoryURL: directory, maxEntries: 3)
        check(!disabled.isEnabled && disabled.entries.count == 3, "disabled preference and existing records survive restart")
        try disabled.clear()
        check(disabled.entries.isEmpty && !disabled.isEnabled, "explicit clear removes records while retaining the disabled setting")

        let queued = TranscriptHistoryStore(directoryURL: root.appendingPathComponent("queued"))
        let oldGeneration = queued.generation
        try queued.clear()
        check(!(try queued.record(entry(20), ifGeneration: oldGeneration)), "queued text cannot reappear after explicit clear")
        check(queued.entries.isEmpty, "clear keeps history empty after a stale save")
        let beforeDisable = queued.generation
        try queued.setEnabled(false)
        try queued.setEnabled(true)
        check(!(try queued.record(entry(21), ifGeneration: beforeDisable)), "disable then enable never resurrects queued old text")
        check(try queued.record(entry(22), ifGeneration: queued.generation), "new generation accepts new recordings")

        let bounded = TranscriptHistoryStore(directoryURL: root.appendingPathComponent("bytes"), maxEntries: 20, maxBytes: 1600)
        _ = try bounded.record(entry(1, text: String(repeating: "a", count: 350)))
        _ = try bounded.record(entry(2, text: String(repeating: "b", count: 350)))
        _ = try bounded.record(entry(3, text: String(repeating: "c", count: 350)))
        let boundedSize = try fm.attributesOfItem(atPath: bounded.fileURL.path)[.size] as? NSNumber
        check((boundedSize?.intValue ?? Int.max) <= 1600 && bounded.entries.first?.date == Date(timeIntervalSince1970: 3), "byte budget evicts oldest records while retaining the newest")
        let beforeOversized = bounded.entries
        do {
            _ = try bounded.record(entry(4, text: String(repeating: "x", count: 4000)))
            check(false, "oversized individual record must fail")
        } catch {
            check(bounded.entries == beforeOversized, "oversized record fails without truncating text or discarding existing history")
        }

        let corruptDir = root.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptURL = corruptDir.appendingPathComponent("entries.json")
        let corruptBytes = Data("broken history".utf8)
        try corruptBytes.write(to: corruptURL)
        let corrupt = TranscriptHistoryStore(directoryURL: corruptDir)
        check(corrupt.loadErrorDescription != nil && !corrupt.isEnabled, "corrupt history fails closed")
        do { try corrupt.setEnabled(true); check(false, "corrupt file must not be silently overwritten") }
        catch { check(try Data(contentsOf: corruptURL) == corruptBytes, "failed load preserves the original file") }
        try corrupt.clear()
        try corrupt.setEnabled(true)
        check(try corrupt.record(entry(7)), "explicit clear recovers corrupted storage")

        let destination = root.appendingPathComponent("outside")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-history")
        try fm.createSymbolicLink(at: link, withDestinationURL: destination)
        let linked = TranscriptHistoryStore(directoryURL: link)
        do { _ = try linked.record(entry(8)); check(false, "symbolic history directory must not be followed") }
        catch { check(!fm.fileExists(atPath: destination.appendingPathComponent("entries.json").path), "history does not write through symbolic links") }

        let failureDir = root.appendingPathComponent("write-failure")
        let failing = TranscriptHistoryStore(directoryURL: failureDir)
        _ = try failing.record(first)
        try fm.moveItem(at: failureDir, to: root.appendingPathComponent("saved-before-failure"))
        try Data("blocked".utf8).write(to: failureDir)
        do { _ = try failing.record(entry(10)); check(false, "invalidated storage must reject a write") }
        catch { check(failing.entries == [first], "failed persistence leaves the in-memory history intact") }

        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
