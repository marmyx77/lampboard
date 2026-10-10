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
    /// The session's project: its folder, and its machine when not this Mac (D156).
    let project: (String) -> (root: String, host: String?)?
    /// A signed command to a session's mod (D152): `false` when none could go.
    let command: (_ session: String, _ op: String, _ args: [String: String]) -> Bool
    /// The tools the session ran lately, oldest first, for the files' marks.
    let tools: (String) -> [(name: String, detail: String?)]
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
    /// The open session's reply as it arrives (D153): provisional, replaced by
    /// the transcript once the turn's lines are written.
    /// The followed turn's reply so far. Not published: a piece every 150 ms
    /// would redraw the whole conversation (P1, measured 10 October 2026); the
    /// bubble watches `liveTail` alone.
    private(set) var live: (turn: String, text: String)? {
        didSet { liveTail.show(live?.text) }
    }
    let liveTail = HubLiveTail()
    /// The session whose reply is followed, if any.
    private(set) var followed: String?

    let deps: HubDependencies
    /// The open session's project, and its shells (D156).
    let files = HubFilesModel()
    let shells = HubShells()
    private var chatFor: String?
    private var cancellables = Set<AnyCancellable>()

    private static let modeKey = "hubSendMode"

    init(deps: HubDependencies) {
        self.deps = deps
        self.mode = Preferences.sharedDefaults.string(forKey: Self.modeKey).flatMap(HubWrite.Mode.init(rawValue:)) ?? .queue
        files.tools = deps.tools
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
            if session == selected { follow(session) }
        case .end(let session, _):
            commandable.remove(session)
        case .measure, .tool, .answer, .done, .stopped:
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

    /// A piece of a reply from the followed session; anything else is dropped.
    func heard(stream text: String, turn: String, done: Bool, session: String) {
        guard session == followed, session == selected else { return }
        if live?.turn == turn {
            live = (turn, String((live?.text ?? "") + text).suffix(64_000).description)
        } else {
            live = (turn, String(text.suffix(64_000)))
        }
    }

    /// Follows `id`'s reply live, and stops following the one before (D153):
    /// one session at a time, the one on screen.
    private func follow(_ id: String?) {
        let next = id.flatMap { $0 != Self.lampMasterId && commandable.contains($0) ? $0 : nil }
        guard next != followed else { return }
        if let previous = followed { _ = deps.command(previous, "stream", ["on": "false"]) }
        followed = next
        live = nil
        if let next { _ = deps.command(next, "stream", ["on": "true"]) }
    }

    /// Stops the turn (Stop), through the mod; says what keeps running.
    func stop() {
        guard let id = session?.id else { return }
        guard commandable.contains(id), deps.command(id, "abort", [:]) else {
            notice = "Stop needs LampBoard's helper in this session: press Esc in its window."
            return
        }
        notice = "Stopped from the Hub. Commands it started in the background keep running."
    }

    private func openChat(for id: String?) {
        follow(id)
        let project = id.flatMap { $0 == Self.lampMasterId ? nil : deps.project($0) }
        files.show(session: id, root: project?.root, host: project?.host)
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
        // The transcript caught up: the turn ended and its lines are read.
        if live != nil, let session, session.status != .working, session.status != .waiting { live = nil }
        guard let chat, let session else { return }
        chat.update(asking: session.status == .awaiting, sendable: route != .none)
    }

    func close() {
        follow(nil)
        shells.endAll()
        chat?.stop()
        chat = nil
        chatFor = nil
    }
}

/// What the live bubble draws: the last lines of the reply being written,
/// at most five times a second. The whole reply comes with the transcript; a
/// bubble that grew and scrolled with every piece cost the panel ten points of
/// CPU (P1, measured 10 October 2026).
@MainActor
final class HubLiveTail: ObservableObject {
    static let lines = 8
    static let every: TimeInterval = 0.2
    @Published private(set) var text = ""
    private var latest = ""
    private var shownAt = Date.distantPast
    private var waiting = false

    func show(_ full: String?) {
        latest = Self.tail(of: full ?? "")
        guard !waiting else { return }
        let wait = Self.every - Date().timeIntervalSince(shownAt)
        guard wait > 0, !latest.isEmpty else { return publish() }
        waiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.waiting = false
            self?.publish()
        }
    }

    private func publish() {
        shownAt = Date()
        if latest != text { text = latest }
    }

    static func tail(of full: String) -> String { HubWrite.tail(of: full, lines: lines) }
}
