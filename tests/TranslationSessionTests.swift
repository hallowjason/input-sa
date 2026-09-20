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
            TranslationSession(appID: "com.example.editor", processID: 42)
        }
        func awaitingChoice(source: String = "今天天氣很好") -> TranslationSession {
            var session = recording()
            _ = session.beginTranscription(token: session.id, durationMs: 1200)
            _ = session.finishTranscription(text: source, token: session.id)
            return session
        }
        func ready() -> TranslationSession {
            var session = awaitingChoice()
            _ = session.selectLanguage("英文", token: session.id)
            _ = session.finish(text: "Today's weather is good.", token: session.id)
            return session
        }

        var session = recording()
        check(session.language == nil, "new recording has no preselected language")
        check(!session.selectLanguage("泰文", token: session.id), "recording cannot choose language before seeing source")
        check(!session.finishTranscription(text: "過早原文", token: session.id), "recording ignores premature STT result")
        session.releaseHold(token: session.id)
        check(session.beginTranscription(token: session.id, durationMs: 1500), "release starts transcription")
        check(!session.beginTranscription(token: session.id, durationMs: 0), "duplicate release cannot stop twice")
        check(session.durationMs == 1500, "duplicate stop cannot reset duration")
        check(!session.selectLanguage("英文", token: session.id), "transcribing cannot choose language before source is ready")
        check(session.finishTranscription(text: "  今天天氣很好\n", token: session.id), "STT finishes into source preview")
        check(session.phase == .awaitingLanguage && session.isActive, "preview waits and keeps session active")
        check(session.sourceText == "今天天氣很好" && session.language == nil, "source visible without a target language")
        check(!session.finish(text: "Premature result", token: session.id), "no translation result accepted before a click")
        check(session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: true) == nil,
              "released shortcut cannot send a preview without choosing language")
        session.releaseHold(token: session.id)
        check(session.phase == .awaitingLanguage, "repeated modifier release keeps waiting for explicit choice")
        check(!session.finishTranscription(text: "Old source", token: session.id), "duplicate STT cannot replace visible source")
        check(!session.selectLanguage(" \n ", token: session.id), "empty language is not a choice")
        check(session.selectLanguage("英文", token: session.id), "explicit language click starts translation")
        check(session.phase == .translating && session.language == "英文", "chosen language captured for request")
        check(!session.selectLanguage("日文", token: session.id), "double click cannot start another request")
        check(session.finish(text: "  Today's weather is good.\n", token: session.id), "translation buffered with source")
        let expected = "Today's weather is good.\n(今天天氣很好)"
        check(session.outputText == expected, "translated block first, original Chinese below in ASCII parentheses")
        check(!session.finish(text: "Duplicate", token: session.id), "duplicate completion cannot overwrite result")
        check(session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: false) == nil,
              "wait for Command or Option release before pasting")
        let delivery = session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: true)
        check(delivery?.destination == .originalApp && delivery?.text == expected, "both blocks delivered together to original app")
        check(session.takeDelivery(token: session.id, frontmostPID: 42, modifiersReleased: true) == nil,
              "later key events cannot paste twice")
        check(!session.isActive && session.sourceText == nil && session.outputText == nil,
              "completed session releases source and result")

        var finishedBeforeRelease = ready()
        check(finishedBeforeRelease.takeDelivery(token: finishedBeforeRelease.id, frontmostPID: 42, modifiersReleased: true) == nil,
              "finish-recording button cannot paste while physical shortcut is held")
        finishedBeforeRelease.releaseHold(token: finishedBeforeRelease.id)
        check(finishedBeforeRelease.takeDelivery(token: finishedBeforeRelease.id, frontmostPID: 42, modifiersReleased: true)?.text == expected,
              "explicit choice completed during hold sends after release")

        for stage in [TranslationSession.Phase.recording, .transcribing, .awaitingLanguage, .translating, .ready] {
            var cancelled = recording()
            if stage != .recording { _ = cancelled.beginTranscription(token: cancelled.id, durationMs: 1000) }
            if [.awaitingLanguage, .translating, .ready].contains(stage) {
                _ = cancelled.finishTranscription(text: "取消的原文", token: cancelled.id)
            }
            if stage == .translating || stage == .ready { _ = cancelled.selectLanguage("英文", token: cancelled.id) }
            if stage == .ready { _ = cancelled.finish(text: "Old result", token: cancelled.id) }
            check(cancelled.cancel(token: cancelled.id), "cancel succeeds during \(stage)")
            cancelled.releaseHold(token: cancelled.id)
            check(!cancelled.selectLanguage("日文", token: cancelled.id)
                  && !cancelled.finishTranscription(text: "Late source", token: cancelled.id)
                  && !cancelled.finish(text: "Late result", token: cancelled.id), "cancel ignores late callbacks during \(stage)")
            check(cancelled.takeDelivery(token: cancelled.id, frontmostPID: 42, modifiersReleased: true) == nil,
                  "cancel cannot inject during \(stage)")
            check(cancelled.sourceText == nil && cancelled.outputText == nil, "cancel releases text during \(stage)")
        }

        var replacement = awaitingChoice()
        let staleID = UUID()
        check(!replacement.selectLanguage("泰文", token: staleID), "old HUD cannot translate a new session")
        check(!replacement.beginTranscription(token: staleID, durationMs: 1), "stale finish cannot stop new recording")
        check(!replacement.finishTranscription(text: "Old source", token: staleID), "stale STT cannot replace source")
        check(!replacement.finish(text: "Old result", token: staleID), "stale API cannot replace result")
        check(!replacement.cancel(token: staleID), "stale cancellation cannot cancel new recording")
        replacement.releaseHold(token: staleID)
        check(!replacement.holdReleased, "stale release does not unlock new recording")

        for frontmost: Int32? in [43, nil] {
            var switched = ready()
            switched.releaseHold(token: switched.id)
            let copied = switched.takeDelivery(token: switched.id, frontmostPID: frontmost, modifiersReleased: true)
            check(copied?.destination == .clipboard && copied?.text == expected,
                  "changed or missing foreground app copies both blocks")
        }
        var unknownTarget = TranslationSession(appID: nil, processID: nil)
        _ = unknownTarget.beginTranscription(token: unknownTarget.id, durationMs: 1)
        _ = unknownTarget.finishTranscription(text: "今天天氣很好", token: unknownTarget.id)
        _ = unknownTarget.selectLanguage("英文", token: unknownTarget.id)
        _ = unknownTarget.finish(text: "Today's weather is good.", token: unknownTarget.id)
        unknownTarget.releaseHold(token: unknownTarget.id)
        check(unknownTarget.takeDelivery(token: unknownTarget.id, frontmostPID: nil, modifiersReleased: true)?.destination == .clipboard,
              "two unknown PIDs never count as same app")

        var empty = recording()
        _ = empty.beginTranscription(token: empty.id, durationMs: 1)
        check(!empty.finishTranscription(text: " \n ", token: empty.id), "empty transcript cannot enable language buttons")
        empty = awaitingChoice()
        _ = empty.selectLanguage("英文", token: empty.id)
        check(!empty.finish(text: " \n ", token: empty.id), "empty translation cannot send source alone")

        let source = "明天三點，啊不對，是四點。\n帶上 Codex、Claude（最新版）。"
        var multiline = awaitingChoice(source: source)
        _ = multiline.selectLanguage("英文", token: multiline.id)
        let translated = "Tomorrow at 4.\nBring Codex and Claude (latest versions)."
        _ = multiline.finish(text: translated, token: multiline.id)
        check(multiline.outputText == "\(translated)\n(\(source))",
              "multi-paragraph output preserves original wording, corrections, English and punctuation")
        check(recording().language == nil, "next recording never inherits previous explicit choice")
        print("\(checks - failures)/\(checks) translation lifecycle checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
