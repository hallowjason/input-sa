import Foundation

/// Common interface for voice transcription providers.
/// Allows InputController to switch between Groq and Google STT
/// without knowing the concrete implementation.
protocol VoiceServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    func startRecording()
    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void)
    /// Stop recording and discard the audio without transcribing
    /// (e.g. the PTT turned out to be part of a keyboard shortcut combo).
    func cancelRecording()
}