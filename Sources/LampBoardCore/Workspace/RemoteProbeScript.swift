import Foundation

/// The script that runs **on** the remote machine.
///
/// It lives in Core, and in one piece, for the same reason the hook script does:
/// it is a promise made to another machine, and a promise you cannot read in one
/// place is a promise nobody checks. It is also under test — the shape it emits is
/// what `RemoteSessionsDecoder` parses, and the two must not drift apart.
///
/// **Why the work happens there and not here.** Two of the three facts a row needs
/// are only true where the processes are: whether the pid is alive, and when the
/// transcript last changed. Shipping the files here and deciding locally would
/// answer both questions about the wrong machine.
///
/// Nothing is installed on the node and nothing is left behind: the script is
/// piped to `python3` over the ssh connection and dies with it.
public enum RemoteProbeScript {

    /// `python3` because it is the one interpreter present on every machine that
    /// runs Claude Code, and because the encoding rule below has to match
    /// `TranscriptLocator` exactly — expressing it in shell would mean two
    /// dialects of the same rule.
    public static let script = """
    import json, os, glob, re, sys

    def encoded(cwd):
        return "-" + re.sub(r"[^a-zA-Z0-9]", "-", cwd.lstrip("/"))

    def alive(pid, proc_start):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            # The process exists and belongs to somebody else. Still alive.
            return True
        except Exception:
            return False
        # A pid outlives its process: after a reboot, or once the counter wraps,
        # the same number names something else, and kill(pid, 0) says "alive"
        # about a session that is long gone. The session file remembers the
        # process's start time in clock ticks; on Linux /proc has the truth.
        if proc_start:
            try:
                with open("/proc/%d/stat" % pid) as stat:
                    after_comm = stat.read().rsplit(")", 1)[1].split()
                if after_comm[19] != str(proc_start):
                    return False
            except Exception:
                pass
        return True

    out = []
    for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
        try:
            record = json.load(open(path))
            pid = int(os.path.basename(path).split(".")[0])
        except Exception:
            continue
        if not alive(pid, record.get("procStart")):
            continue
        cwd = record.get("cwd") or ""
        # The session file is written once at startup and never touched again, so
        # on its own it reports how long the session has been open, not when it
        # last did anything. The transcript is the real signal.
        try:
            activity = os.path.getmtime(path)
        except OSError:
            continue
        folder = os.path.expanduser("~/.claude/projects/") + encoded(cwd)
        for transcript in glob.glob(folder + "/*.jsonl"):
            try:
                activity = max(activity, os.path.getmtime(transcript))
            except OSError:
                pass
        # A miniature of the transcript's tail, in the same shape as the real
        # thing, so that the Mac reads a remote session with exactly the code it
        # reads a local one with. The rule for what these records mean, which
        # is a reply, what a compaction does to it, when a number is only a
        # floor, stays in one place: on the machine we actually update. This
        # side only projects the fields that rule reads, and judges nothing.
        tail = ""
        own = folder + "/" + str(record.get("sessionId") or "") + ".jsonl"
        try:
            size = os.path.getsize(own)
            with open(own, "rb") as handle:
                handle.seek(max(0, size - 32768))
                chunk = handle.read().decode("utf-8", "ignore")
            kept, replies = [], 0
            for line in reversed(chunk.split("\\n")):
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                message = entry.get("message") or {}
                usage = message.get("usage") or {}
                small = {"type": entry.get("type"), "timestamp": entry.get("timestamp")}
                if entry.get("compactMetadata") is not None:
                    small["compactMetadata"] = {}
                if message.get("model"):
                    small["message"] = {"model": message.get("model"), "usage": {
                        k: usage.get(k, 0) for k in (
                            "input_tokens", "cache_creation_input_tokens",
                            "cache_read_input_tokens")}}
                    if usage.get("iterations"):
                        small["message"]["usage"]["iterations"] = usage["iterations"][-1:]
                    if message.get("model") != "<synthetic>" and usage:
                        replies += 1
                kept.append(small)
                # Two candidates rather than one: the first may report zeros at
                # the top level with the real figure inside `iterations`, and the
                # far end must not have to know that to send enough.
                if replies >= 2:
                    break
            tail = "\\n".join(json.dumps(x) for x in reversed(kept))
        except Exception:
            tail = ""
        out.append({
            "pid": pid,
            "sessionId": record.get("sessionId"),
            "cwd": cwd,
            "entrypoint": record.get("entrypoint"),
            "name": record.get("name"),
            "kind": record.get("kind"),
            "activityEpoch": int(activity),
            "contextTail": tail,
        })

    # The editor windows open on this machine, from the same lock files the Mac
    # reads for its own: the Remote-SSH extension runs here and writes them here.
    # Judged alive here too, because the pid means nothing anywhere else.
    windows = []
    for path in glob.glob(os.path.expanduser("~/.claude/ide/*.lock")):
        try:
            lock = json.load(open(path))
            folders = [f for f in (lock.get("workspaceFolders") or []) if isinstance(f, str) and f.startswith("/")]
            pid = int(lock.get("pid") or 0)
            mtime = int(os.path.getmtime(path))
        except Exception:
            continue
        if not folders:
            continue
        windows.append({
            "workspaceFolders": folders,
            "ideName": lock.get("ideName") or "",
            "pid": pid,
            "alive": bool(pid) and alive(pid, None),
            "mtimeEpoch": mtime,
        })

    json.dump({"sessions": out, "windows": windows}, sys.stdout)
    """
}
