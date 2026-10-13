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
    }

    /// The script for `pid` started at `procStart` (clock ticks in `/proc` on
    /// Linux, `ps`'s start time in UTC on a Mac, as Claude Code writes it).
    public static func script(pid: Int32, procStart: String) -> String? {
        let start = procStart.trimmingCharacters(in: .whitespaces)
        guard pid > 1, !start.isEmpty, start.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == ":" }),
              let quoted = try? String(decoding: JSONSerialization.data(withJSONObject: [start]), as: UTF8.self) else { return nil }
        return """
        import os, signal, subprocess, sys, time, json
        pid = \(pid)
        start = json.loads('\(quoted)')[0]
        def started():
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

    public static func outcome(_ output: String) -> Outcome? {
        Outcome(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
    }
}
