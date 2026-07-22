import AVFoundation
import Foundation

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
///
/// start()/stop() bracket the recording exactly (every provider calls them on
/// record-begin / stop / cancel), so this is also where the App Nap guard
/// lives: Input-sa is an LSUIElement background agent, and macOS can throttle
/// a napped background process' run loop / timers mid-recording, contributing
/// to the "records fine here, drops out on a friend's Mac" instability. A
/// `beginActivity(.userInitiated)` assertion held for the recording's duration
/// keeps the process fully scheduled while the mic is open.
final class AudioLevelMeter {
    private var timer: Timer?
    private weak var recorder: AVAudioRecorder?
    private var activity: NSObjectProtocol?

    /// Called on the main thread with a normalized level in 0...1.
    var onLevel: ((Float) -> Void)?

    func start(recorder: AVAudioRecorder) {
        // Hold an activity assertion for the whole recording so App Nap can't
        // throttle this background agent while the mic is capturing.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Input-sa voice recording")
        }
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
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
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
