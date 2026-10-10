import Combine
import Foundation
import LampBoardCore
import SwiftUI

/// What the Hub needs from the rest of the app, handed in once (D149).
struct HubDependencies {
    let store: StateStore
    let queue: WaitingQueueModel
    let lampMaster: LampMasterService?
    let lampMasterActions: LampMasterActions?
    /// The panel's own view, rows and all, with a click that selects here (D150).
    let sidebar: (_ select: @escaping (String) -> Void) -> AnyView
    /// Where a session's transcript is read from, here or on its machine.
    let chatSource: (String) -> LiveChatModel.Source?
    /// What the Hub knows of a session when Send is pressed (D154).
    let situation: (String) -> HubWrite.Situation
    /// Sends through the route `HubWrite` chose; `false` when nothing went.
    let send: (_ session: String, _ text: String, _ route: HubWrite.Route, _ mode: HubWrite.Mode) -> Bool
    /// The same engine as a click in the panel: the session's own window.
    let openRealWindow: (String) -> Void
}

/// The Hub's state: which conversation is open, which sessions take signed
/// commands, what Send does.
@MainActor
final class HubModel: ObservableObject {

    /// LampMaster's row, above the sessions (D151).
    static let lampMasterId = "lampmaster"

    @Published var selected: String?
    @Published private(set) var commandable: Set<String> = []
    @Published private(set) var chat: LiveChatModel?
    @Published var mode: HubWrite.Mode {
        didSet { Preferences.sharedDefaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// What the composer said about the last send.
    @Published var notice: String?

    let deps: HubDependencies
    private var chatFor: String?
    private var cancellables = Set<AnyCancellable>()

    private static let modeKey = "hubSendMode"

    init(deps: HubDependencies) {
        self.deps = deps
        self.mode = Preferences.sharedDefaults.string(forKey: Self.modeKey).flatMap(HubWrite.Mode.init(rawValue:)) ?? .queue
        $selected.removeDuplicates().sink { [weak self] id in self?.openChat(for: id) }.store(in: &cancellables)
        // Once a second, as the live view does: whether Send can go now.
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshSendable() }
            .store(in: &cancellables)
    }

    /// A report from a session's mod: the sessions that say they take commands.
    func heard(_ report: ModReport) {
        switch report {
        case .start(let session, let start):
            if start.features.contains("commands") { commandable.insert(session) } else { commandable.remove(session) }
        case .end(let session, _):
            commandable.remove(session)
        case .measure, .tool, .answer, .done:
            break
        }
    }

    var session: SessionState? {
        guard let selected, selected != Self.lampMasterId else { return nil }
        return deps.store.state.session(named: selected)
    }

    /// The route Send would take now, for the composer to say.
    var route: HubWrite.Route {
        guard let id = session?.id else { return .none }
        return HubWrite.route(mode, in: deps.situation(id))
    }

    /// Sends the text; keeps nothing and says why when nothing went.
    func send(_ text: String) -> Bool {
        guard let id = session?.id, let body = HubWrite.sendable(text) else { return false }
        let route = HubWrite.route(mode, in: deps.situation(id))
        guard route != .none else {
            notice = "This session cannot take a message from here now. Open its window."
            return false
        }
        let sent = deps.send(id, body, route, mode)
        notice = sent ? nil : "The message did not go. It is still in the box."
        return sent
    }

    private func openChat(for id: String?) {
        guard id != chatFor else { return }
        chat?.stop()
        chat = nil
        chatFor = id
        guard let id, id != Self.lampMasterId, let source = deps.chatSource(id) else { return }
        let model = LiveChatModel(source: source)
        model.start()
        chat = model
        refreshSendable()
    }

    private func refreshSendable() {
        guard let chat, let session else { return }
        chat.update(asking: session.status == .awaiting, sendable: route != .none)
    }

    func close() {
        chat?.stop()
        chat = nil
        chatFor = nil
    }
}
