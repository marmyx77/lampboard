#!/bin/bash
#
# Every route of the Mac's hooks' port has an owner in lampd's table (W5, §2.3
# of the mobile plan, §6.2 «Ogni rotta ha un padrone»).
#
# WHY THIS EXISTS
# Once lampd holds a node's hooks' port, a route the Mac learns and lampd does
# not know is refused on that node: a feature that works on the Mac's own
# sessions and silently not on the node's. The list of routes is read here from
# the code that serves them — every `case AppConfig.<name>Path` the Mac's
# SignalServer switches on, every path the companion mod's hooks call — and
# compared with `lampd routes`, the table lampd answers with. A route without a
# row is red until it gets one (R1).
#
# USAGE
#   Scripts/check-lampd-routes.sh <lampd routes JSON file>
#                       the table as `lampd routes` printed it (test-lampd.sh
#                       passes the one the built binary prints)
#
# EXIT CODES
#   0  every route has an owner
#   1  a route has none, or the table cannot be read

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${1:?usage: Scripts/check-lampd-routes.sh <lampd routes JSON>}"

python3 - "$ROOT" "$TABLE" <<'PY'
import glob, json, re, sys
root, table_path = sys.argv[1], sys.argv[2]
config = open(f"{root}/Sources/LampBoardCore/Config/AppConfig.swift").read()
paths = dict(re.findall(r'public static let (\w+Path) = "(/[^"]*)"', config))
server = open(f"{root}/Sources/LampBoardApp/Server/SignalServer.swift").read()
start = server.index("private func handle(_ request: HTTPRequest) -> Data {")
switch = server[start:server.index("\n    }\n", start)]
needed = {}
for name in re.findall(r"AppConfig\.(\w+Path)", switch):
    if name not in paths:
        print(f"    SignalServer names AppConfig.{name}, which AppConfig does not define")
        sys.exit(1)
    needed[paths[name]] = f"SignalServer (AppConfig.{name})"
for hook in glob.glob(f"{root}/mod/hooks/*.js"):
    text = open(hook).read()
    for path in re.findall(r"\$\{[^}]*(?:base|port)[^}]*\}(/[a-z][a-z/_-]*)", text):
        needed.setdefault(path, f"mod/hooks/{hook.rsplit('/', 1)[1]}")
    for path in re.findall(r"['\"`](/mod(?:/[a-z_-]+)*)['\"`]", text):
        needed.setdefault(path, f"mod/hooks/{hook.rsplit('/', 1)[1]}")
try:
    table = {row["path"]: row["owner"] for row in json.load(open(table_path))}
except Exception as error:
    print(f"    lampd's table could not be read: {error}")
    sys.exit(1)
missing = sorted(p for p in needed if p not in table)
print(f"    {len(needed)} routes the Mac serves or the mod calls, {len(table)} rows in lampd's table")
for path in missing:
    print(f"    {path} ({needed[path]}) has no row in lampd's table")
sys.exit(1 if missing else 0)
PY
status=$?
if [ "$status" = 0 ]; then
    printf '\033[32m✓\033[0m every route of the hooks'"'"' port has an owner in lampd\n'
else
    printf '\033[31m✗\033[0m a route of the hooks'"'"' port has no owner in lampd\n'
fi
exit "$status"
