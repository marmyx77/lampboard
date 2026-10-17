#!/bin/bash
#
# lampd's contract timer (E5, Q22 of the mobile plan; ADR-65 point 11): checks
# the contract of Claude Code's events and files on this machine when the
# version of Claude Code changed since the last check, and leaves the outcome
# in ~/.local/state/lampd/contract.json for `lampd status`, `lampd doctor` and
# the Quadro.
#
# Installed by Scripts/lampd-install.sh beside a copy of check-contract.sh and
# the Contracts folder, in ~/.local/lib/lampd/contract/. Claude Code is never
# run to learn its version: the native installer's folder names it. The live
# probe (real `claude -p` sessions, a small model) runs only when
# ~/.config/lampd/config.json says "contractLive": true.
#
#   lampd-contract.sh            check if the version changed
#   lampd-contract.sh --force    check whatever the version

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${LAMPBOARD_HOME:-$HOME}"
STATE="$HOME_DIR/.local/state/lampd"
STAMP="$STATE/contract.json"
CONFIG="$HOME_DIR/.config/lampd/config.json"
mkdir -p "$STATE"

RESOLVED="$(readlink -f "$(command -v claude 2>/dev/null)" 2>/dev/null || true)"
case "$RESOLVED" in
    */claude/versions/*) VERSION="$(basename "$RESOLVED")" ;;
    *) VERSION="" ;;
esac

LAST="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("claudeVersion", ""))
except Exception: print("")' "$STAMP")"
if [ "${1:-}" != "--force" ] && [ -n "$VERSION" ] && [ "$VERSION" = "$LAST" ]; then
    echo "lampd-contract: Claude Code $VERSION was already checked"
    exit 0
fi

LIVE=0
python3 -c 'import json,sys
try: sys.exit(0 if json.load(open(sys.argv[1])).get("contractLive") is True else 1)
except Exception: sys.exit(1)' "$CONFIG" && LIVE=1

ARGS=(--node)
[ "$LIVE" = 1 ] && ARGS+=(--live)
"$HERE/Scripts/check-contract.sh" "${ARGS[@]}" > "$STATE/contract.log" 2>&1
STATUS=$?
case "$STATUS" in
    0) OUTCOME=pass ;;
    1) OUTCOME=fail ;;
    *) OUTCOME=cannot-check ;;
esac
[ -n "$VERSION" ] || OUTCOME=cannot-check

python3 - "$STAMP" "$VERSION" "$OUTCOME" "$LIVE" <<'PY'
import datetime, json, os, sys
path, version, outcome, live = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
stamp = {"claudeVersion": version or "unknown", "outcome": outcome, "live": live,
         "checkedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
temporary = path + ".tmp"
with open(temporary, "w") as handle:
    json.dump(stamp, handle)
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
echo "lampd-contract: Claude Code ${VERSION:-unknown}: $OUTCOME (exit $STATUS, the report is $STATE/contract.log)"
exit 0
