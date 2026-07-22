import Foundation
import AVFoundation
import AVFAudio

/// Records audio using AVAudioRecorder and transcribes via Groq Whisper API.
/// Push-to-talk: call startRecording() on keyDown, stopAndTranscribe() on keyUp.
/// AI polishing is handled separately in InputController after transcription.
final class GroqVoiceService: NSObject, VoiceServiceProtocol {

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var micPermissionDenied = false
    private var recordStartFailed = false
    private let levelMeter = AudioLevelMeter()
    var onLevelUpdate: ((Float) -> Void)? {
        get { levelMeter.onLevel }
        set { levelMeter.onLevel = newValue }
    }

    /// Minimum recording duration in seconds.
    /// Whisper frequently hallucinates (outputs random training-data text) on silent
    /// or very short clips — rejecting them early avoids garbage output.
    static let minimumDurationSeconds: TimeInterval = 0.8

    var isRecording: Bool { audioRecorder?.isRecording ?? false }

    // MARK: - Recording
    func startRecording() {
        // Guard: AVAudioRecorder records silence without error when mic is denied.
        // The permission should have been granted at app launch (AppDelegate), but
        // guard here as a safety net so stopAndTranscribe can return a clear error.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[InputSa] Groq: microphone not authorized — recording skipped")
            micPermissionDenied = true
            return
        }
        micPermissionDenied = false
        recordStartFailed = false

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputsa_voice_\(Int(Date().timeIntervalSince1970)).wav")
        recordingURL = tmpURL
        recordingStartTime = Date()

        // LINEAR16 WAV (uncompressed), NOT AAC/m4a. Rationale (2026-07-21):
        // AAC encoding buffers the tail frames and flushes them asynchronously
        // after stop(); reading the file immediately in stopAndTranscribe raced
        // that flush and uploaded a truncated clip — the "只能轉錄前面 2 秒" bug
        // friends hit but this machine (which defaults to the local Sherpa/PCM
        // path) never saw. PCM WAV is finalized synchronously on stop(), so the
        // whole utterance is always on disk before we read it. Groq Whisper
        // accepts wav; 16 kHz mono 16-bit ≈ 32 KB/s, trivial to upload.
        let settings: [String: Any] = [
            AVFormatIDKey:             Int(kAudioFormatLinearPCM),
            AVSampleRateKey:           16000.0,
            AVNumberOfChannelsKey:     1,
            AVLinearPCMBitDepthKey:    16,
            AVLinearPCMIsFloatKey:     false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: tmpURL, settings: settings)
            if audioRecorder?.record() == true {
                if let recorder = audioRecorder { levelMeter.start(recorder: recorder) }
            } else {
                inputSaLog("Groq: AVAudioRecorder.record() returned false — no usable input device?")
                recordStartFailed = true
                audioRecorder = nil
            }
        } catch {
            inputSaLog("Groq recording failed to start: \(error)")
            recordStartFailed = true
        }
    }

    func cancelRecording() {
        levelMeter.stop()
        audioRecorder?.stop()
        audioRecorder = nil
        recordingStartTime = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }

    /// Stop recording and transcribe via Groq Whisper. Returns the raw transcript.
    /// Aborts if the recording is shorter than `minimumDurationSeconds` to prevent
    /// Whisper hallucination on silence.
    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void) {
        levelMeter.stop()
        guard !micPermissionDenied else {
            completion(.failure(Err("麥克風權限未授權。請至「系統設定 › 隱私與安全性 › 麥克風」開啟 Input-sa 存取權限。")))
            return
        }
        guard !recordStartFailed else {
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
            recordingStartTime = nil
            completion(.failure(Err("錄音無法啟動——請檢查「系統設定 › 聲音 › 輸入」是否有可用的麥克風。")))
            return
        }

        audioRecorder?.stop()
        audioRecorder = nil

        let duration = Date().timeIntervalSince(recordingStartTime ?? .distantPast)
        recordingStartTime = nil

        guard let url = recordingURL else {
            completion(.failure(Err("No recording URL")))
            return
        }
        recordingURL = nil

        // Reject recordings that are too short — prevents Whisper hallucinations
        guard duration >= Self.minimumDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            completion(.failure(Err("錄音太短（\(String(format: "%.1f", duration))s），請按住快捷鍵後再說話")))
            return
        }

        transcribeWithGroq(audioURL: url, completion: completion)
    }

    // MARK: - Groq API
    private func transcribeWithGroq(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let apiKey = APIKeyStore.shared.groqKey
        guard !apiKey.isEmpty else {
            try? FileManager.default.removeItem(at: audioURL)
            completion(.failure(Err("Groq API key 未設定，請至偏好設定輸入。")))
            return
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(.failure(Err("無法讀取錄音檔")))
            return
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "InputSaBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8Data
        }
        field("model",           "whisper-large-v3-turbo")
        // Pinned to "zh" (not auto-detect): logs show Whisper already emits the
        // embedded English (commit/cloud/GitHub) as Latin text under a zh hint, so
        // 中英夾雜 is covered without opening the door to whole-utterance language
        // misdetection on the primary dictation path. Revisit only with real-world
        // testing if English recall proves insufficient.
        field("language",        "zh")
        field("response_format", "json")
        // prompt: 給 Whisper 一個真實的語境提示，大幅降低無聲/安靜時的幻覺輸出
        field("prompt",          "以下是繁體中文口語錄音，請精確轉錄說話者說的內容。")

        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8Data
        body += audioData
        body += "\r\n--\(boundary)--\r\n".utf8Data
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data else { DispatchQueue.main.async { completion(.failure(Err("Groq 無回應"))) }; return }

            do {
                let json = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
                let text = json.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    DispatchQueue.main.async { completion(.failure(Err("轉錄結果為空，請重試"))) }
                    return
                }
                DispatchQueue.main.async { completion(.success(text)) }
            } catch {
                if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errObj  = errJson["error"] as? [String: Any],
                   let msg     = errObj["message"] as? String {
                    DispatchQueue.main.async { completion(.failure(Err("Groq: \(msg)"))) }
                } else {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }.resume()
    }
}

// MARK: - Helpers
private struct GroqTranscriptionResponse: Decodable { let text: String }
private struct Err: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
private extension String { var utf8Data: Data { Data(utf8) } }
private extension Data   { static func += (l: inout Data, r: Data) { l.append(r) } }
