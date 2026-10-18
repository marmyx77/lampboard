import Foundation
import LampBoardCore

/// The panel's acts on another machine's rows, told to that machine's `lampd`
/// (W5, §2.12), and the same acts arriving from it, told to nobody.
extension StateStore {

    func tellNode(_ action: V1Action, _ sessionId: String) {
        guard let onNodeChoice, let host = state.sessions[sessionId]?.workspace.host else { return }
        onNodeChoice(V1Command(action: action, session: sessionId), host)
    }

    /// A read made on the phone, as the node's `lampd` says it: the panel's row
    /// is read too, and nothing is told back.
    func markSeenFromNode(sessionId: String) {
        apply(.markSeen(sessionId: sessionId), now: clock())
    }

    func markUnreadFromNode(sessionId: String) {
        apply(.markUnread(sessionId: sessionId), now: clock())
    }
}
