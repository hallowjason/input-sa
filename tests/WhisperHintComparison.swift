import Foundation

/// Optional local acoustic comparison using a supplied synthetic WAV; no mic,
/// Keychain, personal history or cloud service. Not part of the fast unit suite.
/// Supply: whisper-server model.bin fixture.wav
@main
struct WhisperHintComparison {
    static func main() {
        do { try run() }
        catch { fputs("Comparison failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 4 else { throw WhisperError("Expected server, model and synthetic WAV paths") }
        let runtime = WhisperRuntime(binaryURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                                     modelURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { runtime.shutdown() }
        let wav = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        for (label, prompt) in [("without name hints", ""),
                                ("with name hints", SpeechRecognitionHints.whisperPrompt(vocabulary: []))] {
            var result: Result<String, Error>?
            let began = Date()
            runtime.transcribe(wav: wav, prompt: prompt) { result = $0 }
            while result == nil, Date().timeIntervalSince(began) < 240 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard let result = result else { throw WhisperError("Comparison timed out") }
            let text = try result.get()
            print("\(label) (\(String(format: "%.2f", Date().timeIntervalSince(began)))s): \(text)")
        }
    }
}
