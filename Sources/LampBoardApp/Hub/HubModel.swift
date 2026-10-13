import ClarcChatKit
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
    /// The same engine as a click in the panel: the session's own window.
    let openRealWindow: (String) -> Void
    /// The session's project: its folder, and its machine when not this Mac (D156).
    let project: (String) -> (root: String, host: String?)?
    /// The tools the session ran lately, oldest first, for the files' marks.
    let tools: (String) -> [(name: String, detail: String?)]
    /// The terminal that reaches the session, when LampBoard can open one:
    /// its tmux here or on its machine, or its background job (hub-terminale R1).
    let target: (String) -> LiveTarget?
    /// The terminals, shared with the live view's windows: one attach a session.
    let live: LiveWindowController
    /// «Move to LampBoard» for a session in VS Code (D135); `nil` when it cannot move.
    let move: (String) -> (() -> Void)?
    /// The projects attached to the Hub (hub-terminale R3).
    let projects: ProjectStore
    /// The machines in Settings › Other Macs.
    let hosts: () -> [String]
    /// The sessions another machine's probe says are running there.
    let liveOn: (String) -> Set<String>
    /// Where the processes holding a conversation run, when the probe knows
    /// them: more than one is two writers.
    let holders: (String) -> [String]
}

/// The Hub's state: which session is open, and what its centre shows.
///
/// The centre is the session's own terminal whenever LampBoard can open one
/// (hub-terminale, 11 October 2026): Claude Code's whole interface, its
/// commands, models, modes, questions and Esc, with nothing imitated. A session
/// LampBoard cannot reach (one in VS Code's panel, in the Claude app) is read
/// from its transcript, and offers to move here.
@MainActor
final class HubModel: ObservableObject {

    /// LampMaster's row, above the sessions (D151).
    static let lampMasterId = "lampmaster"

    enum Centre: Equatable {
        case none
        /// LampMaster's row: its own terminal when its session runs (R10).
        case lampMaster(LiveTarget?)
        /// The session's terminal.
        case terminal(LiveTarget)
        /// Its terminal is in a window of its own, until brought back.
        case inWindow(LiveTarget)
        /// Read from its transcript: LampBoard has no terminal into it.
        case reading(String)
    }

    @Published var selected: String?
    @Published private(set) var centre: Centre = .none
    /// Said over the centre when two processes hold the chosen conversation.
    @Published private(set) var twoWriters: String?
    /// Sessions LampBoard just started, shown before their row exists.
    @Published private(set) var pending: [String: SessionLauncher.Pending] = [:]
    /// The transcript of a session read in the centre.
    @Published private(set) var reader: LiveChatModel?
    /// The first-run guide, until the person has read it (Marco's choice).
    @Published var guideShown = !Preferences.sharedDefaults.bool(forKey: HubModel.guideKey)
    static let guideKey = "hub.terminalGuideSeen"

    func dismissGuide() {
        guideShown = false
        Preferences.sharedDefaults.set(true, forKey: Self.guideKey)
    }

    let deps: HubDependencies
    /// The open session's project, and its shells (D156).
    let files = HubFilesModel()
    let shells = HubShells()
    private var readerFor: String?
    private var shown = false
    private var cancellables = Set<AnyCancellable>()

    init(deps: HubDependencies) {
        self.deps = deps
        files.tools = deps.tools
        // A turn of the run loop later: `$selected` speaks before the value is
        // stored, and the centre is worked out from the stored one.
        $selected.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] id in self?.open(id) }.store(in: &cancellables)
        // A session can become reachable after it is chosen (its tmux pane is
        // learnt every ten seconds, a move ends in a background job), or stop
        // being so: the centre follows, once a second.
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshCentre() }
            .store(in: &cancellables)
    }

    var session: SessionState? {
        guard let selected, selected != Self.lampMasterId else { return nil }
        return deps.store.state.session(named: selected)
    }

    /// The warning for a conversation held by several processes, or `nil`.
    static func twoWriters(_ holders: [String]) -> String? {
        guard holders.count > 1 else { return nil }
        let places = holders.dropLast().joined(separator: ", ") + " and " + (holders.last ?? "")
        return "This conversation is open \(holders.count == 2 ? "twice" : "\(holders.count) times"): in \(places). "
            + "Two processes writing one conversation fork it: close the one you are not using."
    }

    /// A session LampBoard started, chosen and shown at once (hub-terminale R4).
    func show(_ started: SessionLauncher.Pending) {
        pending[started.sessionId] = started
        guard started.reveal else { return }
        if selected == started.sessionId { open(started.sessionId) } else { selected = started.sessionId }
    }

    /// What the centre's header says: the row's, or the start's until the row comes.
    var heading: (status: SessionStatus?, name: String, meta: String)? {
        if let session {
            var parts = [session.workspace.name, session.workspace.host ?? "This Mac", HubConversationView.surface(session)]
            if let letter = session.context?.modelInitial, !letter.isEmpty { parts.append(letter) }
            return (session.status, session.displayName, parts.joined(separator: " · "))
        }
        guard let id = selected, let started = pending[id] else { return nil }
        return (nil, started.name, [(started.folder as NSString).lastPathComponent, started.host ?? "This Mac", "starting"]
            .joined(separator: " · "))
    }

    /// The terminal shown, if any: the frame to seat, the attach made once.
    func terminalView(for target: LiveTarget) -> NSView? { deps.live.hosted(target) }

    func terminal(for target: LiveTarget) -> NSView? { deps.live.hostedTerminal(target) }

    func hasLeft(_ target: LiveTarget) -> Bool { deps.live.hostedEnded(target) }

    func reattach(_ target: LiveTarget) { deps.live.reattachHosted(target) }

    /// The session's terminal in a window of its own.
    func popOut() {
        guard case .terminal(let target) = centre else { return }
        deps.live.open(target)
        refreshCentre()
    }

    /// Its window's terminal back in the centre: the same attach.
    func bringBack() {
        guard case .inWindow(let target) = centre else { return }
        _ = deps.live.hosted(target)
        refreshCentre()
    }

    private func open(_ id: String?) {
        showFiles(id)
        refreshCentre()
    }

    /// The project beside the session: its row's, or the folder it was started
    /// in while it has no row yet.
    private func showFiles(_ id: String?) {
        let started = id.flatMap { pending[$0] }.map { (root: $0.folder, host: $0.host) }
        let project = id.flatMap { $0 == Self.lampMasterId ? nil : deps.project($0) } ?? started
        files.show(session: id, root: project?.root, host: project?.host)
    }

    private func refreshCentre() {
        guard shown else { return }
        let next: Centre
        // Started sessions nobody chose are dropped once their row has come.
        // And those that never came, after ten minutes.
        let old = Date().addingTimeInterval(-600)
        let arrived = pending.filter { id, started in
            id != selected && (started.at < old || (deps.store.state.sessions[id] != nil && deps.target(id) != nil))
        }.keys
        if !arrived.isEmpty { arrived.forEach { pending[$0] = nil } }
        if selected == Self.lampMasterId {
            // Its terminal while its conversation runs, or while it is starting.
            let id = conductor?.sessionId
            let starting = id.map { pending[$0] != nil } ?? false
            // Running: its row has a terminal, which only a live session is given
            // (the panes are read off the main thread). Asking the processes here,
            // once a second, would be work on the main thread (D161).
            let running = id.map { deps.store.state.sessions[$0] != nil && deps.target($0) != nil } ?? false
            next = .lampMaster(running || starting ? id.flatMap { deps.target($0) ?? pending[$0]?.target } : nil)
        } else if let id = selected {
            // The row's own terminal once it has one; until then the one the
            // start made; else, a row without a terminal is read.
            let target: LiveTarget?
            if let session, let reached = deps.target(session.id) {
                // Published: set only when it changes, not once a second.
                if pending[id] != nil { pending[id] = nil }
                target = reached
            } else {
                target = pending[id]?.target
            }
            if let target {
                next = deps.live.isInWindow(target) ? .inWindow(target) : .terminal(target)
            } else if let session {
                next = .reading(session.id)
            } else {
                next = .none
            }
        } else {
            next = .none
        }
        let warning = Self.twoWriters(selected.map(deps.holders) ?? [])
        if warning != twoWriters { twoWriters = warning }
        guard next != centre else { return }
        Diagnostics.log("hub: centre \(Self.describe(centre)) → \(Self.describe(next))")
        centre = next
        if case .reading(let id) = next { read(id) } else { read(nil) }
    }

    static func describe(_ centre: Centre) -> String {
        switch centre {
        case .none: return "none"
        case .lampMaster(let target): return "lampMaster(\(target?.key ?? "-"))"
        case .terminal(let target): return "terminal(\(target.key))"
        case .inWindow(let target): return "inWindow(\(target.key))"
        case .reading(let id): return "reading(\(id.prefix(8)))"
        }
    }

    private func read(_ id: String?) {
        guard id != readerFor else { return }
        reader?.stop()
        reader = nil
        readerFor = id
        guard let id, let source = deps.chatSource(id) else { return }
        let model = LiveChatModel(source: source)
        model.start()
        reader = model
    }

    /// The Hub opened again: what closing ended (the reading, the terminals,
    /// git's questions) starts again on the session it shows.
    func resume() {
        shown = true
        centre = .none
        open(selected)
    }

    /// Starts sessions in projects; set once the Hub is built.
    var launcher: SessionLauncher?
    /// LampMaster as a session (R10); set once the Hub is built.
    var conductor: LampMasterConductor?
    /// LampMaster's cards shown instead of its conversation.
    @Published var lampMasterCards = false

    /// Starts LampMaster's session, or takes it up again, on its row.
    func startLampMaster() {
        failure = nil
        conductor?.start { [weak self] reason in self?.failed("LampMaster did not start", reason) }
        lampMasterCards = false
        if selected == Self.lampMasterId { refreshCentre() } else { selected = Self.lampMasterId }
    }

    /// Why the last start did not happen, for the tests' report.
    @Published private(set) var failure: String?

    /// A new conversation in tmux, in `folder` here or on `host` (R4).
    func startSession(folder: String, host: String?, name: String? = nil) {
        failure = nil
        launcher?.launch(folder: folder, host: host, start: .new(sessionId: SessionLauncher.newSessionId()), name: name) { [weak self] reason in
            if let reason { self?.failed("The session did not start", reason) }
        }
    }

    /// A conversation a process holds now, opened where it runs: its row's
    /// terminal in the Hub, or its reading when LampBoard has no terminal into it.
    func openRunning(_ id: String) {
        failure = nil
        guard deps.store.state.session(named: id) != nil else {
            return failed("The conversation runs somewhere LampBoard does not see",
                          "It is open in a process with no row in LampBoard yet: open it where it runs, or end that process first.")
        }
        selected = id
    }

    /// A past conversation taken up in tmux (R5).
    func resumeSession(_ id: String, folder: String, host: String?) {
        failure = nil
        launcher?.launch(folder: folder, host: host, start: .resume(sessionId: id), name: nil) { [weak self] reason in
            if let reason { self?.failed("The conversation was not taken up", reason) }
        }
    }

    private func failed(_ title: String, _ reason: String) {
        failure = reason
        // A fake home is a test's: a modal dialog would hold its main thread.
        guard !AppConfig.isUsingHomeOverride else { return Diagnostics.log("hub: \(title): \(reason)") }
        Alerts.tell(title: title, message: reason)
    }


    /// Text proposed to a session (a handoff, a LampMaster card, `@name …`):
    /// the Hub opens on it and the text waits in its terminal's prompt, for the
    /// person to read, change and send with Enter (D85, D165). `false` when
    /// LampBoard has no terminal into it.
    func propose(_ text: String, to id: String) -> Bool {
        guard let target = deps.target(id) else { return false }
        selected = id
        refreshCentre()
        // The attach may still be starting: the paste waits for Claude Code's prompt.
        let key = target.key
        DispatchQueue.main.async { [weak self] in
            _ = self?.deps.live.hosted(target)
            self?.deps.live.pasteWhenReady(text, into: key)
        }
        return true
    }

    /// One level of another machine's folders, through the panel's ssh.
    func browse(host: String, path: String?) async -> RemoteFolders.Listing? {
        guard let script = RemoteFolders.list(path),
              let answer = await ProjectSource.ssh(host, NewSession.posix(script)) else { return nil }
        return RemoteFolders.parse(answer)
    }

    /// What `entry` offers to take up, read off the main thread.
    func pastConversations(_ entry: ProjectList.Entry) async -> [PastConversations.Item] {
        guard let host = entry.host else {
            let folder = entry.path
            return await Task.detached(priority: .userInitiated) { PastConversationReader.local(folder: folder) }.value
        }
        return await PastConversationReader.remote(folder: entry.path, host: host, live: deps.liveOn(host))
    }

    func close() {
        shown = false
        // Closed, it asked git every three seconds all the same (10 October 2026).
        files.pause()
        shells.endAll()
        read(nil)
        // The terminals leave; their sessions go on.
        deps.live.endHosted()
        centre = .none
    }
}
