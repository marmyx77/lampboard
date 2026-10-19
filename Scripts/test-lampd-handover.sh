#!/bin/bash
#
# The hooks' port handed from the Mac's tunnel to lampd under systemd --user,
# with the repository's lampd.socket and lampd-socket-retry units as installed.
#
# WHY THIS EXISTS
# On 19 October 2026 the real switch (B.4) left the hooks' port empty: the Mac's
# tunnel moved to the next port as it should, the retry timer found the port
# free, and systemd refused `start lampd.socket` with "Socket service
# lampd.service already active, refusing" — lampd runs before the socket, in the
# shade, and a socket unit does not start while its service is up. Every two
# seconds the timer failed the same way and the node heard no hooks. The lampd
# gate never saw it: it starts lampd in a container, without systemd. This plays
# the hand-over with systemd itself.
#
# Then, the same evening: lampd restarted after the hand-over shut down the
# listening socket systemd had passed it, and the port went deaf for every lampd
# after, though systemd still called the socket active. So the hand-over is
# played with the real binary, and lampd is restarted once more after it.
#
# It renders lampd.socket, lampd.service and the retry units from deploy/lampd/
# under names of their own (`lampd-handover-<pid>`), on a free port of their
# own, into the user manager's runtime directory, with the static binary in a
# home of its own (LAMPBOARD_HOME), and removes them at the end. A listener
# stands for the Mac's tunnel and goes away; the port must then be lampd's, and
# stay lampd's across a restart. Nothing installed on this machine is touched.
#
# EXIT CODES
#   0  the port went to lampd, and stayed lampd's across a restart
#   1  it did not, or lampd does not build
#   3  no systemd --user or no container engine here: nothing was observed
#
# USAGE
#   Scripts/test-lampd-handover.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }
passed()         { printf '\033[32m✓\033[0m %s\n' "$1"; }

[ "$(uname -s)" = Linux ] || could_not_look "not Linux: the hand-over was not tried"
systemctl --user show-environment >/dev/null 2>&1 || could_not_look "no systemd --user manager answers: the hand-over was not tried"
[ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] || could_not_look "no XDG_RUNTIME_DIR: the hand-over was not tried"
command -v ss >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || could_not_look "no ss or python3: the hand-over was not tried"

CACHE="${LAMPBOARD_LAMPD_HANDOVER_CACHE:-$HOME/.cache/lampboard/lampd-handover}"
mkdir -p "$CACHE/bin"
Scripts/lampd-build.sh --out "$CACHE/bin" > "$CACHE/build.log" 2>&1
case $? in
    0) ;;
    3) could_not_look "lampd could not be built here (see $CACHE/build.log)" ;;
    *) tail -5 "$CACHE/build.log" | sed 's/^/    /'; failed "lampd does not build static" ;;
esac

NAME="lampd-handover-$$"
UNITS="$XDG_RUNTIME_DIR/systemd/user"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lampd-handover.XXXXXX")"
PORT=""
for candidate in $(seq $((40000 + $$ % 2000)) $((40000 + $$ % 2000 + 50))); do
    ss -Htln "sport = :$candidate" | grep -q . || { PORT=$candidate; break; }
done
[ -n "$PORT" ] || failed "no free port to play the hand-over on"

HOLDER=""
cleanup() {
    systemctl --user stop "$NAME-retry.timer" "$NAME.socket" "$NAME.service" >/dev/null 2>&1
    systemctl --user reset-failed "$NAME-retry.service" "$NAME.service" "$NAME.socket" >/dev/null 2>&1
    rm -f "$UNITS/$NAME.socket" "$UNITS/$NAME.service" "$UNITS/$NAME-retry.service" "$UNITS/$NAME-retry.timer"
    systemctl --user daemon-reload >/dev/null 2>&1
    [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The units as the installer writes them, under this run's names.
render() {
    sed -e "s/@HOOK_PORT@/$PORT/g" \
        -e "s/lampd-socket-retry\.service/$NAME-retry.service/g" \
        -e "s/lampd\.socket/$NAME.socket/g" \
        -e "s/lampd\.service/$NAME.service/g" \
        -e "s|%h/.local/state/lampd/hooks-released|$WORK/home/.local/state/lampd/hooks-released|g" \
        -e "s|^ExecStart=%h/.local/bin/lampd serve|ExecStart=$WORK/lampd serve|" \
        -e "s|^Environment=PATH=.*|Environment=PATH=/usr/local/bin:/usr/bin:/bin LAMPBOARD_HOME=$WORK/home HOME=$WORK/home TMUX_TMPDIR=$WORK/tmux|" "$1"
}
mkdir -p "$UNITS"
mkdir -p "$WORK/home/.claude/sessions" "$WORK/tmux"
install -m 0755 "$CACHE/bin/lampd" "$WORK/lampd"
render deploy/lampd/lampd.socket > "$UNITS/$NAME.socket"
render deploy/lampd/lampd.service > "$UNITS/$NAME.service"
render deploy/lampd/lampd-socket-retry.service > "$UNITS/$NAME-retry.service"
render deploy/lampd/lampd-socket-retry.timer > "$UNITS/$NAME-retry.timer"
grep -q "$NAME.socket" "$UNITS/$NAME-retry.service" || failed "the retry unit no longer names lampd.socket: the rendering is stale"
grep -q "^ExecStart=$WORK/lampd serve" "$UNITS/$NAME.service" || failed "lampd.service no longer runs %h/.local/bin/lampd serve: the rendering is stale"
lampd() { LAMPBOARD_HOME="$WORK/home" HOME="$WORK/home" TMUX_TMPDIR="$WORK/tmux" "$WORK/lampd" "$@"; }
hooks() { lampd status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hooks") or "")' 2>/dev/null; }
listening() { ss -Htln "sport = :$PORT" | grep -q .; }
# A connection taken and answered: a port systemd calls active may hear nothing.
answers() {
    python3 -c "
import socket, sys
s = socket.create_connection(('127.0.0.1', $PORT), timeout=3)
s.sendall(b'GET /health HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n')
sys.exit(0 if s.recv(64).startswith(b'HTTP/1.') else 1)" 2>/dev/null
}
systemctl --user daemon-reload || failed "systemd did not read the units"

# The Mac's tunnel on the port, and lampd running in the shade.
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT)); s.listen(); time.sleep(3600)" &
HOLDER=$!
for _ in $(seq 1 50); do ss -Htln "sport = :$PORT" | grep -q . && break; sleep 0.1; done
systemctl --user start "$NAME.service" || failed "lampd did not start in its unit"
systemctl --user start "$NAME-retry.timer" || failed "the retry timer did not start"
sleep 5
systemctl --user is-active -q "$NAME.socket" && failed "the socket started while the port was the tunnel's"
case "$(hooks)" in *"passed no port"*) ;; *) failed "lampd in the shade says: $(hooks)" ;; esac
passed "while the tunnel holds the port, the socket waits and lampd serves in the shade"

# The tunnel moves to the next port.
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
held=0
for _ in $(seq 1 40); do
    systemctl --user is-active -q "$NAME.socket" && { held=1; break; }
    sleep 0.5
done
if [ "$held" != 1 ]; then
    journalctl --user -u "$NAME-retry.service" -u "$NAME.socket" --since "-30s" --no-pager 2>/dev/null \
        | grep -E "refusing|Failed" | tail -3 | sed 's/^/    /'
    failed "the hooks' port stayed empty after the tunnel left: the socket never started"
fi
listening || failed "the socket is up but nothing listens on the port"
passed "the tunnel gone, the socket holds the port within 20 s"

held() {
    for _ in $(seq 1 40); do
        case "$(hooks)" in "lampd on 127.0.0.1:$PORT"*) answers && return 0 ;; esac
        sleep 0.5
    done
    return 1
}
held || failed "lampd did not take the port the socket holds: $(hooks)"
passed "lampd started again with the port, and it answers"

# lampd restarted, as the watchdog, a crash or an install restart it: the port
# is systemd's and must still listen for the next lampd.
systemctl --user restart "$NAME.service" || failed "lampd did not restart"
listening && held || failed "the port went deaf when lampd restarted (listening: $(listening && echo yes || echo no); lampd: $(hooks))"
passed "restarted, lampd has the port again, and it answers"
