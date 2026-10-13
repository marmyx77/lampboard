import Foundation

/// Where a session sits in tmux: the session's name, the window and the pane.
///
/// Any name tmux can give a session: tmux itself takes no dot and no colon in
/// one, which would read as a window or a pane. Spaces, quotes and emoji are
/// names too — a notification's 🔔 added to one hid its session's terminal from
/// the Hub (13 October 2026) — so the name travels as one argument here and
/// single-quoted over ssh, never read by a shell.
public struct TmuxPlace: Equatable, Hashable, Sendable {
    public let session: String
    public let window: Int
    public let pane: Int
    /// The tag LampBoard gave a tmux session it started (D133), so that a
    /// reattach finds it again and its row opens the same window.
    public let launch: String?

    public init?(session: String, window: Int, pane: Int, launch: String? = nil) {
        guard !session.isEmpty, session.count <= 200, !session.contains(":"), !session.contains("."),
              !session.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              window >= 0, pane >= 0 else { return nil }
        self.session = session
        self.window = window
        self.pane = pane
        let launch = launch?.nilIfEmpty
        self.launch = launch.flatMap { NewSession.isLaunchTag($0) ? $0 : nil }
    }

    /// tmux's exact-name target: `=awevents:1.0`. The `=` stops `awe` from
    /// matching `awevents` by prefix.
    public var target: String { "=\(session):\(window).\(pane)" }

    /// The same, for a shell: zsh, a Mac's default, expands a word that begins
    /// with `=` into a command's path, so the target travels in single quotes,
    /// a quote inside the name closed and reopened.
    public var quotedTarget: String { NewSession.shellQuoted(target) }

    /// Whether a live session may be placed in a pane at all: one started in a
    /// terminal. An editor started from a tmux pane hosts its sessions under that
    /// pane too, and such a session must keep its jump to the editor (D132).
    public static func isPlaceable(entrypoint: String?, isBackground: Bool) -> Bool {
        !isBackground && (entrypoint == nil || entrypoint == "cli")
    }

    /// The format string for `tmux list-panes -a -F`, the same the remote probe
    /// asks for: the pane's shell, where the pane is, and LampBoard's tag.
    public static let paneFormat = "#{pane_pid}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{@lampboard}"

    /// Each pane's shell pid and its place; a line tmux could not take back is skipped.
    public static func panes(_ output: String) -> [Int32: TmuxPlace] {
        var places: [Int32: TmuxPlace] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 || fields.count == 5, let pid = Int32(fields[0]), let window = Int(fields[2]),
                  let pane = Int(fields[3]),
                  let place = TmuxPlace(session: fields[1], window: window, pane: pane,
                                        launch: fields.count == 5 ? fields[4] : nil) else { continue }
            places[pid] = place
        }
        return places
    }

    /// Whether a process runs inside tmux: its server among its ancestors. The
    /// server leaves the terminal that started it, so a session in tmux has no
    /// editor among its ancestors, even when tmux was started in an editor's
    /// terminal; its folder is its own, not the editor window's that contains it.
    public static func runsInTmux(ancestry: [ProcessAncestor]) -> Bool {
        ancestry.dropFirst().contains { ($0.executablePath as NSString).lastPathComponent == "tmux" }
    }

    /// Whether a process runs in LampBoard's own terminal: a session that ends
    /// when closed (D168), with LampBoard among its ancestors. Like one in tmux,
    /// its folder is its own, not an editor window's that contains it.
    public static func runsInLampBoard(ancestry: [ProcessAncestor], lampBoard: Int32) -> Bool {
        lampBoard > 1 && ancestry.dropFirst().contains { $0.pid == lampBoard }
    }

    /// The pane whose shell is among a process's ancestors, the process first.
    public static func place(ofAncestry pids: [Int32], in panes: [Int32: TmuxPlace]) -> TmuxPlace? {
        pids.lazy.compactMap { panes[$0] }.first
    }
}

/// What the live view can open (D130, D132), and nothing else.
///
/// Two kinds, both with one writer whoever looks: a background session of this
/// Mac, which its supervisor keeps single-writer, and a session in tmux, here or
/// on another machine, where tmux keeps one process however many clients attach.
/// A session in an editor or a plain terminal is neither, and keeps its jump.
/// Nothing names a machine: a host is whatever the person added in Settings.
public enum LiveTarget: Equatable, Hashable, Sendable {
    case job(String)
    /// `host` is `nil` for tmux on this Mac.
    case tmux(host: String?, place: TmuxPlace, sessionId: String)
    /// A new session being started inside tmux on another machine (D133),
    /// tagged `launch` there; `start` is the conversation it begins or takes up
    /// (hub-terminale R4, R5), `nil` for a plain `claude`.
    case newTmux(host: String, folder: String, name: String, launch: String, start: NewSession.Start? = nil)
    /// A session that ends when it is closed (D168): Claude Code run in
    /// LampBoard's own terminal, here or over ssh, with no tmux to keep it. It
    /// goes when its terminal goes: ended, or LampBoard quitting.
    case direct(host: String?, folder: String, start: NewSession.Start)

    /// A session that ends when closed, in `folder` on `host` or this Mac;
    /// `nil` for a folder that is not absolute, a host ssh could read as an
    /// option, or an id that is not one.
    public static func temporary(host: String?, folder: String, start: NewSession.Start) -> LiveTarget? {
        guard folder.hasPrefix("/"), NewSession.claudeLine(start) != nil,
              host.map({ RemoteHostList.isUsable($0) && !$0.hasPrefix("-") }) ?? true else { return nil }
        return .direct(host: host, folder: folder, start: start)
    }

    /// The conversation, when the target names it.
    public var sessionId: String? {
        switch self {
        case .job, .newTmux: return nil
        case .tmux(_, _, let id): return id
        case .direct(_, _, let start): return start.sessionId
        }
    }

    /// Whether it outlives its terminal: everything but a temporary session.
    public var outlivesItsTerminal: Bool {
        if case .direct = self { return false }
        return true
    }

    /// A new session in `folder` on `host`, under a name tmux can take; `nil` for
    /// a folder that is not absolute or a host ssh could read as an option.
    public static func starting(host: String, folder: String, name: String,
                                launch: String = NewSession.newLaunchTag(), start: NewSession.Start? = nil) -> LiveTarget? {
        guard folder.hasPrefix("/"), RemoteHostList.isUsable(host), !host.hasPrefix("-"),
              TmuxPlace(session: name, window: 0, pane: 0) != nil, NewSession.isLaunchTag(launch),
              start.map({ NewSession.claudeLine($0) != nil }) ?? true else { return nil }
        return .newTmux(host: host, folder: folder, name: name, launch: launch, start: start)
    }

    /// The machine it is on; `nil` for this Mac.
    public var host: String? {
        switch self {
        case .job: return nil
        case .tmux(let host, _, _): return host
        case .newTmux(let host, _, _, _, _): return host
        case .direct(let host, _, _): return host
        }
    }

    /// The window's key, and what the ledger and `GET /live` call it.
    public var key: String {
        switch self {
        case .job(let id): return id
        // `tmux:` cannot begin a job's id, and an empty host is this Mac: no
        // machine can be named so as to collide with it.
        // A session LampBoard started is known by its tag, whatever name and
        // window numbers it got over there.
        case .tmux(let host, let place, _):
            if let launch = place.launch { return "tmux:\(host ?? ""):launch:\(launch)" }
            return "tmux:\(host ?? ""):\(place.session):\(place.window).\(place.pane)"
        case .newTmux(let host, _, _, let launch, _): return "tmux:\(host):launch:\(launch)"
        case .direct(let host, _, let start): return "direct:\(host ?? ""):\(start.sessionId)"
        }
    }

    /// What a person would type for the same, offered to copy.
    public var command: String {
        switch self {
        case .job(let id): return "claude attach \(id)"
        case .tmux(let host?, let place, _): return "ssh -t \(host) \"tmux attach -t \(place.quotedTarget)\""
        case .tmux(nil, let place, _): return "tmux attach -t \(place.quotedTarget)"
        case .newTmux(let host, let folder, let name, let launch, let start):
            return "ssh -t \(host) \(NewSession.shellQuoted(NewSession.posix(NewSession.remoteCommand(folder: folder, name: name, launch: launch, start: start))))"
        case .direct(let host, let folder, let start):
            let here = "cd \(NewSession.shellQuoted(folder)) && \(NewSession.claudeLine(start) ?? "claude")"
            return host.map { "ssh -t \($0) \(NewSession.shellQuoted(here))" } ?? here
        }
    }

    /// The target of a row's session, if it has one. `place` is where the
    /// session sits in tmux, on its own machine, when that is known.
    public static func of(_ session: SessionState, place: TmuxPlace?) -> LiveTarget? {
        if let host = session.workspace.host {
            guard let place, RemoteHostList.isUsable(host), !host.hasPrefix("-") else { return nil }
            return .tmux(host: host, place: place, sessionId: session.id)
        }
        if session.origin == .background, let job = session.backgroundJob { return .job(job.id) }
        if let place { return .tmux(host: nil, place: place, sessionId: session.id) }
        return nil
    }
}

extension LiveLaunch {
    /// What the other machine's shell runs: one string, since ssh joins its
    /// arguments with spaces for that shell anyway. The target is quoted, and
    /// Homebrew's folders are added to a PATH that a non-interactive ssh keeps
    /// short on a Mac.
    public static func remoteAttach(_ place: TmuxPlace) -> String {
        "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux attach-session -t \(place.quotedTarget)"
    }
}

/// The options every ssh LampBoard starts carries (they were `RemoteCommand`'s):
/// a compromised node gets neither the Mac's agent, nor X11, nor a local command
/// run here, and no password prompt can hang a connection.
public enum SSHHardening {
    public static let options: [String] = [
        "-a", "-x",
        "-o", "ForwardAgent=no",
        "-o", "PermitLocalCommand=no",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
    ]
}

extension LiveLaunch {

    /// The command that opens `target`: `claude attach <id>`, or ssh with a
    /// terminal into the machine and `tmux attach-session` there.
    public static func command(for target: LiveTarget, claude: String, environment base: [String: String],
                               home: String, tmux: String? = nil) -> LiveCommand? {
        switch target {
        case .job(let id):
            return attach(job: id, claude: claude, environment: base, home: home)
        case .tmux(nil, let place, _):
            // This Mac's tmux, its default server; `TMUX` is not in the
            // environment, so it attaches rather than nesting.
            guard let tmux else { return nil }
            return LiveCommand(executable: tmux, arguments: ["attach-session", "-t", place.target], directory: nil,
                               environment: environment(base: base, home: home))
        case .newTmux(let host, let folder, let name, let launch, let start):
            guard RemoteHostList.isUsable(host), !host.hasPrefix("-") else { return nil }
            let script = NewSession.remoteCommand(folder: folder, name: name, launch: launch, start: start)
            return LiveCommand(executable: "/usr/bin/ssh",
                               arguments: SSHHardening.options + ["-t", "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10",
                                                                  "--", host, NewSession.posix(script)],
                               directory: nil, environment: environment(base: base, home: home))
        case .tmux(let host?, let place, _):
            guard RemoteHostList.isUsable(host), !host.hasPrefix("-") else { return nil }
            return LiveCommand(executable: "/usr/bin/ssh",
                               arguments: SSHHardening.options + ["-t", "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10",
                                                                  "--", host, NewSession.posix(remoteAttach(place))],
                               directory: nil, environment: environment(base: base, home: home))
        case .direct(let host, let folder, let start):
            guard let line = NewSession.claudeLine(start) else { return nil }
            // The person's own shell, interactive so that its startup files put
            // `claude` on PATH, as in a tmux pane LampBoard starts (D133).
            guard let host else {
                let shell = base["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
                return LiveCommand(executable: shell, arguments: ["-ilc", line], directory: folder,
                                   environment: environment(base: base, home: home, claude: claude.isEmpty ? nil : claude))
            }
            guard RemoteHostList.isUsable(host), !host.hasPrefix("-") else { return nil }
            let script = "cd -- \(NewSession.shellQuoted(folder)) || exit 1\n"
                + #"export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin""# + "\n"
                + "exec \"$SHELL\" -ilc " + NewSession.shellQuoted(line)
            return LiveCommand(executable: "/usr/bin/ssh",
                               arguments: SSHHardening.options + ["-t", "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10",
                                                                  "--", host, NewSession.posix(script)],
                               directory: nil, environment: environment(base: base, home: home))
        }
    }
}
