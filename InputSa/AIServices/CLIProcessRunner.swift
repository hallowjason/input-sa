import Foundation
import Darwin

enum CLITextError: Error, LocalizedError, Equatable {
    case unavailable, unsupportedProvider, unsafeConfiguration, managedConfiguration, launchFailed
    case inputTooLarge, outputTooLarge, emptyOutput, invalidOutput, inputFailed, timeout
    case nonzeroExit(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "找不到此文字整理 CLI，請先安裝並在終端機登入。"
        case .unsupportedProvider: return "這個選項不是 CLI 文字整理服務。"
        case .unsafeConfiguration: return "此 CLI 版本尚未通過文字整理安全驗證，請更新 Input-sa 或改用其他整理服務。"
        case .managedConfiguration: return "目前只支援未受組織政策管理的個人 CLI 登入。請確認使用個人 ChatGPT 或 Claude Pro／Max 帳號，或改用其他文字整理服務。"
        case .launchFailed: return "CLI 無法啟動，請確認安裝完整且可在終端機執行。"
        case .inputTooLarge: return "文字超過 CLI 單次整理上限，請分段處理。"
        case .outputTooLarge: return "CLI 輸出超過安全上限，未使用其結果。"
        case .emptyOutput: return "CLI 沒有傳回整理結果，請確認登入狀態。"
        case .invalidOutput: return "CLI 回傳格式無效，未使用其結果。"
        case .inputFailed: return "CLI 未能完整接收文字，未使用其結果。"
        case .timeout: return "CLI 文字整理逾時，已停止這次處理。"
        case .nonzeroExit(let code): return "CLI 執行失敗（代碼 \(code)），請在終端機確認登入或更新版本。"
        }
    }
}

/// Cancellation never stores a PID. Only the request's background worker owns
/// its Process, so cancellation after completion cannot target a later request.
final class CLITextRequest {
    fileprivate let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var cancelAction: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock()
        guard !finished, !cancelled else { lock.unlock(); return }
        cancelled = true; let action = cancelAction; lock.unlock()
        action?()
    }

    fileprivate func setCancelAction(_ action: (() -> Void)?) {
        lock.lock(); cancelAction = action; let runNow = cancelled && !finished; lock.unlock()
        if runNow { action?() }
    }

    fileprivate func deliver(_ result: Result<String, Error>, completion: (Result<String, Error>) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let wasCancelled = cancelled; finished = true; cancelAction = nil; lock.unlock()
        completion(wasCancelled ? .failure(URLError(.cancelled)) : result)
    }
}

enum CLIProcessOutput { case standardOutput, file(String) }

/// Two-step public account metadata exchange; never creates a conversation.
struct CLIJSONRPCHandshake {
    let initialize: String
    let afterInitialization: String
}

struct CLIProcessConfiguration {
    var executable: URL
    var arguments: [String]
    var output: CLIProcessOutput
    var timeout: TimeInterval = 90
    var terminationGrace: TimeInterval = 0.5
    var inputLimit = 128 * 1024
    var streamLimit = 64 * 1024
    var outputLimit = 64 * 1024
    // Non-sensitive configuration files only, never the prompt or original text.
    var supportingFiles: [String: Data] = [:]
    var fileConfigurations: [String: String] = [:]
    var jsonRPCHandshake: CLIJSONRPCHandshake?
}

/// Bounded, nonblocking I/O runs off main. Each invocation gets a private empty
/// working directory; it inherits no API keys, proxies or host CLI variables.
enum CLIProcessRunner {
    private static let stateLock = NSLock()
    private static var acceptingRequests = true
    private static var requests: [UUID: CLITextRequest] = [:]
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.inputsa.cli-text"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    @discardableResult
    static func run(configuration: CLIProcessConfiguration, input: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> CLITextRequest {
        run(input: input, prepare: { _ in configuration }, completion: completion)
    }

    @discardableResult
    static func run(input: String, prepare: @escaping (CLITextRequest) throws -> CLIProcessConfiguration,
                    completion: @escaping (Result<String, Error>) -> Void) -> CLITextRequest {
        let request = CLITextRequest()
        stateLock.lock()
        guard acceptingRequests else {
            stateLock.unlock()
            DispatchQueue.main.async { request.deliver(.failure(URLError(.cancelled)), completion: completion) }
            return request
        }
        requests[request.id] = request
        stateLock.unlock()
        workers.addOperation {
            defer { stateLock.lock(); requests.removeValue(forKey: request.id); stateLock.unlock() }
            let result: Result<String, Error>
            do {
                guard !request.isCancelled else { throw URLError(.cancelled) }
                let configuration = try prepare(request)
                guard input.utf8.count <= configuration.inputLimit else { throw CLITextError.inputTooLarge }
                result = .success(try execute(configuration, input: Data(input.utf8), request: request))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { request.deliver(result, completion: completion) }
        }
        return request
    }

    /// Normal quit waits for this drain before replying to AppKit. Queued work
    /// is cancelled too, so no metadata or inference child can start afterward.
    static func shutdown(completion: @escaping () -> Void) {
        stateLock.lock(); acceptingRequests = false; let pending = Array(requests.values); stateLock.unlock()
        pending.forEach { $0.cancel() }
        DispatchQueue.global(qos: .userInitiated).async {
            workers.waitUntilAllOperationsAreFinished()
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Metadata commands share the same request cancellation and bounded pipes.
    /// Called only by the preparation closure on a worker, never the UI thread.
    static func captureMetadata(_ configuration: CLIProcessConfiguration, request: CLITextRequest) throws -> String {
        guard !Thread.isMainThread else { throw CLITextError.unsafeConfiguration }
        return try execute(configuration, input: Data(), request: request)
    }

    private static func execute(_ config: CLIProcessConfiguration, input: Data,
                                request: CLITextRequest) throws -> String {
        guard config.timeout > 0, config.terminationGrace >= 0,
              config.streamLimit > 0, config.outputLimit > 0 else { throw CLITextError.unsafeConfiguration }
        if let handshake = config.jsonRPCHandshake {
            guard input.isEmpty, case .standardOutput = config.output,
                  handshake.initialize.utf8.count + handshake.afterInitialization.utf8.count <= config.inputLimit
            else { throw CLITextError.unsafeConfiguration }
        }
        if case .file(let name) = config.output {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw CLITextError.unsafeConfiguration }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inputsa-cli-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700]) }
        catch { throw CLITextError.launchFailed }
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, data) in config.supportingFiles {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), data.count <= 4 * 1024 * 1024 else {
                throw CLITextError.unsafeConfiguration
            }
            do { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
            catch { throw CLITextError.launchFailed }
        }

        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = config.executable
        child.arguments = config.arguments
        for key in config.fileConfigurations.keys.sorted() {
            guard let name = config.fileConfigurations[key], config.supportingFiles[name] != nil else { throw CLITextError.unsafeConfiguration }
            let path = directory.appendingPathComponent(name).path
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let insertion = child.arguments?.last == "-" ? (child.arguments!.count - 1) : child.arguments!.count
            child.arguments?.insert(contentsOf: ["-c", key + "=\"" + path + "\""], at: insertion)
        }
        child.currentDirectoryURL = directory
        child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "USER": NSUserName(), "LOGNAME": NSUserName(),
                             "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                             "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": directory.path]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        defer {
            for handle in [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                           stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting] { try? handle.close() }
        }
        let inFD = stdin.fileHandleForWriting.fileDescriptor
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        for descriptor in [inFD, outFD, errFD] {
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else { throw CLITextError.launchFailed }
        }
        // A child closing stdin early must not raise SIGPIPE in the input method.
        guard fcntl(inFD, F_SETNOSIGPIPE, 1) != -1 else { throw CLITextError.launchFailed }
        guard !request.isCancelled else { throw URLError(.cancelled) }
        do { try child.run() } catch { throw CLITextError.launchFailed }
        // Signal immediately on UI/app cancellation; subsequent SIGKILL and
        // reaping remain on this worker. The closure borrows this exact Process.
        request.setCancelAction { [weak child] in if let child = child, child.isRunning { child.terminate() } }
        defer { request.setCancelAction(nil) }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        var stdoutData = Data()
        var outgoing = config.jsonRPCHandshake.map { Data($0.initialize.utf8) } ?? input
        var initialized = false
        var metadataReply: Data?
        var stdoutCount = 0, stderrCount = 0, written = 0
        var inputClosed = false
        var failure: Error?
        var terminateAt: TimeInterval?
        var didKill = false
        let deadline = ProcessInfo.processInfo.systemUptime + config.timeout
        let retainStdout: Bool
        if case .standardOutput = config.output { retainStdout = true } else { retainStdout = false }

        func drain(_ descriptor: Int32, count: inout Int, retain: Bool) {
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = Darwin.read(descriptor, &bytes, bytes.count)
                if n <= 0 { break }
                count += n
                guard count <= config.streamLimit else { failure = failure ?? CLITextError.outputTooLarge; return }
                if retain { stdoutData.append(contentsOf: bytes.prefix(n)) }
            }
        }

        func processMetadataLines() {
            guard let handshake = config.jsonRPCHandshake else { return }
            while let newline = stdoutData.firstIndex(of: 10) {
                let line = Data(stdoutData[..<newline])
                stdoutData.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    failure = failure ?? CLITextError.invalidOutput; return
                }
                if (reply["id"] as? Int) == 1 {
                    guard !initialized, reply["error"] == nil, reply["result"] is [String: Any] else {
                        failure = failure ?? CLITextError.invalidOutput; return
                    }
                    initialized = true
                    outgoing.append(contentsOf: handshake.afterInitialization.utf8)
                } else if (reply["id"] as? Int) == 2 {
                    guard initialized, metadataReply == nil else {
                        failure = failure ?? CLITextError.invalidOutput; return
                    }
                    metadataReply = line
                }
            }
        }

        repeat {
            drain(outFD, count: &stdoutCount, retain: retainStdout)
            drain(errFD, count: &stderrCount, retain: false)
            processMetadataLines()
            if case .file(let name) = config.output {
                var attributes = stat()
                if lstat(directory.appendingPathComponent(name).path, &attributes) == 0 {
                    if attributes.st_mode & S_IFMT != S_IFREG { failure = failure ?? CLITextError.invalidOutput }
                    else if attributes.st_size > config.outputLimit { failure = failure ?? CLITextError.outputTooLarge }
                }
            }
            if request.isCancelled { failure = URLError(.cancelled) }
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil, now >= deadline { failure = CLITextError.timeout }
            if failure == nil, !inputClosed {
                if written == outgoing.count {
                    // app-server drops pending requests on early EOF. Keep the
                    // pipe open until the matching account reply has arrived.
                    if config.jsonRPCHandshake == nil || metadataReply != nil {
                        try? stdin.fileHandleForWriting.close(); inputClosed = true
                    }
                } else {
                    let n = outgoing.withUnsafeBytes { bytes in
                        Darwin.write(inFD, bytes.baseAddress!.advanced(by: written), min(4096, outgoing.count - written))
                    }
                    if n > 0 { written += n }
                    else if n < 0, errno != EAGAIN, errno != EINTR { failure = CLITextError.inputFailed }
                }
            }
            if failure != nil || metadataReply != nil, child.isRunning {
                if terminateAt == nil {
                    child.terminate(); terminateAt = now
                } else if !didKill, now - terminateAt! >= config.terminationGrace {
                    // Process remains strongly held and isRunning is checked;
                    // this is not a PID lookup or a process-name kill.
                    if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                    didKill = true
                }
            }
            if !child.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
        child.waitUntilExit()
        drain(outFD, count: &stdoutCount, retain: retainStdout)
        drain(errFD, count: &stderrCount, retain: false)
        processMetadataLines()
        if let failure = failure { throw failure }
        // A metadata process is intentionally stopped after its bounded reply.
        guard metadataReply != nil || child.terminationStatus == 0 else { throw CLITextError.nonzeroExit(child.terminationStatus) }
        guard written == outgoing.count else { throw CLITextError.inputFailed }
        if config.jsonRPCHandshake != nil, metadataReply == nil { throw CLITextError.invalidOutput }

        let data: Data
        switch config.output {
        case .standardOutput: data = metadataReply ?? stdoutData
        case .file(let name): data = try readFinalFile(directory.appendingPathComponent(name), limit: config.outputLimit)
        }
        guard data.count <= config.outputLimit else { throw CLITextError.outputTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw CLITextError.invalidOutput }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLITextError.emptyOutput }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" })
        else { throw CLITextError.invalidOutput }
        return trimmed
    }

    private static func readFinalFile(_ url: URL, limit: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CLITextError.emptyOutput }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw CLITextError.invalidOutput }
        guard attributes.st_size <= limit else { throw CLITextError.outputTooLarge }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(descriptor, &bytes, bytes.count)
            if n == 0 { break }
            guard n > 0 else { throw CLITextError.invalidOutput }
            guard result.count + n <= limit else { throw CLITextError.outputTooLarge }
            result.append(contentsOf: bytes.prefix(n))
        }
        return result
    }
}
