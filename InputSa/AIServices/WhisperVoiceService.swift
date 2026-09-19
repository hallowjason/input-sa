import Foundation
import AVFoundation

/// Local whisper.cpp large-v3-turbo. All public methods/callbacks run on main.
final class WhisperVoiceService: VoiceServiceProtocol {
    var onLevelUpdate: ((Float) -> Void)?
    var onPartialText: ((String) -> Void)?
    private(set) var isRecording = false
    private var recorder: WhisperAudio?
    private var sessionID = UUID()
    private var startError: Error?
    private var levelTimer: Timer?
    private var partialTimer: Timer?
    private var partialRequest: WhisperRequest?
    private var finalRequest: WhisperRequest?
    private var pendingCompletion: ((Result<VoiceTranscriptionSnapshot, Error>) -> Void)?
    private let runtime: WhisperRuntime

    init(runtime: WhisperRuntime = .shared) { self.runtime = runtime }

    func startRecording() {
        cancelRecording()
        sessionID = UUID()
        startError = nil
        guard WhisperRuntime.isSupported else { startError = WhisperError(WhisperRuntime.unavailabilityReason!); return }
        guard ModelManager.shared.isReady else { startError = WhisperError("Whisper 模型尚未下載或仍在驗證，請至偏好設定完成模型準備。"); return }
        guard WhisperRuntime.runtimeInstalled else { startError = WhisperError("App 未附 Whisper 引擎，請重新安裝完整版本。"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            startError = WhisperError("麥克風尚未授權，請在系統設定開啟 Input-sa 麥克風權限。"); return
        }
        let audio = WhisperAudio()
        do { try audio.start() } catch { startError = error; return }
        recorder = audio
        isRecording = true
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            self.onLevelUpdate?(self.recorder?.level ?? 0)
        }
        partialTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.caption() }
    }

    func cancelRecording() {
        sessionID = UUID()
        isRecording = false
        stopTimers()
        recorder?.stop(); recorder = nil
        partialRequest?.cancel(); partialRequest = nil
        finalRequest?.cancel(); finalRequest = nil
        let completion = pendingCompletion; pendingCompletion = nil
        completion?(.failure(URLError(.cancelled)))
    }

    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void) {
        stopAndTranscribeDetailed { completion($0.map(\.normalizedText)) }
    }

    func stopAndTranscribeDetailed(completion: @escaping (Result<VoiceTranscriptionSnapshot, Error>) -> Void) {
        if let error = startError { startError = nil; completion(.failure(error)); return }
        guard isRecording, let audio = recorder else { completion(.failure(WhisperError("沒有正在進行的 Whisper 錄音。"))); return }
        isRecording = false
        stopTimers()
        audio.stop(); recorder = nil
        // This explicitly stops the partial computation, not merely its UI callback.
        partialRequest?.cancel(); partialRequest = nil
        guard audio.duration >= 0.8 else { completion(.failure(WhisperError("錄音太短，請按住快捷鍵後再說話。"))); return }
        let wav: Data
        do { wav = try audio.snapshot() } catch { completion(.failure(error)); return }
        let token = sessionID
        pendingCompletion = completion
        finalRequest = runtime.transcribe(wav: wav, prompt: prompt()) { [weak self] result in
            guard let self = self, self.sessionID == token, !self.isRecording else { return }
            let completion = self.pendingCompletion; self.pendingCompletion = nil; self.finalRequest = nil
            completion?(result.flatMap { raw in
                guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { return .failure(WhisperError("轉錄結果為空，請重試。")) }
                return .success(VoiceTranscriptionSnapshot(rawText: raw,
                    normalizedText: OpenCCConverter.shared.convert(raw), engine: "whisper-large-v3-turbo"))
            })
        }
    }

    private func caption() {
        guard isRecording, partialRequest == nil, let recorder = recorder,
              recorder.duration >= 1, recorder.level > 0.008,
              let wav = try? recorder.snapshot(tailSeconds: 15) else { return }
        let token = sessionID
        partialRequest = runtime.transcribe(wav: wav, prompt: prompt(), partial: true) { [weak self] result in
            guard let self = self, self.sessionID == token, self.isRecording else { return }
            self.partialRequest = nil
            if case .success(let text) = result, !text.isEmpty {
                self.onPartialText?(OpenCCConverter.shared.convert(text))
            }
        }
    }

    private func prompt() -> String {
        let terms = DojoCorrectionTable.shared.preferredTerms(for: "", maxTerms: 20, maxCharacters: 90)
        return terms.isEmpty ? "" : terms.joined(separator: "、")
    }

    private func stopTimers() {
        levelTimer?.invalidate(); levelTimer = nil
        partialTimer?.invalidate(); partialTimer = nil
        onLevelUpdate?(0)
    }

    deinit {
        levelTimer?.invalidate(); partialTimer?.invalidate()
        recorder?.stop(); partialRequest?.cancel(); finalRequest?.cancel()
    }
}
