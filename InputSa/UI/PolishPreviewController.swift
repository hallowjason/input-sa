import AppKit

/// Tracks accept/reject state for a polish-preview session.
/// InputController wires onAccept / onReject once at startup.
/// Accept: Return / Tab.  Reject: Escape.
final class PolishPreviewController {

    enum State {
        case idle
        case previewing(original: String, enhanced: String)
    }

    private(set) var state: State = .idle

    var onAccept: ((String) -> Void)?
    var onReject: (() -> Void)?

    func startPreview(original: String, enhanced: String) {
        state = .previewing(original: original, enhanced: enhanced)
    }

    func accept() {
        if case .previewing(_, let enhanced) = state { onAccept?(enhanced) }
        state = .idle
    }

    func reject() {
        state = .idle
        onReject?()
    }

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }
}
