import Foundation
import AVFoundation
import AVFAudio

/// Records audio using AVAudioRecorder (LINEAR16 / WAV) and transcribes via
/// Google Cloud Speech-to-Text V1.
///
/// Supports Mandarin (zh-TW) + Taiwanese Hokkien (nan-TW) code-switching via
/// `alternativeLanguageCodes`. Requires a GCP API key with Cloud Speech-to-Text
/// API enabled (console.cloud.google.com/apis/credentials).
final class GoogleVoiceService: NSObject, VoiceServiceProtocol {

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var micPermissionDenied = false
    private let levelMeter = AudioLevelMeter()
    var onLevelUpdate: ((Float) -> Void)? {
        get { levelMeter.onLevel }
        set { levelMeter.onLevel = newValue }
    }

    /// Same minimum as GroqVoiceService — prevents hallucinations on silence.
    static let minimumDurationSeconds: TimeInterval = 0.8

    var isRecording: Bool { audioRecorder?.isRecording ?? false }

    // MARK: - Recording (LINEAR16 WAV — required by Google STT)

    func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[InputSa] Google STT: microphone not authorized — recording skipped")
            micPermissionDenied = true
            return
        }
        micPermissionDenied = false

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputsa_google_\(Int(Date().timeIntervalSince1970)).wav")
        recordingURL = tmpURL
        recordingStartTime = Date()

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
            audioRecorder?.record()
            if let recorder = audioRecorder { levelMeter.start(recorder: recorder) }
        } catch {
            NSLog("[InputSa] Google STT recording failed to start: \(error)")
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

    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void) {
        levelMeter.stop()
        guard !micPermissionDenied else {
            completion(.failure(Err("麥克風權限未授權。請至「系統設定 › 隱私與安全性 › 麥克風」開啟 Input-sa 存取權限。")))
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

        guard duration >= Self.minimumDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            completion(.failure(Err("錄音太短（\(String(format: "%.1f", duration))s），請按住快捷鍵後再說話")))
            return
        }

        transcribeWithGoogle(audioURL: url, completion: completion)
    }

    // MARK: - Google Cloud STT V1

    private func transcribeWithGoogle(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let apiKey = APIKeyStore.shared.googleSttKey
        guard !apiKey.isEmpty else {
            try? FileManager.default.removeItem(at: audioURL)
            completion(.failure(Err("Google STT API Key 未設定，請至偏好設定輸入。")))
            return
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(.failure(Err("無法讀取錄音檔")))
            return
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let body: [String: Any] = [
            "config": [
                "encoding":                   "LINEAR16",
                "sampleRateHertz":            16000,
                "audioChannelCount":          1,
                // Primary: Traditional Chinese; alternatives: Taiwanese Hokkien
                // (nan-TW) and US English (en-US) so 中英夾雜 utterances keep the
                // English words as Latin text instead of being transliterated into
                // odd Chinese. Google STT picks the best match per utterance.
                "languageCode":               "zh-TW",
                "alternativeLanguageCodes":   ["nan-TW", "en-US"],
                "enableAutomaticPunctuation": true,
                "model":                      "latest_long",
            ],
            "audio": [
                "content": audioData.base64EncodedString(),
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(Err("無法序列化請求")))
            return
        }

        // API key is passed as a query parameter — no OAuth required.
        guard let endpoint = URL(string: "https://speech.googleapis.com/v1/speech:recognize?key=\(apiKey)") else {
            completion(.failure(Err("Invalid endpoint")))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(Err("Google STT 無回應"))) }
                return
            }

            do {
                let response = try JSONDecoder().decode(GoogleSTTResponse.self, from: data)
                let text = response.results?
                    .compactMap { $0.alternatives?.first?.transcript }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard !text.isEmpty else {
                    DispatchQueue.main.async { completion(.failure(Err("轉錄結果為空，請重試"))) }
                    return
                }
                DispatchQueue.main.async { completion(.success(text)) }
            } catch {
                // Surface the API error message when available.
                if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errObj  = errJson["error"] as? [String: Any],
                   let msg     = errObj["message"] as? String {
                    DispatchQueue.main.async { completion(.failure(Err("Google STT: \(msg)"))) }
                } else {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }.resume()
    }
}

// MARK: - Response Models

private struct GoogleSTTResponse: Decodable {
    let results: [SpeechResult]?
}

private struct SpeechResult: Decodable {
    let alternatives: [SpeechAlternative]?
}

private struct SpeechAlternative: Decodable {
    let transcript: String?
    let confidence: Float?
}

// MARK: - Helpers

private struct Err: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
