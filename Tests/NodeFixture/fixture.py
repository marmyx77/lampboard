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
    fixture.py ask <n>       session n of frame 0 waiting for the person (amber),
                             and `fixture.py ask <n> off` busy again: the
                             notifications' check (W4)
    fixture.py clean         every process and file this made, gone
    fixture.py actions       what a phone's actions need besides frame 0: the
                             sessions' folders, a project with files, a fake
                             `claude` on PATH, a session with a message box
    fixture.py box-log       the messages that box took, one JSON line each
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


def ask(index, on=True):
    state = load_state()
    frames = json.load(open(os.path.join(HERE, "sessions.json")))["frames"]
    chosen = frames[0]["sessions"][index]
    pid = state["pids"].get(chosen["key"])
    path = os.path.join(SESSIONS, "%d.json" % pid)
    record = json.load(open(path))
    record["status"] = "waiting" if on else "busy"
    if on:
        record["waitingFor"] = "permission"
    else:
        record.pop("waitingFor", None)
    record["statusUpdatedAt"] = int(time.time() * 1000)
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


# ── What a phone's actions need (W3) ─────────────────────────────────────────

BOX_LOG = os.path.join(HOME, ".lampd-fixture", "box.log")
BOX_SESSION = "b2000000-0000-4000-8000-000000000001"
EDITORS = {"iphone": "c3000000-0000-4000-8000-000000000001", "ipad": "c3000000-0000-4000-8000-000000000002"}
SPARES = {"iphone": "d4000000-0000-4000-8000-000000000001", "ipad": "d4000000-0000-4000-8000-000000000002"}

# A `claude` that does what the actions need of it and nothing else: started
# with a conversation's id it writes its session file as Claude Code does (its
# own pid and start) and stays until it is asked to end; `attach <job>` notes
# itself and stays. Never the real one: this is a fake node.
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
home = os.path.expanduser("~")
args = sys.argv[1:]
def start_of(pid):
    with open("/proc/%d/stat" % pid) as stat:
        return stat.read().rsplit(")", 1)[1].split()[19]
if args[:1] == ["attach"] and len(args) > 1:
    with open(os.path.join(home, ".lampd-fixture", "attach.log"), "a") as log:
        log.write("%d %s\n" % (os.getpid(), args[1]))
    print("attached " + args[1], flush=True)
    while True:
        time.sleep(1)
session = None
for flag in ("--session-id", "--resume"):
    if flag in args and args.index(flag) + 1 < len(args):
        session = args[args.index(flag) + 1]
if session is None:
    print("fake claude: nothing to do", flush=True)
    sys.exit(1)
pid = os.getpid()
path = os.path.join(home, ".claude", "sessions", "%d.json" % pid)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as handle:
    json.dump({"pid": pid, "sessionId": session, "cwd": os.getcwd(), "entrypoint": "cli", "kind": "interactive",
               "status": "idle", "procStart": start_of(pid)}, handle)
folder = os.path.join(home, ".claude", "projects",
                      "-" + "".join(c if c.isascii() and c.isalnum() else "-" for c in os.getcwd().lstrip("/")))
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, session + ".jsonl"), "a") as handle:
    handle.write(json.dumps({"type": "user", "origin": {"kind": "human"}, "timestamp": "2027-01-15T08:00:00Z",
                             "message": {"role": "user", "content": "Example start"}}) + "\n")
def bye(*_):
    try:
        os.remove(path)
    except OSError:
        pass
    sys.exit(0)
signal.signal(signal.SIGTERM, bye)
signal.signal(signal.SIGHUP, bye)
print("fake claude " + session + " " + ("--resume" if "--resume" in args else "new"), flush=True)
while True:
    time.sleep(1)
'''


def actions():
    """The folders frame 0's sessions work in, a project with files, the fake
    `claude` first on PATH, and a session whose message box writes down what it
    takes (the box of Claude Code 2.1.224 and later, D81)."""
    for name in ("api", "web", "docs", "billing", "search", "mobile", "old", "old2", "blank", "sdk", "batch", "twin",
                 "site", "editor", "uinew", "uinew-iphone", "uinew-ipad"):
        os.makedirs(os.path.join(HOME, "work", name), exist_ok=True)
    api = os.path.join(HOME, "work", "api")
    os.makedirs(os.path.join(api, "src"), exist_ok=True)
    os.makedirs(os.path.join(api, ".git", "info"), exist_ok=True)
    with open(os.path.join(api, "README.md"), "w") as handle:
        handle.write("# Example API\n\nA project for the **phone's** file view.\n\n- one\n- two\n")
    with open(os.path.join(api, "src", "main.py"), "w") as handle:
        handle.write("print('example')\n")
    os.makedirs(os.path.join(HOME, ".local", "bin"), exist_ok=True)
    claude = os.path.join(HOME, ".local", "bin", "claude")
    with open(claude, "w") as handle:
        handle.write(FAKE_CLAUDE)
    os.chmod(claude, 0o755)
    # The box: a process that listens, and the files that name it.
    state = load_state()
    old = state.get("box")
    if old and alive(old):
        stop(old)
    socket_path = "/tmp/lb-box-%d.sock" % os.getpid()
    token = "exampletoken%d" % os.getpid()
    child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "box", BOX_SESSION, socket_path, token],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    for _ in range(50):
        if os.path.exists(socket_path):
            break
        time.sleep(0.1)
    start = proc_start(child.pid)
    os.makedirs(SESSIONS, exist_ok=True)
    with open(os.path.join(SESSIONS, "%d.json" % child.pid), "w") as handle:
        json.dump({"pid": child.pid, "sessionId": BOX_SESSION, "cwd": os.path.join(HOME, "work", "docs"),
                   "entrypoint": "cli", "kind": "interactive", "status": "idle", "procStart": start,
                   "peerProtocol": 1, "messagingSocketPath": socket_path}, handle)
    # A conversation, so that its session earns a row a person can find by name.
    box_transcripts = os.path.join(PROJECTS, encoded(os.path.join(HOME, "work", "docs")))
    os.makedirs(box_transcripts, exist_ok=True)
    with open(os.path.join(box_transcripts, BOX_SESSION + ".jsonl"), "w") as handle:
        handle.write(transcript_lines({"id": BOX_SESSION}))
    key = os.path.join(SESSIONS, "%d.%s.key" % (child.pid, "ab12cd34"))
    with open(key, "w") as handle:
        json.dump({"peerToken": token, "procStart": start}, handle)
    os.chmod(key, 0o600)
    if os.path.exists(BOX_LOG):
        os.remove(BOX_LOG)
    state["box"] = child.pid
    # Two conversations in VS Code, one for each device the app's tests run on:
    # a Move ends its editor's process, and a run on the iPad comes after the
    # iPhone's on the same node.
    editors = {}
    for device, session in EDITORS.items():
        folder = os.path.join(HOME, "work", "site-" + device)
        os.makedirs(folder, exist_ok=True)
        old = state.get("editors", {}).get(device)
        if old and alive(old):
            stop(old)
        pid = start_process("editor-" + device, None)
        editors[device] = pid
        with open(os.path.join(SESSIONS, "%d.json" % pid), "w") as handle:
            json.dump({"pid": pid, "sessionId": session, "cwd": folder, "entrypoint": "claude-vscode",
                       "kind": "interactive", "status": "idle", "procStart": proc_start(pid)}, handle)
        transcripts = os.path.join(PROJECTS, encoded(folder))
        os.makedirs(transcripts, exist_ok=True)
        with open(os.path.join(transcripts, session + ".jsonl"), "w") as handle:
            handle.write(transcript_lines({"id": session}))
    state["editors"] = editors
    # A quiet conversation for each device, last spoken an hour ago: one a device
    # takes off its list (a row taken off comes back only when it speaks after).
    spoke = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
    spares = {}
    for device, session in SPARES.items():
        folder = os.path.join(HOME, "work", "spare-" + device)
        os.makedirs(folder, exist_ok=True)
        old = state.get("spares", {}).get(device)
        if old and alive(old):
            stop(old)
        pid = start_process("spare-" + device, None)
        spares[device] = pid
        with open(os.path.join(SESSIONS, "%d.json" % pid), "w") as handle:
            json.dump({"pid": pid, "sessionId": session, "cwd": folder, "entrypoint": "cli",
                       "kind": "interactive", "status": "idle", "procStart": proc_start(pid)}, handle)
        transcripts = os.path.join(PROJECTS, encoded(folder))
        os.makedirs(transcripts, exist_ok=True)
        with open(os.path.join(transcripts, session + ".jsonl"), "w") as handle:
            handle.write(transcript_lines({"id": session, "spoke": spoke}))
    state["spares"] = spares
    save_state(state)
    print("actions: folders, project, fake claude, box %d, editors %s" % (child.pid, sorted(editors.values())))


def box(session, socket_path, token):
    """The message box: one line of auth with the token, then messages, each
    written down as it came. It answers nothing, as Claude Code's does not."""
    import socket as sockets
    server = sockets.socket(sockets.AF_UNIX, sockets.SOCK_STREAM)
    if os.path.exists(socket_path):
        os.remove(socket_path)
    server.bind(socket_path)
    server.listen(4)
    while True:
        connection, _ = server.accept()
        data = b""
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
        connection.close()
        lines = [json.loads(line) for line in data.decode("utf-8").splitlines() if line.strip()]
        if not lines or lines[0].get("type") != "auth" or lines[0].get("token") != token:
            continue
        with open(BOX_LOG, "a") as log:
            for line in lines[1:]:
                if line.get("type") == "user":
                    log.write(json.dumps({"session": session, "from": line.get("from"),
                                          "content": line.get("message", {}).get("content")}) + "\n")


if __name__ == "__main__":
    refuse_unless_fake()
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "frame" and len(sys.argv) == 3:
        frame(int(sys.argv[2]))
    elif command == "flip":
        flip()
    elif command == "ask" and len(sys.argv) in (3, 4):
        ask(int(sys.argv[2]), on=not (len(sys.argv) == 4 and sys.argv[3] == "off"))
    elif command == "clean":
        clean()
    elif command == "actions":
        actions()
    elif command == "box" and len(sys.argv) == 5:
        box(sys.argv[2], sys.argv[3], sys.argv[4])
    elif command == "box-log":
        sys.stdout.write(open(BOX_LOG).read() if os.path.exists(BOX_LOG) else "")
    else:
        sys.exit(__doc__)
