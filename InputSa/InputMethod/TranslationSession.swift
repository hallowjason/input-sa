import Foundation

/// Main-thread translation lifecycle, independent of microphone and keyboard APIs.
/// The original app and language belong to one recording; callbacks must carry its id.
struct TranslationSession {
    enum Phase { case recording, transcribing, translating, ready, completed, cancelled }
    enum Destination { case originalApp, clipboard }
    struct Delivery {
        let text: String
        let destination: Destination
    }

    let id = UUID()
    let appID: String?
    let processID: Int32?
    private(set) var language: String
    private(set) var phase: Phase = .recording
    private(set) var holdReleased = false
    private(set) var durationMs = 0
    private var result: String?

    init(appID: String?, processID: Int32?, language: String) {
        self.appID = appID
        self.processID = processID
        self.language = language
    }

    var isActive: Bool { phase != .completed && phase != .cancelled }

    mutating func selectLanguage(_ language: String, token: UUID) -> Bool {
        guard token == id, phase == .recording, !language.isEmpty else { return false }
        self.language = language
        return true
    }

    mutating func beginTranscription(token: UUID, durationMs: Int) -> Bool {
        guard token == id, phase == .recording else { return false }
        self.durationMs = max(0, durationMs)
        phase = .transcribing
        return true
    }

    mutating func releaseHold(token: UUID) {
        guard token == id else { return }
        holdReleased = true
    }

    mutating func beginTranslation(token: UUID) -> Bool {
        guard token == id, phase == .transcribing else { return false }
        phase = .translating
        return true
    }

    mutating func finish(text: String, token: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == id, phase == .translating, !trimmed.isEmpty else { return false }
        result = trimmed
        phase = .ready
        return true
    }

    @discardableResult
    mutating func cancel(token: UUID) -> Bool {
        guard token == id, isActive else { return false }
        result = nil
        phase = .cancelled
        return true
    }

    /// Claim a result only after the physical shortcut and all modifiers are up.
    /// A missing target or changed process never receives a synthetic paste.
    mutating func takeDelivery(token: UUID, frontmostPID: Int32?, modifiersReleased: Bool) -> Delivery? {
        guard token == id, phase == .ready, holdReleased, modifiersReleased,
              let text = result else { return nil }
        phase = .completed
        result = nil
        let sameApp = processID != nil && processID == frontmostPID
        return Delivery(text: text, destination: sameApp ? .originalApp : .clipboard)
    }
}
