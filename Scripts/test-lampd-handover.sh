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
# It renders the two units from deploy/lampd/ under names of their own
# (`lampd-handover-<pid>`), on a free port of its own, into the user manager's
# runtime directory, and removes them at the end. The service behind the socket
# is a stand-in that says whether systemd passed it a port: what lampd does with
# the port is the lampd gate's. A listener stands for the Mac's tunnel and goes
# away; the port must then be the socket's, and the service must have been
# started again with it. Nothing installed on this machine is touched.
#
# EXIT CODES
#   0  the port went to the socket, and the service got it
#   1  it did not
#   3  no systemd --user here: nothing was observed
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
        -e "s|%h/.local/state/lampd/hooks-released|$WORK/hooks-released|g" "$1"
}
mkdir -p "$UNITS"
render deploy/lampd/lampd.socket > "$UNITS/$NAME.socket"
render deploy/lampd/lampd-socket-retry.service > "$UNITS/$NAME-retry.service"
render deploy/lampd/lampd-socket-retry.timer > "$UNITS/$NAME-retry.timer"
grep -q "$NAME.socket" "$UNITS/$NAME-retry.service" || failed "the retry unit no longer names lampd.socket: the rendering is stale"
# The stand-in for lampd: writes, at each start, how many ports systemd passed.
cat > "$UNITS/$NAME.service" <<EOF
[Service]
Type=simple
ExecStart=/usr/bin/python3 -c 'import os, time; open("$WORK/starts", "a").write(os.environ.get("LISTEN_FDS", "0") + "\\\\n"); time.sleep(3600)'
EOF
systemctl --user daemon-reload || failed "systemd did not read the units"

# The Mac's tunnel on the port, and lampd running in the shade.
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT)); s.listen(); time.sleep(3600)" &
HOLDER=$!
for _ in $(seq 1 50); do ss -Htln "sport = :$PORT" | grep -q . && break; sleep 0.1; done
systemctl --user start "$NAME.service" || failed "the stand-in did not start"
systemctl --user start "$NAME-retry.timer" || failed "the retry timer did not start"
sleep 5
systemctl --user is-active -q "$NAME.socket" && failed "the socket started while the port was the tunnel's"
passed "while the tunnel holds the port, the socket waits"

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
ss -Htln "sport = :$PORT" | grep -q . || failed "the socket is up but nothing listens on the port"
passed "the tunnel gone, the socket holds the port within 20 s"

got=0
for _ in $(seq 1 20); do
    tail -1 "$WORK/starts" 2>/dev/null | grep -qx 1 && { got=1; break; }
    sleep 0.5
done
[ "$got" = 1 ] || failed "the service was not started again with the port (starts: $(tr '\n' ' ' < "$WORK/starts" 2>/dev/null))"
passed "the service started again with the port passed to it"
