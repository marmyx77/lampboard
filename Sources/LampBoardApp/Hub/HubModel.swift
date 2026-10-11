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
        case lampMaster
        /// The session's terminal.
        case terminal(LiveTarget)
        /// Its terminal is in a window of its own, until brought back.
        case inWindow(LiveTarget)
        /// Read from its transcript: LampBoard has no terminal into it.
        case reading(String)
    }

    @Published var selected: String?
    @Published private(set) var centre: Centre = .none
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
        $selected.removeDuplicates().sink { [weak self] id in self?.open(id) }.store(in: &cancellables)
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
        let project = id.flatMap { $0 == Self.lampMasterId ? nil : deps.project($0) }
        files.show(session: id, root: project?.root, host: project?.host)
        refreshCentre()
    }

    private func refreshCentre() {
        guard shown else { return }
        let next: Centre
        if selected == Self.lampMasterId {
            next = .lampMaster
        } else if let session {
            if let target = deps.target(session.id) {
                next = deps.live.isInWindow(target) ? .inWindow(target) : .terminal(target)
            } else {
                next = .reading(session.id)
            }
        } else {
            next = .none
        }
        guard next != centre else { return }
        centre = next
        if case .reading(let id) = next { read(id) } else { read(nil) }
    }

    private func read(_ id: String?) {
        guard id != readerFor else { return }
        reader?.stop()
        reader = nil
        readerFor = id
        guard let id, let source = deps.chatSource(id) else { return }
        let model = LiveChatModel(source: source)
        model.start()
        model.update(asking: false, sendable: false)
        reader = model
    }

    /// The Hub opened again: what closing ended (the reading, the terminals,
    /// git's questions) starts again on the session it shows.
    func resume() {
        shown = true
        centre = .none
        open(selected)
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
