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
    /// LampMaster's own Plancia (UX §4, §5): its cards, today, its frame, its
    /// cost — in the panel, as the person asked, never a window of its own.
    @Published private(set) var showsLampMaster = false
    /// The sheet LampMaster's Plancia opens on.
    private(set) var lampMasterSheet: LampMasterPlanciaContent.Sheet = .suggestions
    /// Whether it opens to the left of the list, chosen at opening.
    var leading = false

    /// Gated by the same switch as the chat window's composer (D15, D81).
    private let mailbox = MailboxWriter { Preferences().messageSendingEnabled }

    var isOpen: Bool { sessionId != nil || showsLampMaster }

    func openLampMaster(sheet: LampMasterPlanciaContent.Sheet = .suggestions) {
        release()
        thread = nil
        sessionId = nil
        lampMasterSheet = sheet
        showsLampMaster = true
    }

    func open(_ session: SessionState, store: StateStore) {
        guard session.id != sessionId else { return }
        release()
        showsLampMaster = false
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
        showsLampMaster = false
    }

    private func release() {
        thread?.stop()
        if let sessionId, !mailbox.close(sessionId: sessionId) {
            Diagnostics.log("plancia \(sessionId): message still pending, listener left armed")
        }
    }
}
