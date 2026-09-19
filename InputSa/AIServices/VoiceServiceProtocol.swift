import Foundation

/// Immutable, per-recording values: the recognizer output must remain recoverable
/// even when normalization or AI cleanup later changes the text.
struct VoiceTranscriptionSnapshot: Equatable {
    let rawText: String
    let normalizedText: String
    let engine: String
}

/// Common interface for voice transcription providers.
/// Allows InputController to switch between Groq and Google STT
/// without knowing the concrete implementation.
protocol VoiceServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    func startRecording()
    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void)
    func stopAndTranscribeDetailed(completion: @escaping (Result<VoiceTranscriptionSnapshot, Error>) -> Void)
    /// Stop recording and discard the audio without transcribing
    /// (e.g. the PTT turned out to be part of a keyboard shortcut combo).
    func cancelRecording()
    /// Fires ~30 times/sec while recording with a normalized 0...1 mic level,
    /// for driving the HUD's live waveform. Fires with 0 once recording stops.
    var onLevelUpdate: ((Float) -> Void)? { get set }
    /// Provisional text only. Never use a partial result as the final transcript.
    var onPartialText: ((String) -> Void)? { get set }
}

extension VoiceServiceProtocol {
    var onPartialText: ((String) -> Void)? {
        get { nil }
        set { }
    }

    func stopAndTranscribeDetailed(completion: @escaping (Result<VoiceTranscriptionSnapshot, Error>) -> Void) {
        stopAndTranscribe { result in
            completion(result.map {
                VoiceTranscriptionSnapshot(rawText: $0, normalizedText: $0, engine: "legacy")
            })
        }
    }
}
