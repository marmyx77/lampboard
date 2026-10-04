import Foundation
import LampBoardCore

/// The Plancia's state (UX §5, D79): which session is open beside the list, its
/// conversation, and whether it is pinned open.
///
/// The conversation is the chat window's own `ChatSession`, with its mailbox
/// opened and released the way the chat window does it (D15): the same reader,
/// the same composer when sending is on, nothing written twice.
@MainActor
final class PlanciaModel: ObservableObject {

    @Published private(set) var sessionId: String?
    @Published private(set) var thread: ChatSession?
    @Published var pinned = false
    /// Whether it opens to the left of the list, chosen at opening.
    var leading = false

    private let mailbox = MailboxWriter()

    var isOpen: Bool { sessionId != nil }

    func open(_ session: SessionState, store: StateStore) {
        guard session.id != sessionId else { return }
        release()
        let chat = ChatSession(session: session, store: store, mailbox: mailbox)
        if case .failure(let error) = mailbox.open(sessionId: session.id) {
            Diagnostics.log("plancia \(session.id): mailbox not opened: \(error.description)")
        }
        chat.start()
        chat.markRead()
        thread = chat
        sessionId = session.id
    }

    func close() {
        release()
        sessionId = nil
        thread = nil
        pinned = false
    }

    private func release() {
        thread?.stop()
        if let sessionId, !mailbox.close(sessionId: sessionId) {
            Diagnostics.log("plancia \(sessionId): message still pending, listener left armed")
        }
    }
}
