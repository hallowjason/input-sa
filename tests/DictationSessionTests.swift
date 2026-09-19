import Foundation

@main
struct DictationSessionTests {
    static func main() {
        let snapshot = VoiceTranscriptionSnapshot(rawText: "三点，啊不对四点", normalizedText: "三點，啊不對四點", engine: "test")
        var session = DictationSession(appID: "editor", appName: "Editor", processID: 12)
        let token = session.id
        precondition(session.beginTranscription(token: token, durationMs: 1800))
        precondition(!session.beginTranscription(token: token, durationMs: 1900))
        precondition(!session.receive(snapshot, token: UUID()))
        precondition(session.receive(snapshot, token: token))
        precondition(session.finish(text: "4點", aiText: "4點", token: token))
        precondition(session.takeDelivery(token: token, frontmostPID: 12, modifiersReleased: false) == nil)
        precondition(session.takeDelivery(token: token, frontmostPID: 13, modifiersReleased: true)?.destination == .clipboard)
        precondition(session.takeDelivery(token: token, frontmostPID: 12, modifiersReleased: true) == nil)
        precondition(session.snapshot?.rawText == snapshot.rawText)
        precondition(session.durationMs == 1800)
        var cancelled = DictationSession(appID: nil, appName: nil, processID: nil)
        precondition(cancelled.beginTranscription(token: cancelled.id, durationMs: 1000))
        cancelled.cancel(token: cancelled.id)
        precondition(!cancelled.receive(snapshot, token: cancelled.id))
        precondition(!cancelled.finish(text: "late", aiText: nil, token: cancelled.id))
        precondition(!cancelled.isActive)
        var empty = DictationSession(appID: nil, appName: nil, processID: nil)
        _ = empty.beginTranscription(token: empty.id, durationMs: 1000)
        _ = empty.receive(snapshot, token: empty.id)
        precondition(!empty.finish(text: " \n", aiText: nil, token: empty.id))
        precondition(empty.finish(text: snapshot.normalizedText, aiText: nil, fallbackReason: "offline", token: empty.id))
        precondition(empty.takeDelivery(token: empty.id, frontmostPID: nil, modifiersReleased: true)?.destination == .clipboard)
        precondition(empty.fallbackReason == "offline")
        print("DictationSessionTests: 18/18 passed")
    }
}
