import Foundation
import AVFoundation
import AVFAudio

/// Fully local voice transcription via sherpa-onnx + Paraformer (zh).
///
/// Push-to-talk like the cloud providers: startRecording() on keyDown,
/// stopAndTranscribe() on keyUp. Audio is recorded as 16 kHz mono LINEAR16 WAV,
/// decoded to Float samples, run through the offline Paraformer recognizer
/// (greedy_search, 4 threads), then converted simplified → Traditional (Taiwan)
/// via OpenCCConverter before being returned.
///
/// The recognizer is lazily built on first use and then kept resident — the
/// 243 MB int8 model must not be reloaded per utterance.
final class SherpaVoiceService: NSObject, VoiceServiceProtocol {

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var micPermissionDenied = false
    private let levelMeter = AudioLevelMeter()
    var onLevelUpdate: ((Float) -> Void)? {
        get { levelMeter.onLevel }
        set { levelMeter.onLevel = newValue }
    }

    /// Same minimum as the cloud providers — guards against empty/garbage clips.
    static let minimumDurationSeconds: TimeInterval = 0.8

    /// Serial queue for model build + decode so heavy work never blocks the main
    /// (event-tap) thread and two utterances never build the model concurrently.
    private let work = DispatchQueue(label: "com.inputsa.sherpa.decode")

    /// Lazily-built, resident recognizer. Accessed only on `work`.
    private var recognizer: SherpaOnnxOfflineRecognizer?

    var isRecording: Bool { audioRecorder?.isRecording ?? false }

    // MARK: - Recording (LINEAR16 WAV — decoded locally to Float samples)

    func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[InputSa] Sherpa: microphone not authorized — recording skipped")
            micPermissionDenied = true
            return
        }
        micPermissionDenied = false

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputsa_sherpa_\(Int(Date().timeIntervalSince1970)).wav")
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
            NSLog("[InputSa] Sherpa recording failed to start: \(error)")
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

        transcribeLocally(audioURL: url, completion: completion)
    }

    // MARK: - Local decode

    private func transcribeLocally(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        work.async { [weak self] in
            guard let self = self else { return }
            defer { try? FileManager.default.removeItem(at: audioURL) }

            func finish(_ result: Result<String, Error>) {
                DispatchQueue.main.async { completion(result) }
            }

            // 1. Decode WAV → Float samples (16 kHz mono, normalized [-1, 1]).
            guard let samples = Self.readSamples(url: audioURL), !samples.isEmpty else {
                finish(.failure(Err("無法讀取錄音檔")))
                return
            }

            // 2. Build the recognizer once, then reuse.
            guard let recognizer = self.loadRecognizerIfNeeded() else {
                finish(.failure(Err("本地模型載入失敗，請確認 model.int8.onnx / tokens.txt 已隨 App 安裝。")))
                return
            }

            // 3. Decode → simplified Chinese text.
            let result = recognizer.decode(samples: samples, sampleRate: 16000)
            let simplified = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Silence/noise can decode to bare punctuation (SenseVoice emits "." on
            // empty audio) — treat "no letters at all" as an empty result, otherwise
            // the LLM polish step gets garbage and replies conversationally.
            guard simplified.contains(where: { $0.isLetter || $0.isNumber }) else {
                finish(.failure(Err("轉錄結果為空，請重試")))
                return
            }

            // 4. Simplified → Traditional (Taiwan).
            let traditional = OpenCCConverter.shared.convert(simplified)

            // 5. Dojo homophone corrections (always + optional dojoOnly tier).
            let dojoMode = UserDefaults.standard.bool(forKey: "com.inputsa.dojoMode")
            let corrected = DojoCorrectionTable.shared.correct(traditional, dojoMode: dojoMode)
            inputSaLog("STT raw: \(String(simplified.prefix(120)))")
            if corrected != traditional {
                inputSaLog("dojo corrected: \(String(corrected.prefix(120)))")
            }
            finish(.success(corrected))
        }
    }

    /// Build (once) and return the resident Paraformer recognizer. Must run on `work`.
    private func loadRecognizerIfNeeded() -> SherpaOnnxOfflineRecognizer? {
        if let recognizer = recognizer { return recognizer }

        guard let resourcePath = Bundle.main.resourcePath else {
            NSLog("[InputSa] Sherpa: no resourcePath")
            return nil
        }
        let fm = FileManager.default
        let t0 = Date()
        let modelConfig: SherpaOnnxOfflineModelConfig

        // Prefer SenseVoice (zh/en/ja/ko/yue — handles中英夾雜 and is more accent-
        // tolerant than the zh-only Paraformer). Falls back to Paraformer when the
        // sensevoice/ directory is absent, so either model dir alone works.
        let svModel  = "\(resourcePath)/model/sensevoice/model.int8.onnx"
        let svTokens = "\(resourcePath)/model/sensevoice/tokens.txt"
        let pfModel  = "\(resourcePath)/model/model.int8.onnx"
        let pfTokens = "\(resourcePath)/model/tokens.txt"

        if fm.fileExists(atPath: svModel), fm.fileExists(atPath: svTokens) {
            let sv = sherpaOnnxOfflineSenseVoiceModelConfig(
                model: svModel,
                language: "auto",
                useInverseTextNormalization: true
            )
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: svTokens,
                numThreads: 4,
                provider: "cpu",
                modelType: "sense_voice",
                senseVoice: sv
            )
            inputSaLog("STT model: SenseVoice (multilingual)")
        } else if fm.fileExists(atPath: pfModel), fm.fileExists(atPath: pfTokens) {
            let paraformer = sherpaOnnxOfflineParaformerModelConfig(model: pfModel)
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: pfTokens,
                paraformer: paraformer,
                numThreads: 4,
                provider: "cpu",
                modelType: "paraformer"
            )
            inputSaLog("STT model: Paraformer (zh)")
        } else {
            NSLog("[InputSa] Sherpa: no model found under \(resourcePath)/model")
            return nil
        }

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
        let built = SherpaOnnxOfflineRecognizer(config: &config)
        recognizer = built
        NSLog("[InputSa] Sherpa: recognizer loaded in %.2fs", Date().timeIntervalSince(t0))
        return built
    }

    // MARK: - WAV → Float samples

    /// Read a LINEAR16 WAV into normalized Float samples via AVAudioFile.
    /// `processingFormat` is always deinterleaved Float32 at the file's sample rate,
    /// so for a 16 kHz mono recording this yields exactly what Paraformer expects.
    private static func readSamples(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channels[0], count: n))
    }
}

// MARK: - Helpers
private struct Err: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
