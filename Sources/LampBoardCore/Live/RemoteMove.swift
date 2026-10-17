import Foundation

/// «Move to LampBoard…» for a conversation open in VS Code on another machine
/// (D135, D166): its process there is asked to end, between turns, and only if
/// it is still the process the session file names — the same pid at the same
/// start, read where the process is. Then the conversation is taken up in tmux
/// over there, by `SessionLauncher`. Piped to `python3` over ssh, as the probe is.
public enum RemoteMove {

    public enum Outcome: String, Equatable, Sendable {
        /// It ended: the conversation has no writer now.
        case ended
        /// Not the process the file names any more, or gone already: nothing sent.
        case notIt = "not-it"
        /// Still running ten seconds after it was asked to end.
        case stillRunning = "still-running"
        /// Another Move of the same conversation is under way (H1.5-3): nothing sent.
        case locked
    }

    /// Where the lock of a Move lives on the session's machine, one folder per
    /// conversation (H1.5-3): `mkdir` is atomic, so of two Moves of the same
    /// conversation, from two devices or a device and the Mac, one takes it.
    public static let lockFolder = ".lampboard/moving"

    /// How long a lock holds without its Move finishing it: a Move cut off
    /// half-way (the phone put away, the link gone) must not refuse every later
    /// one for ever.
    public static let lockLasts: TimeInterval = 300

    /// The Move under a lock: `script(pid:procStart:)` run only by whoever took
    /// `~/.lampboard/moving/<session>`; a second Move while it is held is
    /// `locked`, and ends nothing. When nothing was ended (`not-it`,
    /// `still-running`) the lock goes at once; when the process ended it stays
    /// until the conversation is taken up again (`unlock`), so that no Move
    /// starts a second writer meanwhile.
    public static func lockedScript(pid: Int32, procStart: String, session: String) -> String? {
        guard pid > 1, let quoted = quotedStart(procStart), isLockable(session) else { return nil }
        return """
        import os, signal, subprocess, sys, time, json
        pid = \(pid)
        start = json.loads('\(quoted)')[0]
        lock = os.path.join(os.path.expanduser("~"), "\(lockFolder)", "\(session)")
        \(startedFunction)
        def take():
            os.makedirs(os.path.dirname(lock), mode=0o700, exist_ok=True)
            try:
                os.mkdir(lock, 0o700)
                return True
            except FileExistsError:
                pass
            try:
                if time.time() - os.stat(lock).st_mtime < \(Int(lockLasts)):
                    return False
                os.rmdir(lock)
                os.mkdir(lock, 0o700)
                return True
            except OSError:
                return False
        def done(word, keep=False):
            if not keep:
                try:
                    os.rmdir(lock)
                except OSError:
                    pass
            print(word); sys.exit(0)
        if not take():
            print("locked"); sys.exit(0)
        if started_at(pid) != start:
            done("not-it")
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            time.sleep(0.2)
            if started_at(pid) != start:
                done("ended", keep=True)
        done("still-running")
        """
    }

    /// Lets go of the lock once the conversation goes on elsewhere.
    public static func unlock(session: String) -> String? {
        guard isLockable(session) else { return nil }
        return "rmdir \"$HOME\"/\(lockFolder)/\(session) 2>/dev/null; true"
    }

    /// A conversation's id as a folder's name: what Claude Code writes, nothing a shell or a path reads twice.
    static func isLockable(_ session: String) -> Bool {
        ModReport.isSessionId(session) && !session.hasPrefix("-")
    }

    /// The script for `pid` started at `procStart` (clock ticks in `/proc` on
    /// Linux, `ps`'s start time in UTC on a Mac, as Claude Code writes it).
    public static func script(pid: Int32, procStart: String) -> String? {
        guard pid > 1, let quoted = quotedStart(procStart) else { return nil }
        return """
        import os, signal, subprocess, sys, time, json
        pid = \(pid)
        start = json.loads('\(quoted)')[0]
        def started():
            return started_at(pid)
        \(startedFunction)
        if started() != start:
            print("not-it"); sys.exit(0)
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            time.sleep(0.2)
            if started() != start:
                print("ended"); sys.exit(0)
        print("still-running")
        """
    }

    /// A start time as one JSON string, or `nil` for one that is not a start
    /// time: nothing else is ever written into a script.
    static func quotedStart(_ procStart: String) -> String? {
        let start = procStart.trimmingCharacters(in: .whitespaces)
        guard !start.isEmpty, start.count <= 64,
              start.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == ":" }),
              let quoted = try? String(decoding: JSONSerialization.data(withJSONObject: [start]), as: UTF8.self) else { return nil }
        return quoted
    }

    /// When a process started, as Claude Code writes it in a session file:
    /// clock ticks from `/proc` on Linux, `ps`'s start time in UTC on a Mac;
    /// `None` for one that has ended. The one reading of it the scripts that
    /// end or move a session share (`RemoteEnd`, `RemoteResume`): a pid reused
    /// since the file was written has another start, and is not it.
    static let startedFunction = """
    def started_at(pid):
        try:
            with open("/proc/%d/stat" % pid) as stat:
                fields = stat.read().rsplit(")", 1)[1].split()
            # Ended and not yet reaped by its parent: ended all the same.
            return None if fields[0] == "Z" else fields[19]
        except FileNotFoundError:
            if os.path.isdir("/proc"):
                return None
        except Exception:
            return None
        try:
            out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                                 env=dict(os.environ, TZ="UTC"), timeout=3).stdout.strip()
            return out or None
        except Exception:
            return None
    """

    public static func outcome(_ output: String) -> Outcome? {
        Outcome(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
    }
}
