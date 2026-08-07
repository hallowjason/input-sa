import AppKit
import ApplicationServices

/// Reads the user's currently-selected text, for the three select-and-act
/// features (⌥P 選字潤飾, ⌃⌥Q 劃詞問答, ⌃⌥T 劃詞翻譯).
///
/// Two layers, tried in order:
///   1. Accessibility (AX) — the focused element's kAXSelectedText. Free and
///      instant when the app exposes it (native text fields, TextEdit, most
///      Cocoa apps).
///   2. Synthetic ⌘C fallback — for apps whose AX selection is empty or
///      unavailable (Electron, some terminals, web views). We deep-copy the
///      pasteboard, fire ⌘C, poll the changeCount, read the string, and ALWAYS
///      restore the snapshot before returning on every path.
///
/// ⚠️ Known edge case: the synthetic ⌘C flows back through this app's own
/// CGEventTap. If the user has bound their custom voice shortcut to exactly ⌘C
/// (keyCode 8 + Command), the fallback would spuriously trigger it. This is
/// accepted — ⌘C is a near-universal Copy binding no one reassigns to dictation.
enum SelectionReader {

    /// Returns the selected text (trimmed, non-empty) or nil if nothing is
    /// selected / could be read.
    static func read() -> String? {
        if let ax = readViaAX() { return ax }
        return readViaSyntheticCopy()
    }

    // MARK: - Layer 1: Accessibility

    private static func readViaAX() -> String? {
        let sys = AXUIElementCreateSystemWide()
        // Bound the AX round-trip. The default messaging timeout is ~6 s, and an
        // app that is busy or wedged makes every call wait it out. That wait used
        // to happen on the event-tap callback, i.e. with the whole keyboard held
        // behind it — the user sees the machine freeze, then macOS times the tap
        // out and flushes every key that piled up during the stall in one burst.
        // 250 ms is far longer than a healthy app needs and short enough to feel
        // like nothing happened when one is not.
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }

        var selVal: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selVal) == .success,
              let text = selVal as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Layer 2: Synthetic ⌘C fallback

    private static func readViaSyntheticCopy() -> String? {
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)   // deep copy — own machinery, never
                                                 // touches InputController's restore token
        let beforeCount = pb.changeCount

        guard postCmdC() else {
            // Couldn't synthesize the event — nothing changed, snapshot intact.
            return nil
        }

        // Poll the changeCount up to ~350 ms (30 ms steps). ⌘C is fast in most
        // apps; a longer budget just adds latency when there's no selection.
        //
        // usleep (not RunLoop.run): this runs synchronously inside the event-tap
        // callback, so nesting the runloop would let OUR OWN synthetic ⌘C — and
        // any real key events (e.g. the Q keyUp that ends a 劃詞問答 hold) — be
        // delivered re-entrantly, stranding half-built state. Blocking the thread
        // instead makes those events queue and process in order after we return;
        // the target app copies in its own process regardless of our sleep.
        var changed = false
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            usleep(30_000)   // 30 ms
            if pb.changeCount != beforeCount { changed = true; break }
        }

        guard changed else {
            // No copy happened ⇒ no selection. Restore (a no-op write that keeps
            // the original contents byte-for-byte) and bail.
            restorePasteboard(snapshot, to: pb)
            return nil
        }

        let copied = pb.string(forType: .string)
        restorePasteboard(snapshot, to: pb)   // restore BEFORE returning on every path
        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Synthesize a ⌘C keystroke (C = keyCode 0x08), same event-source pattern as
    /// InputController.pasteViaCmdV. Returns false if the events couldn't be built.
    private static func postCmdC() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    // MARK: - Pasteboard snapshot (independent of InputController's copy)

    /// Deep-copy every item/type on the pasteboard into fresh NSPasteboardItems
    /// that survive a clearContents(). Mirrors InputController.snapshotPasteboard
    /// but is a standalone implementation on purpose — this reader must not share
    /// state with the injection restore machinery.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ items: [NSPasteboardItem], to pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
