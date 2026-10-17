#!/bin/bash
#
# lampd under systemd --user, with the repository's unit: a loop that stops on
# purpose is killed and started again, and a stop with a phone attached is quick.
#
# WHY THIS EXISTS
# The failure this machine is known for is a service alive on an old state
# (~/AGENTS.md): a process that answers while its loop has stopped looking.
# `lampd` tells systemd it is alive from its main loop and nowhere else, and the
# unit gives it `WatchdogSec`. Measured in W0 (S-G v2): with the heartbeat on a
# thread of its own, a blocked loop was never restarted and only the age of the
# state gave it away. This makes that a red, with the unit as it is installed.
#
# It runs the static binary on this machine, in a transient user unit named
# `lampd-gate-<pid>` with the [Unit] and [Service] settings of
# deploy/lampd/lampd.service, and nothing of this machine's: a home of its own
# (LAMPBOARD_HOME), a tmux of its own (TMUX_TMPDIR), no port, no installed unit
# touched. The test hook that stops the loop (`LAMPD_TEST_HOOKS=1`) is set only
# here; the unit in the repository never sets it.
#
# EXIT CODES
#   0  the blocked loop was restarted within the watchdog, and the stop was quick
#   1  it was not, or lampd does not build
#   3  no systemd --user or no container engine here: nothing was observed
#
# USAGE
#   Scripts/test-lampd-watchdog.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

[ "$(uname -s)" = Linux ] || could_not_look "not Linux: the watchdog was not tried"
command -v systemd-run >/dev/null 2>&1 || could_not_look "no systemd-run here: the watchdog was not tried"
systemctl --user show-environment >/dev/null 2>&1 || could_not_look "no systemd --user manager answers: the watchdog was not tried"

CACHE="${LAMPBOARD_LAMPD_WATCHDOG_CACHE:-$HOME/.cache/lampboard/lampd-watchdog}"
mkdir -p "$CACHE/bin"
Scripts/lampd-build.sh --out "$CACHE/bin" > "$CACHE/build.log" 2>&1
case $? in
    0) ;;
    3) could_not_look "lampd could not be built here (see $CACHE/build.log)" ;;
    *) tail -5 "$CACHE/build.log" | sed 's/^/    /'; failed "lampd does not build static" ;;
esac

UNIT="lampd-gate-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lampd-gate.XXXXXX")"
cleanup() {
    systemctl --user stop "$UNIT" >/dev/null 2>&1
    systemctl --user reset-failed "$UNIT" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$WORK/home/.claude/sessions" "$WORK/tmux"
install -m 0755 "$CACHE/bin/lampd" "$WORK/lampd"

# The unit's own settings, read from the file the machine installs.
PROPERTIES=()
while IFS= read -r line; do
    case "$line" in
        Type=*|NotifyAccess=*|Restart=*|RestartSec=*|WatchdogSec=*|TimeoutStopSec=*|LimitCORE=*|MemoryHigh=*|MemoryMax=*|CPUQuota=*|Nice=*|StartLimitIntervalSec=*|StartLimitBurst=*)
            PROPERTIES+=(-p "$line") ;;
    esac
done < deploy/lampd/lampd.service
WATCHDOG="$(sed -n 's/^WatchdogSec=//p' deploy/lampd/lampd.service)"
RESTART="$(sed -n 's/^RestartSec=//p' deploy/lampd/lampd.service)"
[ -n "$WATCHDOG" ] || failed "deploy/lampd/lampd.service has no WatchdogSec"
grep -qx 'Type=notify' deploy/lampd/lampd.service || failed "deploy/lampd/lampd.service is not Type=notify"

ENVIRONMENT=(-E "LAMPBOARD_HOME=$WORK/home" -E "HOME=$WORK/home" -E "TMUX_TMPDIR=$WORK/tmux" -E LAMPD_TEST_HOOKS=1
             -E MIMALLOC_ARENA_EAGER_COMMIT=0 -E "PATH=/usr/local/bin:/usr/bin:/bin")
SOCKET="$WORK/home/.local/state/lampd/run/lampd/v1.sock"
lampd() { LAMPBOARD_HOME="$WORK/home" HOME="$WORK/home" TMUX_TMPDIR="$WORK/tmux" "$WORK/lampd" "$@"; }
show() { systemctl --user show "$UNIT" -p "$1" --value; }

echo "▸ Starting $UNIT with the settings of deploy/lampd/lampd.service (WatchdogSec=$WATCHDOG)"
systemd-run --user --unit "$UNIT" --collect "${PROPERTIES[@]}" "${ENVIRONMENT[@]}" "$WORK/lampd" serve > "$WORK/run.log" 2>&1 \
    || { sed 's/^/    /' "$WORK/run.log"; failed "the transient unit did not start"; }
[ "$(show ActiveState)" = active ] || failed "the unit is $(show ActiveState) after READY"
FIRST="$(show MainPID)"
lampd status > /dev/null || failed "lampd does not answer in its unit"

echo "▸ A loop stopped on purpose, the process alive"
: > "$WORK/home/.local/state/lampd/block-loop"
BLOCKED_AT="$(date +%s)"
LIMIT=$(( ${WATCHDOG%s} + 5 + ${RESTART%s} + 10 ))
AGES=""
RESTARTED=0
while [ $(( $(date +%s) - BLOCKED_AT )) -lt "$LIMIT" ]; do
    sleep 2
    PID="$(show MainPID)"
    if [ "$PID" != "$FIRST" ] && [ "$PID" != 0 ] && [ "$(show NRestarts)" -ge 1 ]; then RESTARTED=1; break; fi
    AGE="$(lampd status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stateAgeSeconds"))' 2>/dev/null)"
    [ -n "$AGE" ] && AGES="$AGES $AGE"
done
TOOK=$(( $(date +%s) - BLOCKED_AT ))
echo "    the state's age while blocked:$AGES"
if [ "$RESTARTED" != 1 ]; then
    failed "no restart within $LIMIT s of the loop stopping: the heartbeat does not come from the loop"
fi
echo "    restarted after $TOOK s (pid $FIRST → $(show MainPID), restarts $(show NRestarts))"
[ -e "$WORK/home/.local/state/lampd/block-loop" ] && failed "the block was not consumed"
python3 - "$AGES" <<'PY' || failed "the age in hello did not climb while the loop was stopped"
import sys
ages = [float(a) for a in sys.argv[1].split() if a not in ("None", "")]
sys.exit(0 if len(ages) >= 2 and ages[-1] > ages[0] else 1)
PY
for _ in $(seq 1 50); do lampd status > /dev/null 2>&1 && break; sleep 0.2; done
lampd status > /dev/null || failed "the restarted lampd does not answer"

echo "▸ A stop with a phone attached"
python3 - "$WORK/lampd" "$WORK/home" > "$WORK/client.log" 2>&1 <<'PY' &
import json, os, subprocess, sys
def frame(o):
    j = json.dumps(o).encode(); return str(len(j)).encode() + b" " + j + b"\n"
env = dict(os.environ, LAMPBOARD_HOME=sys.argv[2], HOME=sys.argv[2])
p = subprocess.Popen([sys.argv[1], "v1-stdio", "--device", "gate-phone"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
p.stdin.write(frame({"op": "hello", "protocol": 1, "client": "gate", "id": 1}) + frame({"op": "events", "id": 2, "ping": 1}))
p.stdin.flush()
out = p.stdout.read()
print("bye" if b'"type":"bye"' in out else "no bye")
PY
CLIENT=$!
sleep 2
STOP_START="$(date +%s%N)"
systemctl --user stop "$UNIT"
STOP_MS=$(( ($(date +%s%N) - STOP_START) / 1000000 ))
wait "$CLIENT"
echo "    stopped in $STOP_MS ms; the client: $(cat "$WORK/client.log")"
[ "$STOP_MS" -lt 3000 ] || failed "the stop took $STOP_MS ms with a phone attached: the connections do not close on SIGTERM"
grep -q '^bye$' "$WORK/client.log" || failed "the attached phone was not told bye"

printf '\033[32m✓\033[0m the watchdog restarts a stopped loop, and a stop with a phone attached is quick\n'
