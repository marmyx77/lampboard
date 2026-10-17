import Foundation

/// A background session of another machine (`claude --bg`) opened from a
/// device: `claude attach <job>` over ssh, in a terminal (L.A8, R1-24, H1.3-14).
///
/// Never a second attach (D130): the attach runs under a lock on that machine,
/// `~/.lampboard/attach/<job>.lock`, held by the process that waits for it and
/// let go when it ends, whatever ends it (the terminal closed, the link gone, a
/// signal). A second device or window that asks while one is open is told so and
/// attaches nothing. A lock file rather than a search of the process list: a
/// list read and then acted on lets two arrive together, and a lock that dies
/// with its holder never has to be cleaned.
public enum BackgroundAttach {

    /// What the refusal prints, and the exit status it ends with.
    public static let refusal = "This background session is open from another window or device: close it there first."
    public static let refusedStatus = 5

    /// The command for a terminal on `job`; `nil` for an id that is not a job's.
    /// The person's own shell, interactive, so that its startup files put
    /// `claude` on PATH, as in a tmux pane LampBoard starts (D133).
    public static func command(job: String) -> String? {
        guard BackgroundJobParser.isSafe(id: job) else { return nil }
        let script = """
        import fcntl, os, signal, subprocess, sys
        job = "\(job)"
        folder = os.path.join(os.path.expanduser("~"), ".lampboard", "attach")
        os.makedirs(folder, mode=0o700, exist_ok=True)
        lock = os.open(os.path.join(folder, job + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("\(refusal)", flush=True)
            sys.exit(\(refusedStatus))
        shell = os.environ.get("SHELL") or "/bin/sh"
        env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")
        # The lock stays here, in the process that waits: `claude` and whatever it
        # starts never hold it, so it goes when this does.
        for name in ("SIGINT", "SIGQUIT", "SIGTSTP"):
            signal.signal(getattr(signal, name), signal.SIG_IGN)
        def own_signals():
            for name in ("SIGINT", "SIGQUIT", "SIGTSTP"):
                signal.signal(getattr(signal, name), signal.SIG_DFL)
        child = subprocess.Popen([shell, "-ilc", "exec claude attach \(job)"], env=env, close_fds=True,
                                 preexec_fn=own_signals)
        sys.exit(child.wait())
        """
        return NewSession.posix("exec python3 -B -c " + NewSession.shellQuoted(script))
    }
}
