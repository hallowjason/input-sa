import Foundation
import CryptoKit

@main
struct WhisperModelTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { print("FAIL: \(name)"); exit(1) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-model-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("known model fixture".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let spec = WhisperModelSpec(file: "fixture.bin", bytes: Int64(bytes.count), sha256: hash, url: URL(string: "https://example.invalid/model")!)
        let part = root.appendingPathComponent("fixture.part")
        let dest = root.appendingPathComponent(spec.file)
        try bytes.write(to: part)
        try ModelFileValidator.install(part, at: dest, spec: spec)
        check(try Data(contentsOf: dest) == bytes, "first installation works without an existing destination")
        try Data(repeating: 0, count: bytes.count).write(to: part)
        do { try ModelFileValidator.install(part, at: dest, spec: spec); check(false, "bad digest must throw") }
        catch { check(try Data(contentsOf: dest) == bytes, "bad digest cannot replace a verified model") }
        try bytes.dropLast().write(to: part)
        do { try ModelFileValidator.verify(part, spec: spec); check(false, "truncated model must throw") }
        catch { check(true, "size mismatch fails closed") }
        do { try ModelFileValidator.verify(root.appendingPathComponent("missing"), spec: spec); check(false, "missing file must throw") }
        catch { check(true, "file read failure fails closed") }
        check(ModelFileValidator.acceptsRange("bytes 10-19/20", offset: 10, total: 20), "valid resume accepted")
        for invalid in ["bytes 0-19/20", "bytes 10-20/20", "bytes 10-19/21", "bytes 10-9/20", "garbage"] {
            check(!ModelFileValidator.acceptsRange(invalid, offset: 10, total: 20), "invalid range rejected: \(invalid)")
        }
        let pcm = Data((0..<32000 * 20).map { UInt8($0 % 251) })
        let whole = try WhisperWAV.encode(pcm: pcm)
        let tail = try WhisperWAV.encode(pcm: WhisperWAV.tail(pcm, seconds: 15))
        check(whole.count == pcm.count + 44, "full audio is preserved")
        check(whole.suffix(pcm.count) == pcm, "WAV final payload includes first and last samples")
        check(tail.count == 32000 * 15 + 44, "partial is only 15-second preview")
        check(whole.count > tail.count, "full result never reuses partial window")
        check(String(data: whole.prefix(4), encoding: .ascii) == "RIFF", "WAV header is RIFF")
        do { _ = try WhisperWAV.encode(pcm: Data([1])); check(false, "unaligned samples must throw") }
        catch { check(true, "odd byte count rejected") }
        print("\(checks)/\(checks) Whisper model/audio checks passed")
    }
}
