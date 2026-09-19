import Foundation

@main
struct TranslationSessionTests {
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        func recording() -> TranslationSession {
            TranslationSession(appID: "com.example.editor", processID: 42, language: "英文")
        }
        func ready() -> TranslationSession {
            var session = recording()
            _ = session.beginTranscription(token: session.id, durationMs: 1200)
            _ = session.beginTranslation(token: session.id)
            _ = session.finish(text: "Hello", token: session.id)
            return session
        }

        var session = recording()
        check(session.selectLanguage("泰文", token: session.id), "recording accepts a language chip")
        check(session.language == "泰文", "chosen language stays on this session")
        check(session.beginTranscription(token: session.id, durationMs: 1500), "chip stops recording once")
        check(!session.beginTranscription(token: session.id, durationMs: 0), "shortcut release cannot stop twice")
        check(session.durationMs == 1500, "duplicate stop cannot reset duration")
        check(!session.selectLanguage("日文", token: session.id), "late chip cannot change in-flight language")
        check(session.beginTranslation(token: session.id), "transcription advances to translation")
        check(!session.beginTranslation(token: session.id), "duplicate STT result cannot start another request")
        check(session.finish(text: "สวัสดี", token: session.id), "translation result is buffered")
        check(session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: true) == nil,
              "chip cannot paste before the held shortcut is released")
        session.releaseHold(token: session.id)
        check(session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: false) == nil,
              "key-combo release still waits for Command or Option release")
        let delivery = session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: true)
        check(delivery?.destination == .originalApp && delivery?.text == "สวัสดี", "released shortcut delivers once")
        check(session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: true) == nil,
              "later key events cannot paste the result twice")
        check(!session.isActive, "completed session no longer blocks other shortcuts")

        var releasedFirst = recording()
        releasedFirst.releaseHold(token: releasedFirst.id)
        check(releasedFirst.beginTranscription(token: releasedFirst.id, durationMs: 2000), "ordinary release starts transcription")
        _ = releasedFirst.beginTranslation(token: releasedFirst.id)
        _ = releasedFirst.finish(text: "Result", token: releasedFirst.id)
        check(releasedFirst.takeDelivery(token: releasedFirst.id, frontmostPID: 42, modifiersReleased: true) != nil,
              "ordinary PTT uses the remembered language without chip selection")

        for stage in [TranslationSession.Phase.recording, .transcribing, .translating, .ready] {
            var cancelled = recording()
            if stage != .recording { _ = cancelled.beginTranscription(token: cancelled.id, durationMs: 1000) }
            if stage == .translating || stage == .ready { _ = cancelled.beginTranslation(token: cancelled.id) }
            if stage == .ready { _ = cancelled.finish(text: "Old result", token: cancelled.id) }
            check(cancelled.cancel(token: cancelled.id), "cancel succeeds during \(stage)")
            cancelled.releaseHold(token: cancelled.id)
            check(!cancelled.finish(text: "Late result", token: cancelled.id), "cancel ignores late completion during \(stage)")
            check(cancelled.takeDelivery(token: cancelled.id, frontmostPID: 42, modifiersReleased: true) == nil,
                  "cancel cannot inject during \(stage)")
        }

        var replacement = recording()
        let staleID = UUID()
        check(!replacement.selectLanguage("泰文", token: staleID), "old HUD cannot change a new session")
        check(!replacement.beginTranscription(token: staleID, durationMs: 1), "stale finish cannot stop a new recording")
        check(!replacement.beginTranslation(token: staleID), "stale STT cannot advance a new recording")
        check(!replacement.finish(text: "Old", token: staleID), "stale API cannot replace a new result")
        check(!replacement.cancel(token: staleID), "stale cancellation cannot cancel a new recording")
        replacement.releaseHold(token: staleID)
        check(!replacement.holdReleased, "stale release does not unlock a new recording")

        for frontmost: Int32? in [43, nil] {
            var switched = ready()
            switched.releaseHold(token: switched.id)
            check(switched.takeDelivery(token: switched.id, frontmostPID: frontmost, modifiersReleased: true)?.destination == .clipboard,
                  "changed or missing foreground app uses clipboard")
        }
        var unknownTarget = TranslationSession(appID: nil, processID: nil, language: "英文")
        _ = unknownTarget.beginTranscription(token: unknownTarget.id, durationMs: 1)
        _ = unknownTarget.beginTranslation(token: unknownTarget.id)
        _ = unknownTarget.finish(text: "Hello", token: unknownTarget.id)
        unknownTarget.releaseHold(token: unknownTarget.id)
        check(unknownTarget.takeDelivery(token: unknownTarget.id, frontmostPID: nil, modifiersReleased: true)?.destination == .clipboard,
              "two unknown PIDs never count as the same app")

        var empty = recording()
        _ = empty.beginTranscription(token: empty.id, durationMs: 1)
        _ = empty.beginTranslation(token: empty.id)
        check(!empty.finish(text: " \n ", token: empty.id), "empty translation is never a deliverable")
        print("\(checks - failures)/\(checks) translation lifecycle checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
