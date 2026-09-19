import Foundation

private final class LegacyService: VoiceServiceProtocol {
    var isRecording = false
    var onLevelUpdate: ((Float) -> Void)?
    func startRecording() { isRecording = true }
    func cancelRecording() { isRecording = false }
    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void) {
        isRecording = false
        completion(.success("原始文字"))
    }
}

@main
struct VoiceServiceProtocolTests {
    static func main() {
        let service: VoiceServiceProtocol = LegacyService()
        var received: VoiceTranscriptionSnapshot?
        service.stopAndTranscribeDetailed { received = try? $0.get() }
        precondition(received?.rawText == "原始文字")
        precondition(received?.normalizedText == "原始文字")
        service.onPartialText = { _ in fatalError("Legacy providers do not emit partials") }
        precondition(service.onPartialText == nil)
        let original = VoiceTranscriptionSnapshot(rawText: "简体", normalizedText: "繁體", engine: "test")
        precondition(original.rawText != original.normalizedText)
        precondition(original.engine == "test")
        print("VoiceServiceProtocolTests: 5/5 passed")
    }
}
