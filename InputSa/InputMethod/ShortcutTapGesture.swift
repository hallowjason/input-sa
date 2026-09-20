/// Recognizes a complete shortcut tap without knowing about recording sessions.
/// The controller supplies exact binding matches and physical modifier edges;
/// this type never reads AppKit state, starts a microphone, or schedules work.
///
/// Feed every modifier edge, even during Preferences/shortcut-capture bypass
/// (with `matchingAction: nil`), so a held key cannot become a fresh tap later.
/// Normal key events already owned here must also arrive before any bypass.
struct ShortcutTapGesture<Action: Equatable> {
    struct Result {
        let consume: Bool
        let actionToToggle: Action?
        let releasedOwnership: Bool

        fileprivate init(consume: Bool = false, actionToToggle: Action? = nil,
                         releasedOwnership: Bool = false) {
            self.consume = consume
            self.actionToToggle = actionToToggle
            self.releasedOwnership = releasedOwnership
        }
    }

    private struct ModifierCandidate {
        let action: Action
        let keyCode: Int
        let modifiers: UInt
        var mayFire = true
    }

    private struct KeyCandidate {
        let action: Action
        var mayFire: Bool
    }

    private var modifierCandidate: ModifierCandidate?
    private var pressedModifiers: Set<Int> = []
    private var ownedKeys: [Int: KeyCandidate] = [:]

    var hasOwnedKey: Bool { !ownedKeys.isEmpty }
    func ownsKey(_ keyCode: Int) -> Bool { ownedKeys[keyCode] != nil }

    /// A matched normal key is owned until keyUp, including after cancellation.
    /// Repeats never arm an action. Unrelated typing invalidates a pending tap
    /// but still passes through to the foreground application.
    mutating func keyDown(keyCode: Int, isRepeat: Bool, matchingAction: Action?) -> Result {
        invalidateModifierCandidate()
        if ownsKey(keyCode) { return Result(consume: true) }

        let hadOwnedKey = hasOwnedKey
        invalidateOwnedKeys()
        guard let action = matchingAction else { return Result() }
        // Own even an orphan repeat, but never turn its eventual release into
        // a tap. This also prevents that release from leaking into the editor.
        ownedKeys[keyCode] = KeyCandidate(action: action, mayFire: !isRepeat && !hadOwnedKey)
        return Result(consume: true)
    }

    /// Removes ownership before returning the action, allowing the controller
    /// to stop recording and safely evaluate delivery after this event exits.
    mutating func keyUp(keyCode: Int) -> Result {
        guard let candidate = ownedKeys.removeValue(forKey: keyCode) else { return Result() }
        return Result(consume: true,
                      actionToToggle: candidate.mayFire ? candidate.action : nil,
                      releasedOwnership: true)
    }

    /// `isDown` refers to this physical key, not an aggregate Command/Option
    /// flag: left and right modifiers can be held simultaneously. `modifiers`
    /// is the device-independent mask used by the controller's exact matcher.
    /// Bare modifiers pass through so native macOS chords keep working.
    mutating func modifierChanged(keyCode: Int, isDown: Bool, modifiers: UInt,
                                  matchingAction: Action?) -> Result {
        let wasDown = pressedModifiers.contains(keyCode)
        if isDown { pressedModifiers.insert(keyCode) }
        else { pressedModifiers.remove(keyCode) }
        let changed = wasDown != isDown

        if changed && isDown { invalidateOwnedKeys() }

        if var candidate = modifierCandidate {
            if changed && !isDown && keyCode == candidate.keyCode {
                modifierCandidate = nil
                return Result(actionToToggle: candidate.mayFire && modifiers == 0
                              ? candidate.action : nil, releasedOwnership: true)
            }
            if (changed && keyCode != candidate.keyCode) || modifiers != candidate.modifiers {
                candidate.mayFire = false
            }
            modifierCandidate = candidate
            return Result()
        }

        guard changed, isDown, pressedModifiers.count == 1, !hasOwnedKey,
              let action = matchingAction else { return Result() }
        modifierCandidate = ModifierCandidate(action: action, keyCode: keyCode, modifiers: modifiers)
        return Result()
    }

    /// Use for mouse clicks or native chords involving the candidate modifier.
    /// Keep the candidate until its release so duplicate flags cannot rearm it.
    mutating func invalidateModifierCandidate() {
        modifierCandidate?.mayFire = false
    }

    /// Use on HUD cancellation, focus/capture bypass, or session cancellation.
    /// Do not drop physical ownership: a previously swallowed keyDown still
    /// requires swallowing repeats and keyUp, with no action on that release.
    mutating func cancelPendingGestures() {
        invalidateModifierCandidate()
        invalidateOwnedKeys()
    }

    /// Only use when the event tap stops, since no later keyUp will be handled.
    mutating func reset() {
        modifierCandidate = nil
        pressedModifiers.removeAll()
        ownedKeys.removeAll()
    }

    private mutating func invalidateOwnedKeys() {
        for keyCode in Array(ownedKeys.keys) { ownedKeys[keyCode]?.mayFire = false }
    }
}
