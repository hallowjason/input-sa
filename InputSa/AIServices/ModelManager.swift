import Foundation

/// Verified model storage. Does not download until download() is explicitly called.
/// State and readyModelURL are safe to read from any queue; UI notifications run on main.
final class ModelManager {
    enum State: Equatable {
        case missing, downloading(Double), verifying, ready, paused, failed(String)
        var isBusy: Bool {
            switch self { case .downloading, .verifying: return true; default: return false }
        }
    }
    static let shared = ModelManager()
    static let didChange = Notification.Name("InputSaWhisperModelStateChanged")
    let spec: WhisperModelSpec
    let modelURL: URL
    private let queue = DispatchQueue(label: "com.inputsa.whisper.model")
    private let lock = NSLock()
    private var storedState: State = .missing
    private var downloadTask: ModelDownload?
    private var revision = UUID()

    var state: State { lock.lock(); defer { lock.unlock() }; return storedState }
    var readyModelURL: URL? { state == .ready ? modelURL : nil }
    var isReady: Bool { readyModelURL != nil }

    init(directory: URL = ModelCatalog.directory, spec: WhisperModelSpec = ModelCatalog.whisperLargeV3Turbo) {
        self.spec = spec
        modelURL = directory.appendingPathComponent(spec.file)
        refresh()
    }

    func refresh() {
        queue.async {
            guard self.downloadTask == nil else { return }
            guard FileManager.default.fileExists(atPath: self.modelURL.path) else { self.publish(.missing); return }
            self.publish(.verifying)
            do { try ModelFileValidator.verify(self.modelURL, spec: self.spec); self.publish(.ready) }
            catch { self.publish(.failed(error.localizedDescription)) }
        }
    }

    func download() {
        queue.async {
            guard self.downloadTask == nil, self.state != .ready else { return }
            let revision = UUID()
            self.revision = revision
            let task = ModelDownload(spec: self.spec, destination: self.modelURL, progress: { [weak self] state in
                self?.queue.async { [weak self] in
                    guard let self = self, self.revision == revision else { return }
                    self.publish(state)
                }
            }, completion: { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self = self, self.revision == revision else { return }
                    self.downloadTask = nil
                    switch result {
                    case .success: self.publish(.ready)
                    case .failure(let e as URLError) where e.code == .cancelled: self.publish(.paused)
                    case .failure(let error): self.publish(.failed(error.localizedDescription))
                    }
                }
            })
            self.downloadTask = task
            self.publish(.downloading(0))
            task.start()
        }
    }

    func cancel() { queue.async { self.downloadTask?.cancel() } }

    private func publish(_ state: State) {
        lock.lock(); storedState = state; lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}

/// One resumable transfer. The .part file survives cancellation and connection errors.
final class ModelDownload: NSObject, URLSessionDataDelegate {
    private let spec: WhisperModelSpec
    private let destination: URL
    private let progress: (ModelManager.State) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private let configuration: URLSessionConfiguration
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q
    }()
    private let cancelLock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var output: FileHandle?
    private var offset: Int64 = 0
    private var finished = false
    private var failure: Error?
    private var verifyCompletePart = false
    private var part: URL { destination.appendingPathExtension("part") }
    private var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }

    init(spec: WhisperModelSpec, destination: URL, configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping (ModelManager.State) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.spec = spec; self.destination = destination; self.progress = progress; self.completion = completion
        self.configuration = configuration
    }

    func start() {
        delegateQueue.addOperation {
            do {
                guard !self.isCancelled else { throw URLError(.cancelled) }
                let fm = FileManager.default
                try fm.createDirectory(at: self.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: self.part.path) { fm.createFile(atPath: self.part.path, contents: nil) }
                self.offset = (try fm.attributesOfItem(atPath: self.part.path)[.size] as? Int64) ?? 0
                self.output = try FileHandle(forWritingTo: self.part)
                if self.offset > self.spec.bytes { try self.resetPart() }
                let needed = max(0, self.spec.bytes - self.offset) + 100 * 1_048_576
                let attrs = try fm.attributesOfFileSystem(forPath: self.destination.deletingLastPathComponent().path)
                if let free = attrs[.systemFreeSize] as? Int64, free < needed { throw WhisperError("磁碟空間不足，請清出模型所需空間。") }
                try self.output?.seekToEnd()
                if self.offset == self.spec.bytes { return self.verify() }
                var request = URLRequest(url: self.spec.url, timeoutInterval: 45)
                if self.offset > 0 { request.setValue("bytes=\(self.offset)-", forHTTPHeaderField: "Range") }
                let config = self.configuration
                config.timeoutIntervalForResource = 6 * 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: self.delegateQueue)
                self.session = session
                self.task = session.dataTask(with: request)
                guard !self.isCancelled else { throw URLError(.cancelled) }
                self.task?.resume()
            } catch { self.finish(.failure(error)) }
        }
    }

    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
        delegateQueue.addOperation { self.task?.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, !isCancelled else { completionHandler(.cancel); return }
        do {
            switch http.statusCode {
            case 200: if offset > 0 { try resetPart() }
            case 206:
                guard ModelFileValidator.acceptsRange(http.value(forHTTPHeaderField: "Content-Range"), offset: offset, total: spec.bytes)
                else { throw WhisperError("下載續傳範圍不符，已停止以保護模型檔。") }
            case 416 where offset == spec.bytes:
                verifyCompletePart = true; completionHandler(.cancel); return
            default: throw WhisperError("模型下載失敗（HTTP \(http.statusCode)）。")
            }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, !isCancelled else { dataTask.cancel(); return }
        do {
            guard offset + Int64(data.count) <= spec.bytes else { throw WhisperError("下載內容超過模型大小，已停止。") }
            try output?.write(contentsOf: data)
            offset += Int64(data.count)
            progress(.downloading(Double(offset) / Double(spec.bytes)))
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if isCancelled { finish(.failure(URLError(.cancelled))) }
        else if let failure = failure { finish(.failure(failure)) }
        else if verifyCompletePart { verify() }
        else if let error = error { finish(.failure(error)) }
        else { verify() }
    }

    private func resetPart() throws { try output?.truncate(atOffset: 0); try output?.seek(toOffset: 0); offset = 0 }

    private func verify() {
        guard !finished else { return }
        do {
            try output?.close(); output = nil
            guard !isCancelled else { throw URLError(.cancelled) }
            progress(.verifying)
            try ModelFileValidator.verify(part, spec: spec)
            guard !isCancelled else { throw URLError(.cancelled) }
            // Validated first; destination is never replaced by a partial/corrupt file.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
            } else { try FileManager.default.moveItem(at: part, to: destination) }
            finish(.success(destination))
        } catch {
            // A fully downloaded bad digest must not become a permanently stuck resume.
            if !isCancelled, offset == spec.bytes, let h = try? FileHandle(forWritingTo: part) {
                try? h.truncate(atOffset: 0); try? h.close()
            }
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        try? output?.close(); output = nil
        session?.invalidateAndCancel(); session = nil
        completion(result)
    }
}
