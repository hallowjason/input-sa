import Foundation
import Darwin

final class WhisperRequest {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    fileprivate var onCancel: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); let first = !cancelled; cancelled = true; lock.unlock()
        if first { onCancel?() }
    }
}

/// One owned loopback server, one request at a time. Cancelling an inference also
/// terminates its server computation; cancelling just URLSession would leave GPU work queued.
final class WhisperRuntime {
    static let shared = WhisperRuntime()
    private let queue = DispatchQueue(label: "com.inputsa.whisper.runtime", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var baseURL: URL?
    private var active: WhisperRequest?
    private var activeTask: URLSessionDataTask?
    private var stopping = false
    private let binaryOverride: URL?
    private let modelOverride: URL?

    static var unavailableReason: String? {
        #if !arch(arm64)
        return "Whisper 本機辨識需要 Apple Silicon Mac。"
        #else
        if #available(macOS 14.0, *) { return nil }
        return "Whisper 本機辨識需要 macOS 14 以上。"
        #endif
    }
    static var isSupported: Bool { unavailableReason == nil }
    static var unavailabilityReason: String? { unavailableReason }
    static var bundledBinary: URL? { Bundle.main.resourceURL?.appendingPathComponent("whisper/whisper-server") }
    static var runtimeInstalled: Bool {
        guard let binary = bundledBinary else { return false }
        return FileManager.default.isExecutableFile(atPath: binary.path)
    }

    init(binaryURL: URL? = nil, modelURL: URL? = nil) {
        binaryOverride = binaryURL; modelOverride = modelURL
    }

    deinit { shutdown() }

    @discardableResult
    func transcribe(wav: Data, prompt: String = "", partial: Bool = false,
                    completion: @escaping (Result<String, Error>) -> Void) -> WhisperRequest {
        let request = WhisperRequest()
        request.onCancel = { [weak self, weak request] in
            guard let self = self, let request = request else { return }
            self.lock.lock()
            let ownsWork = self.active?.id == request.id
            let task = ownsWork ? self.activeTask : nil
            self.lock.unlock()
            task?.cancel()
            if ownsWork { self.stopServer(ownedBy: request.id) }
        }
        queue.async {
            var result: Result<String, Error>
            self.lock.lock(); self.active = request; self.lock.unlock()
            do {
                try self.check(request)
                let base = try self.ensureServer(request)
                try self.check(request)
                let text = try self.inference(wav: wav, prompt: prompt, base: base,
                                              timeout: partial ? 12 : 900, request: request)
                try self.check(request)
                result = .success(text)
            } catch {
                if request.isCancelled { self.stopServer() }
                result = .failure(request.isCancelled ? URLError(.cancelled) : error)
            }
            self.lock.lock()
            if self.active?.id == request.id { self.active = nil; self.activeTask = nil }
            self.lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
        return request
    }

    func shutdown() {
        lock.lock(); stopping = true; let request = active; lock.unlock()
        request?.cancel()
        stopServer()
    }

    private func check(_ request: WhisperRequest) throws {
        lock.lock(); let isStopping = stopping; lock.unlock()
        if isStopping || request.isCancelled { throw URLError(.cancelled) }
    }

    private func stopServer(ownedBy requestID: UUID? = nil) {
        lock.lock()
        // A late cancel from the preceding request must never terminate a new final decode.
        if let requestID = requestID, active?.id != requestID { lock.unlock(); return }
        let old = process; process = nil; baseURL = nil; lock.unlock()
        guard let old = old, old.isRunning else { return }
        old.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if old.isRunning { kill(old.processIdentifier, SIGKILL) }
        }
    }

    private func ensureServer(_ request: WhisperRequest) throws -> URL {
        if let reason = Self.unavailableReason { throw WhisperError(reason) }
        lock.lock(); let existing = process; let existingURL = baseURL; lock.unlock()
        if let existing = existing, existing.isRunning, let base = existingURL { return base }
        guard let binary = binaryOverride ?? Self.bundledBinary,
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw WhisperError("Whisper 引擎未隨 App 安裝，請重新安裝完整版本。")
        }
        guard let model = modelOverride ?? ModelManager.shared.readyModelURL else {
            throw WhisperError("請先在偏好設定下載並驗證 Whisper 模型。")
        }
        // Validate even externally supplied test/development models before launching native code.
        try ModelFileValidator.verify(model, spec: ModelCatalog.whisperLargeV3Turbo)
        try check(request)
        let port = try Self.availablePort()
        let route = "/inputsa-" + UUID().uuidString.lowercased()
        let base = URL(string: "http://127.0.0.1:\(port)\(route)")!
        let child = Process()
        child.executableURL = binary
        // Server v1.9.1 sets no_context=true by default; unlike whisper-cli it has no -nc flag.
        child.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                           "--request-path", route, "-l", "auto", "-t",
                           String(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))]
        // No inherited DYLD/GGML paths: packaged static runtime resolves only system libraries.
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        lock.lock(); process = child; baseURL = base; lock.unlock()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try check(request)
            guard child.isRunning else {
                stopServer()
                throw WhisperError("Whisper 引擎啟動失敗（exit \(child.terminationStatus)）。")
            }
            // An unrelated listener cannot satisfy this random instance-specific URL.
            if health(base) {
                guard child.isRunning else { throw WhisperError("Whisper 引擎已停止。") }
                return base
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        stopServer()
        throw WhisperError("Whisper 模型載入逾時，請確認可用記憶體後重試。")
    }

    private final class Reply {
        let lock = NSLock()
        var data: Data?
        var status = 0
        var error: Error?
    }

    private func health(_ base: URL) -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 0.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let reply = Reply(); let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.lock.lock(); reply.data = data; reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0; reply.lock.unlock()
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 0.7) == .timedOut { task.cancel(); return false }
        reply.lock.lock(); defer { reply.lock.unlock() }
        guard reply.status == 200, let data = reply.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return json["status"] == "ok"
    }

    private func inference(wav: Data, prompt: String, base: URL, timeout: TimeInterval,
                           request: WhisperRequest) throws -> String {
        let boundary = "inputsa-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("language", "auto")
        field("temperature", "0")
        field("prompt", String(prompt.prefix(120)))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var urlRequest = URLRequest(url: base.appendingPathComponent("inference"), timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"; urlRequest.httpBody = body
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let reply = Reply(); let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            reply.lock.lock(); reply.data = data; reply.error = error
            reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0; reply.lock.unlock()
            done.signal()
        }
        lock.lock(); activeTask = task; lock.unlock()
        try check(request)
        task.resume()
        guard done.wait(timeout: .now() + timeout + 1) != .timedOut else {
            task.cancel(); stopServer(); throw WhisperError("Whisper 辨識逾時，完整錄音沒有被部分字幕取代。")
        }
        try check(request)
        reply.lock.lock(); let data = reply.data; let status = reply.status; let error = reply.error; reply.lock.unlock()
        if let error = error { stopServer(); throw error }
        guard status == 200, let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw WhisperError("Whisper 回應無效（HTTP \(status)）。") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WhisperError("無法建立本機語音服務。") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw WhisperError("無法保留本機語音服務連接埠。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0 else { throw WhisperError("無法取得本機語音服務連接埠。") }
        return UInt16(bigEndian: address.sin_port)
    }
}
