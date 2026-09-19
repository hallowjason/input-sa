import Foundation
import CryptoKit

/// In-process HTTP fixture: real URLSession delegate/file-write paths, no network.
private final class DownloadFixture: URLProtocol {
    static let payload = Data(repeating: 87, count: 131072)
    private var stopped = false
    private let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.url!.lastPathComponent
        let offset = Int(request.value(forHTTPHeaderField: "Range")?.dropFirst(6).dropLast() ?? "") ?? 0
        let range = scenario == "ignore" ? 0 : offset
        let status = range > 0 ? 206 : 200
        var headers = ["Content-Length": String(Self.payload.count - range)]
        if status == 206 {
            headers["Content-Range"] = "bytes \(scenario == "bad" ? 0 : range)-\(Self.payload.count - 1)/\(Self.payload.count)"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        let chunk = Data(Self.payload.dropFirst(range))
        if scenario == "slow" {
            client?.urlProtocol(self, didLoad: Data(chunk.prefix(32768)))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
                guard !stopped else { return }
                self.client?.urlProtocol(self, didLoad: Data(chunk.dropFirst(32768)))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            client?.urlProtocol(self, didLoad: chunk)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@main
struct WhisperDownloadTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-download-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = SHA256.hash(data: DownloadFixture.payload).map { String(format: "%02x", $0) }.joined()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadFixture.self]
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            checks += 1
            if !condition { throw WhisperError("FAIL: " + label) }
        }
        func download(_ scenario: String, destination: URL, cancel: Bool = false) throws -> Result<URL, Error> {
            let spec = WhisperModelSpec(file: destination.lastPathComponent, bytes: Int64(DownloadFixture.payload.count),
                                        sha256: hash, url: URL(string: "https://fixture.invalid/\(scenario)")!)
            let lock = NSLock()
            var result: Result<URL, Error>?
            var transfer: ModelDownload!
            transfer = ModelDownload(spec: spec, destination: destination, configuration: config, progress: { phase in
                if case .downloading(let progress) = phase, progress > 0, cancel { transfer.cancel() }
            }, completion: { value in lock.lock(); result = value; lock.unlock() })
            transfer.start()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                lock.lock(); let finished = result; lock.unlock()
                if let finished = finished { return finished }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            throw WhisperError("download fixture timed out")
        }
        let resumable = root.appendingPathComponent("resume.bin")
        let cancellation = try download("slow", destination: resumable, cancel: true)
        if case .failure(let error) = cancellation {
            try check((error as? URLError)?.code == .cancelled, "cancel is reported")
        } else { try check(false, "cancel cannot install") }
        try check(!FileManager.default.fileExists(atPath: resumable.path), "cancel leaves destination absent")
        try check((try Data(contentsOf: resumable.appendingPathExtension("part"))).count == 32768, "cancel retains only downloaded bytes")
        _ = try download("resume", destination: resumable).get()
        try check(try Data(contentsOf: resumable) == DownloadFixture.payload, "Range resumes and validates final bytes")

        let ignored = root.appendingPathComponent("ignore.bin")
        try DownloadFixture.payload.prefix(100).write(to: ignored.appendingPathExtension("part"))
        _ = try download("ignore", destination: ignored).get()
        try check(try Data(contentsOf: ignored) == DownloadFixture.payload, "server ignoring Range resets instead of appending")

        let replacement = root.appendingPathComponent("replace.bin")
        try Data("previous corrupt model".utf8).write(to: replacement)
        _ = try download("resume", destination: replacement).get()
        try check(try Data(contentsOf: replacement) == DownloadFixture.payload, "verified download replaces an existing corrupt model")

        let bad = root.appendingPathComponent("bad.bin")
        try DownloadFixture.payload.prefix(100).write(to: bad.appendingPathExtension("part"))
        if case .success = try download("bad", destination: bad) { try check(false, "wrong resume range rejected") }
        else { try check(true, "wrong resume range rejected") }
        try check(!FileManager.default.fileExists(atPath: bad.path), "wrong range does not install")
        print("\(checks)/\(checks) Whisper download checks passed")
    }
}
