#!/usr/bin/env python3
"""Plays Claude Code's session files on a fake node, for lampd's gate.

Claude Code writes one file per live process in ~/.claude/sessions (its pid,
its session, a status word: busy, shell, waiting, idle), and the conversation
in ~/.claude/projects/<folder>/<session>.jsonl. The rule of what those mean is
the Core's, and both of its readers -- the phone's probe over ssh and lampd --
must give the same lamp for the same files. This writes the files those
readers read, frame by frame, from sessions.json beside it; the processes the
files name are `sleep`s started here, so that "is this pid alive, and is it
the process that wrote the file" has a true answer.

Runs on the node, as its account, in a container: never on a real machine.
It refuses to run where the home has no ~/.lampd-fixture marker, which only the
gate's container makes.

    fixture.py frame <n>     the node as frame n describes it
    fixture.py flip          the first session of frame 0 between busy and idle
    fixture.py clean         every process and file this made, gone
"""
import json, os, signal, subprocess, sys, time

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HOME, ".lampd-fixture", "state.json")
SESSIONS = os.path.join(HOME, ".claude", "sessions")
PROJECTS = os.path.join(HOME, ".claude", "projects")
JOBS = os.path.join(HOME, ".claude", "jobs")


def refuse_unless_fake():
    if not os.path.isdir(os.path.join(HOME, ".lampd-fixture")):
        sys.exit("fixture.py: this home has no ~/.lampd-fixture: not a fake node, nothing done")


def encoded(cwd):
    return "-" + "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd.lstrip("/"))


def load_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {"pids": {}}


def save_state(state):
    json.dump(state, open(STATE, "w"))


def proc_start(pid):
    with open("/proc/%d/stat" % pid) as stat:
        return stat.read().rsplit(")", 1)[1].split()[19]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def start_process(key, tmux):
    """A process that stays: in a tmux session of the default server, or alone."""
    if tmux:
        subprocess.run(["tmux", "-u", "kill-session", "-t", "=" + tmux], capture_output=True)
        subprocess.run(["tmux", "-u", "new-session", "-d", "-s", tmux, "sleep 100000"], check=True)
        out = subprocess.run(["tmux", "-u", "list-panes", "-t", "=" + tmux, "-F", "#{pane_pid}"],
                             capture_output=True, text=True, check=True).stdout.split()
        return int(out[0])
    child = subprocess.Popen(["sleep", "100000"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    return child.pid


def stop(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass


def transcript_lines(session):
    turn, spoke = session.get("turn", "ended"), session.get("spoke", "2027-01-15T08:00:00Z")
    usage = {"input_tokens": 12, "cache_creation_input_tokens": 3000, "cache_read_input_tokens": 41000}
    lines = [{"type": "user", "origin": {"kind": "human"}, "timestamp": spoke,
              "message": {"role": "user", "content": "Example request for " + session["id"][:8]}}]
    if turn in ("open", "ended", "compacted"):
        lines.append({"type": "assistant", "timestamp": spoke,
                      "message": {"model": "claude-opus-4-5", "stop_reason": "tool_use" if turn == "open" else "end_turn",
                                  "role": "assistant", "content": [{"type": "text", "text": "Example answer"}],
                                  "usage": usage}})
    if turn in ("ended", "compacted"):
        lines.append({"type": "system", "subtype": "turn_duration", "timestamp": spoke})
    if turn == "compacted":
        # Claude Code compacting a conversation nobody is typing in: the summary
        # is a `user` record nobody typed, and no prompt (D177).
        lines.append({"type": "user", "isCompactSummary": True, "timestamp": spoke,
                      "message": {"role": "user", "content": "Example summary of the conversation"}})
    return "\n".join(json.dumps(line) for line in lines) + "\n"


def frame(number):
    frames = json.load(open(os.path.join(HERE, "sessions.json")))["frames"]
    wanted = frames[number]["sessions"]
    state = load_state()
    pids = state["pids"]
    keys = set()
    os.makedirs(SESSIONS, exist_ok=True)
    os.makedirs(PROJECTS, exist_ok=True)
    for session in wanted:
        key = session["key"]
        keys.add(key)
        pid = pids.get(key)
        if session.get("alive", True):
            if pid is None or not alive(pid) or session.get("restart"):
                if pid:
                    stop(pid)
                pid = start_process(key, session.get("tmux"))
            start = proc_start(pid)
        else:
            if pid and alive(pid):
                stop(pid)
            # A pid nobody holds: started, then gone.
            gone = subprocess.Popen(["true"])
            gone.wait()
            pid, start = gone.pid, "1"
        pids[key] = pid
        if session.get("reused"):
            start = str(int(start) + 12345)
        record = {"pid": pid, "sessionId": session["id"], "cwd": session["cwd"],
                  "entrypoint": session.get("entrypoint", "cli"), "kind": session.get("kind", "interactive"),
                  "status": session["status"], "procStart": start}
        if "waitingFor" in session:
            record["waitingFor"] = session["waitingFor"]
        path = os.path.join(SESSIONS, "%d.json" % pid)
        with open(path, "w") as handle:
            json.dump(record, handle)
        folder = os.path.join(PROJECTS, encoded(session["cwd"]))
        os.makedirs(folder, exist_ok=True)
        transcript = os.path.join(folder, session["id"] + ".jsonl")
        if session.get("transcript", True):
            with open(transcript, "w") as handle:
                handle.write(transcript_lines(session))
        elif os.path.exists(transcript):
            os.remove(transcript)
        if "job" in session:
            os.makedirs(os.path.join(JOBS, session["job"]), exist_ok=True)
            with open(os.path.join(JOBS, session["job"], "state.json"), "w") as handle:
                json.dump({"sessionId": session["id"], "detail": session.get("jobDetail", "Example work"),
                           "tempo": "working"}, handle)
    # What the frame no longer has: its process and its file go.
    for key, pid in list(pids.items()):
        if key not in keys:
            stop(pid)
            try:
                os.remove(os.path.join(SESSIONS, "%d.json" % pid))
            except OSError:
                pass
            del pids[key]
    # Files of processes that are gone and no frame names any more.
    known = {"%d.json" % pid for pid in pids.values()}
    for name in os.listdir(SESSIONS):
        if name not in known:
            os.remove(os.path.join(SESSIONS, name))
    save_state(state)
    print("frame %d: %d sessions" % (number, len(wanted)))


def flip():
    state = load_state()
    frames = json.load(open(os.path.join(HERE, "sessions.json")))["frames"]
    first = frames[0]["sessions"][0]
    pid = state["pids"].get(first["key"])
    path = os.path.join(SESSIONS, "%d.json" % pid)
    record = json.load(open(path))
    record["status"] = "idle" if record["status"] == "busy" else "busy"
    with open(path, "w") as handle:
        json.dump(record, handle)
    print(record["status"])


def clean():
    state = load_state()
    for pid in state["pids"].values():
        stop(pid)
    subprocess.run(["tmux", "-u", "kill-server"], capture_output=True)
    for folder in (SESSIONS, PROJECTS, JOBS):
        subprocess.run(["rm", "-rf", folder])
    save_state({"pids": {}})
    print("clean")


if __name__ == "__main__":
    refuse_unless_fake()
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "frame" and len(sys.argv) == 3:
        frame(int(sys.argv[2]))
    elif command == "flip":
        flip()
    elif command == "clean":
        clean()
    else:
        sys.exit(__doc__)
