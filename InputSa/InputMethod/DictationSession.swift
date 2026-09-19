import Foundation

/// One recording owns its complete pipeline until delivery or cancellation.
/// Immutable stage snapshots survive AI changes; stale callbacks cannot deliver.
struct DictationSession {
    enum Phase { case recording, transcribing, polishing, ready, completed, cancelled }
    enum Destination { case originalApp, clipboard }
    struct Delivery { let text: String; let destination: Destination }

    let id = UUID()
    let date = Date()
    let appID: String?
    let appName: String?
    let processID: Int32?
    private(set) var phase: Phase = .recording
    private(set) var durationMs = 0
    private(set) var snapshot: VoiceTranscriptionSnapshot?
    private(set) var aiText: String?
    private(set) var finalText: String?
    private(set) var fallbackReason: String?

    var isActive: Bool { phase != .cancelled && phase != .completed }

    mutating func beginTranscription(token: UUID, durationMs: Int) -> Bool {
        guard id == token, phase == .recording else { return false }
        self.durationMs = max(0, durationMs)
        phase = .transcribing
        return true
    }

    mutating func receive(_ snapshot: VoiceTranscriptionSnapshot, token: UUID) -> Bool {
        guard id == token, phase == .transcribing else { return false }
        self.snapshot = snapshot
        phase = .polishing
        return true
    }

    mutating func finish(text: String, aiText: String?, fallbackReason: String? = nil, token: UUID) -> Bool {
        guard id == token, phase == .polishing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        self.aiText = aiText
        self.finalText = text
        self.fallbackReason = fallbackReason
        phase = .ready
        return true
    }

    mutating func takeDelivery(token: UUID, frontmostPID: Int32?, modifiersReleased: Bool) -> Delivery? {
        guard id == token, phase == .ready, modifiersReleased, let text = finalText else { return nil }
        phase = .completed
        let destination: Destination = processID != nil && processID == frontmostPID ? .originalApp : .clipboard
        return Delivery(text: text, destination: destination)
    }

    mutating func cancel(token: UUID) {
        guard id == token, isActive else { return }
        phase = .cancelled
    }
}
