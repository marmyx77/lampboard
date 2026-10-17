import Foundation

/// «End session…» on another machine, asked from a device that knows the
/// conversation and not its process (W3 of the mobile plan, L.H6, H1.4-13).
///
/// The process is found there, where it runs: the session file under
/// `~/.claude/sessions` that names the conversation, and only if the pid it
/// names is still the process that wrote it — alive, and started when the file
/// says. A pid reused since is another program: nothing is sent to it (the rule
/// `SessionTerminator` keeps on the Mac, and `RemoteMove` over ssh).
///
/// In tmux, the tmux session is closed, as the panel does (D168), but only when
/// one of its panes holds that very process: a name typed on a phone never
/// closes a tmux session of somebody else's. Outside tmux the process gets
/// `SIGTERM`, never `SIGKILL`, and the time to save what it holds.
/// Piped to `python3` over ssh, as the probe is.
public enum RemoteEnd {

    public enum Outcome: String, Equatable, Sendable {
        /// It ended: its tmux session closed, or its process stopped.
        case ended
        /// No live process holds the conversation as its file says (gone, or
        /// its pid reused), or the tmux session named does not hold it: nothing sent.
        case notIt = "not-it"
        /// Still running ten seconds after it was asked to end.
        case stillRunning = "still-running"
    }

    /// The script for `session`, closing the tmux session `tmux` when it holds
    /// the process; `nil` for an id or a name that is not one.
    public static func script(session: String, tmux: String? = nil) -> String? {
        guard ModReport.isSessionId(session), !session.hasPrefix("-") else { return nil }
        if let tmux, !TmuxSizeRule.isSessionName(tmux) { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: [session, tmux ?? ""]) else { return nil }
        return """
        import base64, glob, json, os, signal, subprocess, sys, time
        session, tmux = json.loads(base64.b64decode("\(data.base64EncodedString())").decode("utf-8"))
        \(RemoteMove.startedFunction)
        def found():
            for path in glob.glob(os.path.join(os.path.expanduser("~/.claude/sessions"), "*.json")):
                try:
                    meta = json.load(open(path))
                    pid = int(meta["pid"])
                    start = str(meta.get("procStart") or "")
                except Exception:
                    continue
                if meta.get("sessionId") != session or pid <= 1 or not start:
                    continue
                if os.path.basename(path) == "%d.json" % pid and started_at(pid) == start:
                    return pid, start
            return None
        def parent(pid):
            try:
                with open("/proc/%d/stat" % pid) as stat:
                    return int(stat.read().rsplit(")", 1)[1].split()[1])
            except FileNotFoundError:
                if os.path.isdir("/proc"):
                    return None
            except Exception:
                return None
            try:
                out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True, timeout=3).stdout
                return int(out.strip())
            except Exception:
                return None
        def ancestors(pid):
            seen = []
            while pid and pid > 1 and pid not in seen and len(seen) < 64:
                seen.append(pid)
                pid = parent(pid)
            return seen
        def wait(pid, start):
            for _ in range(50):
                if started_at(pid) != start:
                    print("ended"); sys.exit(0)
                time.sleep(0.2)
            print("still-running"); sys.exit(0)
        held = found()
        if held is None:
            print("not-it"); sys.exit(0)
        pid, start = held
        if tmux:
            env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")
            try:
                panes = subprocess.run(["tmux", "list-panes", "-s", "-t", "=" + tmux, "-F", "#{pane_pid}"],
                                       capture_output=True, text=True, timeout=5, env=env).stdout.split()
            except Exception:
                panes = []
            if not set(int(p) for p in panes if p.isdigit()) & set(ancestors(pid)):
                print("not-it"); sys.exit(0)
            subprocess.run(["tmux", "kill-session", "-t", "=" + tmux], capture_output=True, timeout=5, env=env)
            wait(pid, start)
        os.kill(pid, signal.SIGTERM)
        wait(pid, start)
        """
    }

    public static func outcome(_ output: String) -> Outcome? {
        Outcome(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
    }
}
