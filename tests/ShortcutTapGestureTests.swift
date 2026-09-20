import Foundation

@main
struct ShortcutTapGestureTests {
    enum Action: String, CaseIterable { case dictation, translate, correction, selectionQA }

    static func main() {
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        typealias Gesture = ShortcutTapGesture<Action>
        let command: UInt = 1
        let option: UInt = 2
        let shift: UInt = 4

        for action in Action.allCases {
            var modifier = Gesture()
            for tap in 1...2 {
                let down = modifier.modifierChanged(keyCode: 54, isDown: true,
                                                    modifiers: command, matchingAction: action)
                check(!down.consume && down.actionToToggle == nil, "\(action) modifier tap \(tap) waits for release")
                let up = modifier.modifierChanged(keyCode: 54, isDown: false,
                                                  modifiers: 0, matchingAction: nil)
                check(up.actionToToggle == action && !up.consume && up.releasedOwnership,
                      "\(action) modifier tap \(tap) fires exactly once on release")
            }
            var combo = Gesture()
            for tap in 1...2 {
                let down = combo.keyDown(keyCode: 12, isRepeat: false, matchingAction: action)
                check(down.consume && down.actionToToggle == nil && combo.ownsKey(12),
                      "\(action) combo tap \(tap) owns key without starting early")
                let up = combo.keyUp(keyCode: 12)
                check(up.consume && up.actionToToggle == action && up.releasedOwnership && !combo.hasOwnedKey,
                      "\(action) combo tap \(tap) fires after releasing ownership")
            }
        }

        var gesture = Gesture()
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        check(gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command,
                                      matchingAction: .translate).actionToToggle == nil,
              "duplicate modifier down cannot toggle")
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == .translate,
              "quick modifier tap needs no minimum duration")
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == nil,
              "duplicate modifier release cannot toggle twice")

        for (modifierKey, mask, typedKey, action) in [(54, command, 8, Action.translate),
                                                      (61, option, 35, .dictation),
                                                      (60, shift, 0, .correction)] {
            var nativeChord = Gesture()
            _ = nativeChord.modifierChanged(keyCode: modifierKey, isDown: true,
                                             modifiers: mask, matchingAction: action)
            check(!nativeChord.keyDown(keyCode: typedKey, isRepeat: false, matchingAction: nil).consume,
                  "native chord \(modifierKey)+\(typedKey) passes through")
            _ = nativeChord.keyUp(keyCode: typedKey)
            check(nativeChord.modifierChanged(keyCode: modifierKey, isDown: false, modifiers: 0,
                                               matchingAction: nil).actionToToggle == nil,
                  "native chord cannot become a recording tap on modifier release")
        }

        gesture = Gesture()
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        _ = gesture.modifierChanged(keyCode: 61, isDown: true, modifiers: command | option, matchingAction: nil)
        _ = gesture.modifierChanged(keyCode: 61, isDown: false, modifiers: command, matchingAction: nil)
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == nil,
              "additional modifier invalidates the whole original tap")

        gesture = Gesture()
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        _ = gesture.modifierChanged(keyCode: 55, isDown: true, modifiers: command, matchingAction: nil)
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: command,
                                      matchingAction: nil).actionToToggle == nil,
              "right Command release while left Command remains held does not toggle")
        _ = gesture.modifierChanged(keyCode: 55, isDown: false, modifiers: 0, matchingAction: nil)
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == .translate,
              "right Command works again after overlapping left Command clears")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        for _ in 0..<10 {
            let repeated = gesture.keyDown(keyCode: 12, isRepeat: true, matchingAction: .selectionQA)
            check(repeated.consume && repeated.actionToToggle == nil, "owned autorepeat stays swallowed")
        }
        check(gesture.keyUp(keyCode: 12).actionToToggle == .selectionQA,
              "ten autorepeats still produce only one tap")
        check(!gesture.keyUp(keyCode: 12).consume, "duplicate combo release has no remaining owner")

        gesture = Gesture()
        check(gesture.keyDown(keyCode: 12, isRepeat: true, matchingAction: .selectionQA).consume,
              "orphan autorepeat is consumed without arming a tap")
        let orphanUp = gesture.keyUp(keyCode: 12)
        check(orphanUp.consume && orphanUp.actionToToggle == nil && orphanUp.releasedOwnership,
              "orphan repeat release cannot start recording")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .translate)
        check(gesture.keyUp(keyCode: 12).actionToToggle == .selectionQA,
              "duplicate down and rebinding preserve the action captured by initial down")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        check(!gesture.keyDown(keyCode: 0, isRepeat: false, matchingAction: nil).consume,
              "unrelated typed key still reaches the app")
        check(gesture.keyUp(keyCode: 12).actionToToggle == nil,
              "an interrupted key gesture does not toggle later")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        check(gesture.keyDown(keyCode: 17, isRepeat: false, matchingAction: .translate).consume,
              "overlapping matched shortcut also owns its key")
        check(gesture.keyUp(keyCode: 12).actionToToggle == nil && gesture.hasOwnedKey,
              "first overlapped shortcut is invalid and does not release the second key")
        let secondUp = gesture.keyUp(keyCode: 17)
        check(secondUp.consume && secondUp.actionToToggle == nil && !gesture.hasOwnedKey,
              "overlapping recording shortcuts cannot trigger two actions")

        gesture = Gesture()
        _ = gesture.modifierChanged(keyCode: 61, isDown: true, modifiers: option, matchingAction: .dictation)
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        _ = gesture.modifierChanged(keyCode: 61, isDown: false, modifiers: 0, matchingAction: nil)
        check(gesture.hasOwnedKey && gesture.keyUp(keyCode: 12).actionToToggle == .selectionQA,
              "releasing required modifier before the owned combo key still commits one combo tap")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        _ = gesture.modifierChanged(keyCode: 60, isDown: true, modifiers: shift, matchingAction: .correction)
        check(gesture.keyUp(keyCode: 12).actionToToggle == nil,
              "adding a new modifier while a combo key is held invalidates its tap")
        check(gesture.modifierChanged(keyCode: 60, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == nil,
              "extra modifier during an owned combo does not arm a second action")

        gesture = Gesture()
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        gesture.invalidateModifierCandidate()
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == nil,
              "mouse or native chord invalidation cannot fire on later release")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        gesture.cancelPendingGestures()
        check(gesture.hasOwnedKey && gesture.keyDown(keyCode: 12, isRepeat: true,
                                                    matchingAction: nil).consume,
              "HUD cancel or Preferences bypass retains owned repeat swallowing")
        let cancelledUp = gesture.keyUp(keyCode: 12)
        check(cancelledUp.consume && cancelledUp.actionToToggle == nil && cancelledUp.releasedOwnership,
              "cancelled combo release is consumed without restarting recording")

        gesture = Gesture()
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        gesture.cancelPendingGestures()
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == nil,
              "cancelled modifier cannot be rearmed by a duplicate down after bypass")
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: nil)
        _ = gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0, matchingAction: nil)
        _ = gesture.modifierChanged(keyCode: 54, isDown: true, modifiers: command, matchingAction: .translate)
        check(gesture.modifierChanged(keyCode: 54, isDown: false, modifiers: 0,
                                      matchingAction: nil).actionToToggle == .translate,
              "observing bypassed modifier edges lets the next normal tap work")

        gesture = Gesture()
        _ = gesture.keyDown(keyCode: 12, isRepeat: false, matchingAction: .selectionQA)
        gesture.reset()
        check(!gesture.hasOwnedKey && !gesture.keyUp(keyCode: 12).consume,
              "stopping the event tap clears all ownership")

        print("\(checks - failures)/\(checks) shortcut tap gesture checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
