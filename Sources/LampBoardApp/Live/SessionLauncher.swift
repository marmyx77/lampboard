import AppKit
import Foundation
import LampBoardCore

/// Starts a session in a project from LampBoard (hub-terminale R4, R5): a new
/// conversation under an id LampBoard chooses, or a past one taken up, inside
/// tmux on this Mac or on another machine. The Hub shows its terminal at once,
/// before the session has said anything.
///
/// One writer: a past conversation is taken up only when no process holds it,
/// here or on its machine as far as LampBoard knows.
@MainActor
final class SessionLauncher {

    /// What the Hub needs to show a session that has no row yet.
    struct Pending: Equatable {
        let sessionId: String
        let target: LiveTarget
        let name: String
        let folder: String
        let host: String?
        /// Chosen in the Hub at once; `false` for a start LampMaster asked for,
        /// which leaves the Hub on LampMaster's conversation.
        var reveal = true
        /// When it was started: one whose row never comes is dropped in time.
        var at = Date()
    }

    private let store: StateStore
    private let show: (Pending) -> Void

    init(store: StateStore, show: @escaping (Pending) -> Void) {
        self.store = store
        self.show = show
    }

    /// A fresh id for a new conversation.
    static func newSessionId() -> String { UUID().uuidString.lowercased() }

    /// Conversations being started now, and since when. A process takes a
    /// second or more to show in `~/.claude/sessions`, and another machine's
    /// probe longer: until then a second start of the same id would be a second
    /// writer (a review finding, 12 October 2026).
    private var starting: [String: Date] = [:]
    static let startingFor: TimeInterval = 90

    /// Whether `id` is being started now.
    /// It stops being so the moment the session speaks: its row moves after the
    /// start (then a process holds it, or has let it go).
    func isStarting(_ id: String, now: Date = Date()) -> Bool {
        guard let since = starting[id] else { return false }
        if let row = store.state.sessions[id], row.updatedAt > since {
            starting[id] = nil
            return false
        }
        return now.timeIntervalSince(since) < Self.startingFor
    }

    /// Starts `start` in `folder`, on `host` or this Mac; `done` is told `nil`
    /// once it is started, or why not.
    func launch(folder: String, host: String?, start: NewSession.Start, name: String?, reveal: Bool = true,
                done: @escaping (String?) -> Void) {
        let id = start.sessionId
        guard !isStarting(id) else { return done("This conversation is being started already.") }
        if case .resume = start, let reason = Self.busy(id, host: host, store: store) { return done(reason) }
        for old in Array(starting.keys) where !isStarting(old) { starting[old] = nil }
        starting[id] = Date()
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? (folder as NSString).lastPathComponent
        let tmuxName = NewSession.tmuxName(for: "/" + label, taken: [])
        let finish: (String?) -> Void = { [weak self] reason in
            if reason != nil { self?.starting[id] = nil }
            done(reason)
        }
        guard let host else {
            return launchHere(folder: folder, name: tmuxName, label: label, start: start, reveal: reveal, done: finish)
        }
        guard let target = LiveTarget.starting(host: host, folder: folder, name: tmuxName, start: start),
              case .newTmux(_, _, _, let launch, _) = target else {
            return finish("LampBoard could not start a session on \(host): its name, or that folder, is not one ssh can be given.")
        }
        let pending = Pending(sessionId: id, target: target, name: label, folder: folder, host: host, reveal: reveal)
        // Shown: its terminal runs the script that makes it, then attaches.
        guard !reveal else {
            show(pending)
            return finish(nil)
        }
        // Not shown: made over ssh now, detached; attaching later finds it by its tag.
        let script = NewSession.posix(NewSession.remoteCommand(folder: folder, name: tmuxName, launch: launch, start: start, attach: false))
        Task { @MainActor [weak self] in
            let made = await ProjectSource.ssh(host, script)
            guard made?.isEmpty == false else { return finish("\(host) did not start the session in \(folder).") }
            self?.show(pending)
            finish(nil)
        }
    }

    /// Why `id` cannot be taken up now, if it cannot.
    static func busy(_ id: String, host: String?, store: StateStore) -> String? {
        if let host {
            guard store.remoteSessions[host]?.contains(where: { $0.sessionId == id }) != true else {
                return "This conversation is open on \(host). Open it there, or close it first: two writers would fork it."
            }
            return nil
        }
        // Either way of knowing it runs is enough to refuse: a session file
        // without its start time is still a process holding the conversation.
        let running = LiveSessionReader().readLiveSessions().contains { $0.sessionId == id }
        guard !running, SessionTerminator.process(of: id) == nil else {
            return "This conversation is open on this Mac. Open it, or Move it to LampBoard: two writers would fork it."
        }
        return nil
    }

    private func launchHere(folder: String, name: String, label: String, start: NewSession.Start, reveal: Bool,
                            done failed: @escaping (String?) -> Void) {
        guard let tmux = LocalTmuxPlaces.executable() else {
            return failed("tmux was not found on this Mac. Install it (brew install tmux) to start sessions from LampBoard.")
        }
        let launch = NewSession.newLaunchTag()
        guard let script = NewSession.localCommand(folder: folder, name: name, launch: launch, start: start) else {
            return failed("LampBoard could not start a session in \(folder).")
        }
        // The pane's shell is the person's own, from tmux's server: what this
        // process was started with stays out of it, as for every attach (D130).
        var environment = LiveLaunch.environment(base: ProcessInfo.processInfo.environment, home: AppConfig.homeDirectory.path)
        environment["PATH"] = ((tmux as NSString).deletingLastPathComponent) + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        var cleared: [String: String?] = [:]
        for key in ProcessInfo.processInfo.environment.keys where environment[key] == nil { cleared[key] = .some(nil) }
        for (key, value) in environment { cleared[key] = value }
        let store = store
        let show = show
        DispatchQueue.global(qos: .userInitiated).async {
            let result = try? Command.run("/bin/sh", ["-c", script], deadline: 20, environment: cleared)
            let output = result?.output ?? ""
            let place = Self.place(fromOutput: output, launch: launch)
            DispatchQueue.main.async {
                guard result?.succeeded == true, let place else {
                    let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return failed(said.isEmpty ? "tmux did not start the session in \(folder)." : said)
                }
                store.conversations.expect(start.sessionId)
                show(Pending(sessionId: start.sessionId, target: .tmux(host: nil, place: place, sessionId: start.sessionId),
                             name: label, folder: folder, host: nil, reveal: reveal))
                failed(nil)
            }
        }
    }

    /// `name:window.pane`, the script's last line, as a place carrying its tag.
    nonisolated static func place(fromOutput output: String, launch: String) -> TmuxPlace? {
        guard let line = output.split(separator: "\n").last.map(String.init),
              let colon = line.lastIndex(of: ":") else { return nil }
        let name = String(line[..<colon])
        let numbers = line[line.index(after: colon)...].split(separator: ".")
        guard numbers.count == 2, let window = Int(numbers[0]), let pane = Int(numbers[1]) else { return nil }
        return TmuxPlace(session: name, window: window, pane: pane, launch: launch)
    }
}
