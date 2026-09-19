import Foundation
import AVFoundation

enum WhisperWAV {
    static func encode(pcm: Data) throws -> Data {
        guard pcm.count % 2 == 0, pcm.count <= Int(UInt32.max) - 36 else { throw WhisperError("錄音資料大小無效。") }
        var data = Data()
        func ascii(_ text: String) { data.append(Data(text.utf8)) }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm.count) + 36); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }

    static func tail(_ pcm: Data, seconds: Int) -> Data { Data(pcm.suffix(max(0, seconds) * 32000)) }
}

/// Audio is accumulated once. Temporary captions inspect a tail snapshot; final
/// decoding always gets the entire buffer, never the previous caption text.
final class WhisperAudio {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var amplitude: Float = 0
    private var overflow = false
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    var duration: Double { lock.lock(); defer { lock.unlock() }; return Double(pcm.count) / 32000 }
    var level: Float { lock.lock(); defer { lock.unlock() }; return amplitude }

    func start() throws {
        let input = engine.inputNode
        let sourceFormat = input.inputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else { throw WhisperError("沒有可用的麥克風輸入裝置。") }
        inputFormat = sourceFormat
        converter = AVAudioConverter(from: sourceFormat, to: format)
        guard converter != nil else { throw WhisperError("無法建立 16 kHz 錄音轉換器。") }
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            if self.inputFormat != buffer.format {
                self.converter = AVAudioConverter(from: buffer.format, to: self.format)
                self.inputFormat = buffer.format
            }
            guard let converter = self.converter,
                  let output = AVAudioPCMBuffer(pcmFormat: self.format,
                    frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
            var peak: Int32 = 0
            for i in 0..<Int(output.frameLength) { peak = max(peak, abs(Int32(samples[i]))) }
            let bytes = Data(bytes: samples, count: Int(output.frameLength) * 2)
            self.lock.lock()
            if self.pcm.count + bytes.count <= 32000 * 30 * 60 { self.pcm.append(bytes) }
            else { self.overflow = true }
            self.amplitude = max(Float(peak) / 32768, self.amplitude * 0.75)
            self.lock.unlock()
        }
        tapInstalled = true
        do { try engine.start() } catch { stop(); throw error }
    }

    func stop() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    func snapshot(tailSeconds: Int? = nil) throws -> Data {
        lock.lock(); var bytes = pcm; let tooLong = overflow; lock.unlock()
        guard !tooLong else { throw WhisperError("單段錄音超過 30 分鐘，請分段口述；未輸出截斷文字。") }
        if let seconds = tailSeconds { bytes = WhisperWAV.tail(bytes, seconds: seconds) }
        return try WhisperWAV.encode(pcm: bytes)
    }

    deinit { stop() }
}
