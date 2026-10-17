import Foundation

/// What a device asks of a machine with its action key (W3 of the mobile plan,
/// §2.6): the panel's own actions on another machine, named, each with its
/// arguments checked here and its command built here, so that the phone, the
/// Mac and the Mac's bridge for the phone (W5) run one rule and not three.
///
/// Every command is one `sh -c`, whatever the login shell over there, built
/// from the scripts the Mac already runs over ssh (`NewSession`, `RemoteMove`,
/// `RemoteFolders`, `RemoteProject`, `RemotePeerScripts`, `RemoteTranscripts`)
/// and the ones a device needs besides (`RemoteEnd`, the Move's lock, the
/// resume that refuses a held conversation, `BackgroundAttach`). No text a
/// person typed reaches a shell unquoted; a value that is not what it should
/// be gives no command at all.
public enum NodeAction: Equatable, Sendable {
    /// A new conversation, or a past one taken up, in tmux in `folder`, under
    /// a tmux name like `name` and the tag `launch` (D133). It makes the tmux
    /// session and leaves: the terminal attaches to the name it prints.
    case start(folder: String, name: String, launch: String, start: NewSession.Start)
    /// «End session…» (L.H6): the conversation's process, checked to be the
    /// one its file names; with `tmux`, the tmux session that holds it.
    case end(session: String, tmux: String?)
    /// «Move to LampBoard…» (L.H3, H1.5-3): the editor's process `pid`, started
    /// at `procStart`, ended under the lock of `session`.
    case move(session: String, pid: Int32, procStart: String)
    /// The Move's lock let go, once the conversation goes on in tmux.
    case moveDone(session: String)
    /// A machine's folders, one level (H1.4-2).
    case browse(path: String?)
    /// A project's past conversations, for Resume (H1.4-7).
    case conversations(folder: String)
    /// A project's tree, a file in it, what git says (H1.7-1, H1.7-2).
    case files(root: String, relative: String?)
    case read(root: String, relative: String)
    case gitStatus(root: String)
    /// The project's attachments folder, made and resolved, for a copy by SFTP (H1.2-9).
    case attachments(root: String)
    /// `@name message` (H1.6-4, R5-2): into the conversation's box there.
    case message(session: String, text: String)
    /// The sessions as their files say, with their processes: what a Move needs.
    case look
    /// The machine's projects, kept by `lampd` (H1.1-4, H1.4-1).
    case projects(ProjectsChange)

    public enum ProjectsChange: Equatable, Sendable {
        case list
        case attach(String)
        case detach(String)
    }

    /// The action's name, as the bridge of the Mac will take it (§2.6).
    public var name: String {
        switch self {
        case .start(_, _, _, .new): return "new-session"
        case .start(_, _, _, .resume): return "resume"
        case .end: return "end"
        case .move: return "move"
        case .moveDone: return "move-done"
        case .browse: return "browse"
        case .conversations: return "conversations"
        case .files: return "files"
        case .read: return "read"
        case .gitStatus: return "git-status"
        case .attachments: return "attachments"
        case .message: return "peer-send"
        case .look: return "look"
        case .projects: return "projects"
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// An argument that is not one: a relative folder, an id that is not
        /// a conversation's, a name tmux would not take.
        case invalid(String)
        /// Bypass from the start is turned on on the Mac only, which writes
        /// it into `lampd` (W5, D169): until then a device cannot ask for it.
        case bypassOff
    }

    /// The command, or why there is none. `bypassAllowed`: whether the person
    /// turned on starting in Bypass where it is kept (the Mac, from W5).
    public func command(bypassAllowed: Bool = false) -> Result<String, Refusal> {
        switch self {
        case .start(let folder, let name, let launch, let start):
            guard folder.hasPrefix("/"), !folder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return .failure(.invalid("a folder is an absolute path")) }
            // Letters, digits, `-` and `_`, as `NewSession.tmuxName` makes them: tmux
            // expands `#(…)` and `#{…}` in a new session's name.
            guard TmuxPlace(session: name, window: 0, pane: 0) != nil, !name.hasPrefix("-"), name.count <= 60,
                  name.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" })
            else { return .failure(.invalid("not a name tmux takes")) }
            guard NewSession.isLaunchTag(launch) else { return .failure(.invalid("not a launch tag")) }
            guard NewSession.claudeLine(start) != nil else { return .failure(.invalid("not a conversation's id")) }
            if start.permissions == .bypass, !bypassAllowed { return .failure(.bypassOff) }
            let make = NewSession.remoteCommand(folder: folder, name: name, launch: launch, start: start, attach: false)
            guard case .resume(let id, _) = start else { return .success(NewSession.posix(make)) }
            return .success(NewSession.posix(Self.unlessHeld(id.lowercased()) + "\n" + make))
        case .end(let session, let tmux):
            return Self.python(RemoteEnd.script(session: session, tmux: tmux), "not a conversation or a tmux name")
        case .move(let session, let pid, let procStart):
            return Self.python(RemoteMove.lockedScript(pid: pid, procStart: procStart, session: session),
                               "not a process to move")
        case .moveDone(let session):
            guard let script = RemoteMove.unlock(session: session) else { return .failure(.invalid("not a conversation's id")) }
            return .success(NewSession.posix(script))
        case .browse(let path):
            guard let script = RemoteFolders.list(path) else { return .failure(.invalid("a folder is an absolute path")) }
            return .success(NewSession.posix(script))
        case .conversations(let folder):
            guard ProjectList.isValid(path: folder, host: nil) else { return .failure(.invalid("a folder is an absolute path")) }
            return .success(NewSession.posix(RemoteTranscripts.list(folder: folder)))
        case .files(let root, let relative):
            guard Self.isRoot(root), let script = RemoteProject.list(root: root, relative: relative)
            else { return .failure(.invalid("not a folder inside the project")) }
            return .success(NewSession.posix(script))
        case .read(let root, let relative):
            guard Self.isRoot(root), let script = RemoteProject.read(root: root, relative: relative)
            else { return .failure(.invalid("not a file inside the project")) }
            return .success(NewSession.posix(script))
        case .gitStatus(let root):
            guard Self.isRoot(root) else { return .failure(.invalid("a project is an absolute path")) }
            return .success(NewSession.posix(RemoteProject.gitStatus(root: root)))
        case .attachments(let root):
            guard Self.isRoot(root) else { return .failure(.invalid("a project is an absolute path")) }
            return .success(NewSession.posix(RemoteProject.attachmentsFolder(root: root)))
        case .message(let session, let text):
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty,
                  let payload = RemotePeerScripts.payload(session: session, content: PeerBox.preamble + "\n" + typed),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            else { return .failure(.invalid("nothing to send, too much, or not a conversation")) }
            return Self.python(RemotePeerScripts.send(payloadBase64: data.base64EncodedString()), "")
        case .look:
            return .success(V1ProbeReading.command())
        case .projects(let change):
            let lampd = "exec \"$HOME/.local/bin/lampd\" projects "
            switch change {
            case .list:
                return .success(NewSession.posix(lampd + "list"))
            case .attach(let path):
                guard ProjectList.isValid(path: path, host: nil) else { return .failure(.invalid("a project is an absolute path")) }
                return .success(NewSession.posix(lampd + "attach -- " + NewSession.shellQuoted(path)))
            case .detach(let path):
                guard ProjectList.isValid(path: path, host: nil) else { return .failure(.invalid("a project is an absolute path")) }
                return .success(NewSession.posix(lampd + "detach -- " + NewSession.shellQuoted(path)))
            }
        }
    }

    // MARK: - What came back

    /// How a start ended.
    public enum Started: Equatable, Sendable {
        /// Running in this tmux session, which the terminal attaches to.
        case started(tmux: String)
        /// A process holds that conversation now: it is opened where it runs,
        /// never taken up a second time (H1.4-7, R5-3).
        case held
        /// Nothing runs: the machine's words.
        case failed(String)
    }

    public static func started(output: String, exitCode: Int) -> Started {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.contains(heldWord) { return .held }
        if lines.contains(noPythonWord) {
            return .failed("python3 is not on that machine: LampBoard cannot check that nothing holds the conversation.")
        }
        guard exitCode == 0, let last = lines.last?.trimmingCharacters(in: .whitespaces), TmuxSizeRule.isSessionName(last)
        else { return .failed(lines.last ?? "tmux did not start the session (exit \(exitCode)).") }
        return .started(tmux: last)
    }

    /// What `message` answered: `nil` when sent, else why not.
    public static func notSent(_ output: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            return "the machine did not answer"
        }
        if object["ok"] as? Bool == true { return nil }
        return (object["reason"] as? String) ?? "the machine did not confirm it"
    }

    // MARK: - Inside

    static let heldWord = "lampboard:held"
    /// How long a Resume holds its conversation for the next one: longer than
    /// Claude Code takes to write its session file.
    static let resumeHolds: TimeInterval = 20
    static let noPythonWord = "lampboard:no-python"

    /// Before a conversation is taken up: no live process may hold it, as its
    /// session file says and the process confirms (pid alive, same start). A
    /// conversation running in an editor, a terminal or the background would
    /// get a second writer, and fork (R5-3).
    public static func unlessHeld(_ session: String) -> String {
        let check = """
        import glob, json, os, subprocess, sys
        session = "\(session)"
        \(RemoteMove.startedFunction)
        for path in glob.glob(os.path.join(os.path.expanduser("~/.claude/sessions"), "*.json")):
            try:
                meta = json.load(open(path))
                pid = int(meta["pid"])
                start = str(meta.get("procStart") or "")
            except Exception:
                continue
            if meta.get("sessionId") == session and pid > 1 and start and started_at(pid) == start:
                sys.exit(4)
        # Claude Code writes its file a second or two after it starts: a second
        # Resume in that while finds none, so the first holds it a little longer.
        import time
        lock = os.path.join(os.path.expanduser("~"), ".lampboard", "resuming", session)
        os.makedirs(os.path.dirname(lock), mode=0o700, exist_ok=True)
        try:
            os.mkdir(lock, 0o700)
        except FileExistsError:
            if time.time() - os.stat(lock).st_mtime < \(Int(resumeHolds)):
                sys.exit(4)
            os.utime(lock)
        """
        return "python3 -B -c \(NewSession.shellQuoted(check)); s=$?\n"
            + "if [ \"$s\" = 4 ]; then echo '\(heldWord)'; exit 4; elif [ \"$s\" != 0 ]; then echo '\(noPythonWord)'; exit 4; fi"
    }

    static func python(_ script: String?, _ why: String) -> Result<String, Refusal> {
        guard let script else { return .failure(.invalid(why)) }
        return .success(NewSession.posix("python3 -B -c " + NewSession.shellQuoted(script)))
    }

    static func isRoot(_ root: String) -> Bool { ProjectList.isValid(path: root, host: nil) && root != "/" }
}

/// A terminal a device opens on a machine besides a tmux session's (§2.7):
/// a background session's `claude attach`, a shell in a project's folder.
public enum NodeTerminalCommand: Equatable, Sendable {
    case background(job: String)
    case shell(root: String)

    public var command: String? {
        switch self {
        case .background(let job):
            return BackgroundAttach.command(job: job)
        case .shell(let root):
            guard NodeAction.isRoot(root) else { return nil }
            return NewSession.posix(ProjectShell.remoteScript(root: root))
        }
    }
}
