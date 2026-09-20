import Foundation

/// Main-thread translation lifecycle, independent of microphone and keyboard APIs.
/// The source must be visible before an explicit language choice can translate it.
/// The original app belongs to one recording; callbacks must carry its id.
struct TranslationSession {
    enum Phase { case recording, transcribing, awaitingLanguage, translating, ready, completed, cancelled }
    enum Destination { case originalApp, clipboard }
    struct Delivery {
        let text: String
        let destination: Destination
    }

    let id = UUID()
    let appID: String?
    let processID: Int32?
    private(set) var language: String?
    private(set) var sourceText: String?
    private(set) var phase: Phase = .recording
    private(set) var holdReleased = false
    private(set) var durationMs = 0
    private(set) var outputText: String?

    init(appID: String?, processID: Int32?) {
        self.appID = appID
        self.processID = processID
    }

    var isActive: Bool { phase != .completed && phase != .cancelled }

    mutating func selectLanguage(_ language: String, token: UUID) -> Bool {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == id, phase == .awaitingLanguage, !trimmed.isEmpty else { return false }
        self.language = trimmed
        phase = .translating
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

    mutating func finishTranscription(text: String, token: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == id, phase == .transcribing, !trimmed.isEmpty else { return false }
        sourceText = trimmed
        phase = .awaitingLanguage
        return true
    }

    mutating func finish(text: String, token: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == id, phase == .translating, !trimmed.isEmpty,
              let sourceText else { return false }
        // Assemble locally: the lower block is exactly the previewed source,
        // never a model-generated back-translation or an extra API request.
        outputText = "\(trimmed)\n(\(sourceText))"
        phase = .ready
        return true
    }

    @discardableResult
    mutating func cancel(token: UUID) -> Bool {
        guard token == id, isActive else { return false }
        sourceText = nil
        outputText = nil
        phase = .cancelled
        return true
    }

    /// Claim a result only after the physical shortcut and all modifiers are up.
    /// A missing target or changed process never receives a synthetic paste.
    mutating func takeDelivery(token: UUID, frontmostPID: Int32?, modifiersReleased: Bool) -> Delivery? {
        guard token == id, phase == .ready, holdReleased, modifiersReleased,
              let text = outputText else { return nil }
        phase = .completed
        sourceText = nil
        outputText = nil
        let sameApp = processID != nil && processID == frontmostPID
        return Delivery(text: text, destination: sameApp ? .originalApp : .clipboard)
    }
}
