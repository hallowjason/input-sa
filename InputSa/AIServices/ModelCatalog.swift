import Foundation
import CryptoKit

struct WhisperModelSpec {
    let file: String
    let bytes: Int64
    let sha256: String
    let url: URL
}

enum ModelCatalog {
    // ggerganov/whisper.cpp LFS object; also independently pinned by Talky
    // 9fd3ab7ab2c8c0536e6d37103edaa777ec31cf67/Downloads.swift.
    static let whisperLargeV3Turbo = WhisperModelSpec(
        file: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!)

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputSa/models", isDirectory: true)
    }
}

struct WhisperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ModelFileValidator {
    /// Always verify both size and digest. A read failure never means success.
    static func verify(_ url: URL, spec: WhisperModelSpec) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        guard size == spec.bytes else { throw WhisperError("模型大小不符，請重新下載。") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == spec.sha256.lowercased() else { throw WhisperError("模型 SHA-256 校驗失敗，請重新下載。") }
    }

    static func install(_ part: URL, at destination: URL, spec: WhisperModelSpec) throws {
        try verify(part, spec: spec)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: destination)
        }
    }

    static func acceptsRange(_ contentRange: String?, offset: Int64, total: Int64) -> Bool {
        guard let value = contentRange, value.hasPrefix("bytes ") else { return false }
        let pieces = value.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, Int64(pieces[1]) == total else { return false }
        let bounds = pieces[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return false }
        return start == offset && end >= start && end < total
    }
}
