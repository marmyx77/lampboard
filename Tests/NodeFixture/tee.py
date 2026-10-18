#!/usr/bin/env python3
"""The other ends of lampd's hooks' port on the fake node, for its gate (W5).

lampd, holding the hooks' port in tee, answers the hooks and passes each one
on to the Mac's tunnel on the next port, and sends this machine's
notifications to the push relay. Neither the Mac nor the relay is on a fake
node, so this plays both, and plays the hooks and the mod as they post:

    tee.py mac <port> <log>           the Mac's end of the tunnel: every request it
                                      gets as one JSON line in <log>; /check is
                                      held eight seconds and answered "allow.signed"
    tee.py relay <port> <log>         the push relay: every push's kind in <log>
    tee.py post <port> <path> [--token <file>] [--header K:V]... [--body <json>]
                                      one request, its status and body printed
    tee.py play <port> <flow.jsonl> --token <file>
                                      a recorded flow posted as the hook script posts it
    tee.py flow <log> <session>...    what the Mac's end received, as a flow file
                                      (the format of Tests/NodeFixture/flows)
    tee.py listening <port>           the addresses <port> is bound to (from /proc)
    tee.py device <state-dir>         a device registered for notifications
    tee.py hook <port> <event> <session> [<extra-json>] [--token <hex>]
                                      a hook's post with ~/.lampboard/token (or <hex>)
    tee.py row <session>              its row as `lampd rows` has it: status, basis,
                                      held by the Mac, question
    tee.py alerts <log>               how many alerts the relay was handed

Runs on the node, as its account, in a container: never on a real machine. It
refuses to run where the home has no ~/.lampd-fixture marker.
"""
import base64, http.server, json, os, socket, socketserver, sys, threading, time, urllib.request

HOME = os.path.expanduser("~")


def refuse_unless_fake():
    if not os.path.isdir(os.path.join(HOME, ".lampd-fixture")):
        sys.exit("tee.py: this home has no ~/.lampd-fixture: not a fake node, nothing done")


def serve(port, log, answer):
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def handle_any(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            entry = {"at": time.time(), "method": self.command, "path": self.path,
                     "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body.decode("utf-8", "replace")}
            with lock, open(log, "a") as out:
                out.write(json.dumps(entry, sort_keys=True) + "\n")
            status, text = answer(entry)
            data = text.encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = handle_any

        def log_message(self, *args):
            pass

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    Server(("127.0.0.1", port), Handler).serve_forever()


def mac_answer(entry):
    if entry["path"] == "/check":
        time.sleep(8)
        return 200, "allow.signed"
    return 200, "lampboard-mac"


def relay_answer(entry):
    return 200, json.dumps({"outcome": "ok", "status": "ok"})


def post(port, path, headers, body, method=None):
    data = body.encode() if body is not None else None
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method or ("POST" if data else "GET"))
    for key, value in headers.items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=80) as reply:
            return reply.status, reply.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")


def listening(port):
    found = []
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = open(table).read().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            local, state = fields[1], fields[3]
            address, hex_port = local.split(":")
            if state != "0A" or int(hex_port, 16) != port:
                continue
            if len(address) == 8:
                found.append(socket.inet_ntoa(bytes.fromhex(address)[::-1]))
            else:
                found.append("ipv6:" + address)
    return found


def main():
    refuse_unless_fake()
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    command = args[0]
    if command == "mac":
        serve(int(args[1]), args[2], mac_answer)
    elif command == "relay":
        serve(int(args[1]), args[2], relay_answer)
    elif command == "post":
        port, path = int(args[1]), args[2]
        headers, body, rest = {}, None, args[3:]
        while rest:
            key = rest.pop(0)
            if key == "--token":
                headers["X-LampBoard-Token"] = open(rest.pop(0)).read().strip()
            elif key == "--header":
                name, value = rest.pop(0).split(":", 1)
                headers[name] = value
            elif key == "--body":
                body = rest.pop(0)
                headers["Content-Type"] = "application/json"
        status, text = post(port, path, headers, body)
        print(status, text)
    elif command == "play":
        port, flow, token = int(args[1]), args[2], open(args[4]).read().strip()
        for line in open(flow):
            if not line.strip():
                continue
            event = json.loads(line)
            headers = {"X-LampBoard-Token": token, "X-Claude-Entrypoint": event.get("entrypoint") or "",
                       "X-LampBoard-Harness": "claude", "Content-Type": "application/json"}
            status, _ = post(port, "/signal", headers, json.dumps(event["payload"], sort_keys=True))
            if status != 204:
                sys.exit(f"tee.py play: {event['payload'].get('hook_event_name')} answered {status}")
    elif command == "flow":
        log, sessions = args[1], set(args[2:])
        entries = [json.loads(l) for l in open(log) if l.strip()]
        start = None
        for entry in entries:
            if entry["path"] != "/signal":
                continue
            payload = json.loads(entry["body"])
            if payload.get("session_id") not in sessions:
                continue
            start = start if start is not None else entry["at"]
            print(json.dumps({"at": round(entry["at"] - start, 3), "entrypoint": entry["headers"].get("x-claude-entrypoint") or None,
                              "payload": payload}, sort_keys=True, separators=(",", ":")))
    elif command == "listening":
        print(" ".join(listening(int(args[1]))))
    elif command == "hook":
        port, event, session = int(args[1]), args[2], args[3]
        rest = args[4:]
        token = open(os.path.join(HOME, ".lampboard", "token")).read().strip()
        if "--token" in rest:
            token = rest[rest.index("--token") + 1]
            rest = rest[:rest.index("--token")]
        payload = {"cwd": "/home/dev/work/x", "hook_event_name": event, "session_id": session}
        if rest:
            payload.update(json.loads(rest[0]))
        headers = {"X-LampBoard-Token": token, "X-Claude-Entrypoint": "cli", "Content-Type": "application/json"}
        status, text = post(port, "/signal", headers, json.dumps(payload, sort_keys=True))
        print(status, text)
    elif command == "row":
        import subprocess
        rows = json.loads(subprocess.run(["lampd", "rows"], capture_output=True, text=True).stdout or "[]")
        found = [r for r in rows if r.get("id") == args[1]]
        if not found:
            print("absent")
        else:
            r = found[0]
            print(r["status"], r.get("stateBasis", "-"), str(r.get("heldByMac", False)).lower(), r.get("pendingAsk"))
    elif command == "alerts":
        count = 0
        try:
            for line in open(args[1]):
                entry = json.loads(line)
                if entry["path"] == "/v1/push" and json.loads(entry["body"] or "{}").get("kind") == "alert":
                    count += 1
        except OSError:
            pass
        print(count)
    elif command == "device":
        state = args[1]
        os.makedirs(state, mode=0o700, exist_ok=True)
        devices = {"check-phone": {"at": "2026-10-18T00:00:00Z", "registration": {
            "capability": base64.b64encode(b"capability").decode(), "token": "ab" * 32, "environment": "sandbox",
            "envelopeKey": base64.b64encode(os.urandom(32)).decode()}}}
        path = os.path.join(state, "push-devices.json")
        with open(path, "w") as out:
            json.dump(devices, out)
        os.chmod(path, 0o600)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
