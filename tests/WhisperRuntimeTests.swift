import Foundation
import AVFoundation

/// Uses only a supplied WAV file and local test model; never opens a microphone.
@main
struct WhisperRuntimeTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 4 else {
            print("Usage: WhisperRuntimeTests whisper-server model.bin sample.wav"); exit(2)
        }
        let runtime = WhisperRuntime(binaryURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                                     modelURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { runtime.shutdown() }
        let wav = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        func decode(_ data: Data, label: String) throws -> String {
            var result: Result<String, Error>?
            let began = Date()
            runtime.transcribe(wav: data) { result = $0 }
            while result == nil, Date().timeIntervalSince(began) < 240 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard let result = result else { throw WhisperError("test timed out") }
            let text = try result.get()
            print("\(label): \(String(format: "%.2f", Date().timeIntervalSince(began))) seconds; \(text)")
            return text
        }
        let short = try decode(wav, label: "official JFK final")
        guard short.lowercased().contains("country"), short.lowercased().contains("ask") else { throw WhisperError("official sample transcription missing expected speech") }

        // Extend beyond the temporary 15-second caption window. The first
        // utterance must still be present after substantial trailing silence.
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard audio.processingFormat.sampleRate == 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { throw WhisperError("sample format") }
        try audio.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw WhisperError("sample channel") }
        var pcm = Data()
        for i in 0..<Int(buffer.frameLength) {
            var value = Int16(max(-32768, min(32767, Int(samples[i] * 32767)))).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let original = pcm
        pcm.append(Data(repeating: 0, count: 32000 * 35))
        pcm.append(original)
        let long = try decode(WhisperWAV.encode(pcm: pcm), label: "long first-and-last final")
        let occurrences = long.lowercased().components(separatedBy: "country").count - 1
        guard occurrences >= 4 else { throw WhisperError("long sample lost its first or last utterance") }
        print("PASS: complete long audio retains both first and last JFK utterances")

        var cancelled: Result<String, Error>?
        let request = runtime.transcribe(wav: try WhisperWAV.encode(pcm: pcm), partial: true) { cancelled = $0 }
        // The warm server has started work before cancellation. This exercises
        // actual process interruption, not just cancellation of a queued request.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard cancelled == nil else { throw WhisperError("in-flight cancellation fixture completed too early") }
        request.cancel()
        let cancelStart = Date()
        while cancelled == nil, Date().timeIntervalSince(cancelStart) < 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard case .failure(let error) = cancelled, (error as? URLError)?.code == .cancelled else { throw WhisperError("cancelled request completed successfully") }
        print("PASS: in-flight cancellation returns no transcript in \(String(format: "%.2f", Date().timeIntervalSince(cancelStart))) seconds")
        let afterCancel = try decode(wav, label: "final after partial cancellation")
        guard afterCancel.lowercased().contains("country") else { throw WhisperError("partial cancellation poisoned next final decode") }
        print("PASS: next final decode restarts the owned process successfully")
    }
}
