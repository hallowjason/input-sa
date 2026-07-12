import AVFoundation

/// Polls an AVAudioRecorder's built-in metering while it records and reports
/// a normalized 0...1 amplitude via callback, ~30 times/sec. Shared by all
/// three voice providers (Sherpa/Groq/Google) so the live pixel waveform in
/// the HUD behaves identically regardless of which STT backend is active.
///
/// Uses AVAudioRecorder.averagePower(forChannel:) rather than an
/// AVAudioEngine tap — every provider already owns an AVAudioRecorder for
/// file-based recording, and metering is a built-in capability of that same
/// object. This gives "volume reacts while speaking" without a second,
/// independent audio capture path.
final class AudioLevelMeter {
    private var timer: Timer?
    private weak var recorder: AVAudioRecorder?

    /// Called on the main thread with a normalized level in 0...1.
    var onLevel: ((Float) -> Void)?

    func start(recorder: AVAudioRecorder) {
        recorder.isMeteringEnabled = true
        self.recorder = recorder
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder, rec.isRecording else { return }
            rec.updateMeters()
            self.onLevel?(Self.normalize(rec.averagePower(forChannel: 0)))
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        onLevel?(0)
    }

    /// Maps typical speech dBFS (~-50 near-silence ... 0 loud) to 0...1.
    private static func normalize(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let minDb: Float = -50
        let clamped = max(minDb, min(0, db))
        return (clamped - minDb) / -minDb
    }
}
