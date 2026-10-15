#!/bin/bash
#
# Says that every package the build reaches is pinned in the committed
# Package.resolved, at the version the build uses.
#
# WHY THIS EXISTS
# Until NodeLink (D175) the package had no dependencies, and Package.resolved was
# ignored as a build product. Now it reaches ten packages: Citadel and its fork
# of swift-nio-ssh pinned to commits, swift-nio to a version — and, under them,
# BigInt, swift-asn1, swift-atomics, swift-collections, swift-log, swift-system
# and swift-crypto, pinned by nothing. Every fresh clone, every new test Mac,
# every cold cache took whatever was newest that day, for the ssh stack of the
# phone. The commits pinned in the manifest were read once (S-C, S-R); what
# sits under them must not move without a commit either.
#
# SwiftPM does not say when a pin is missing: measured on Swift 6.4, a
# Package.resolved with one package removed resolves, builds, and is left as it
# was, even with `--only-use-versions-from-resolved-file`. So this asks SwiftPM
# for the graph it builds and compares it with the file as committed, before
# SwiftPM has a chance to touch it.
#
# EXIT CODES
#   0  every package in the graph is pinned, at the version the graph uses
#   1  one is not, the file is not committed, or the build moved it
#   3  there is no swift here: nothing was observed
#
# USAGE
#   Scripts/check-pins.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

command -v swift >/dev/null 2>&1 || could_not_look "no swift here: the pins were not compared with the graph"
git ls-files --error-unmatch Package.resolved >/dev/null 2>&1 \
    || failed "Package.resolved is not committed: nothing pins what the build fetches"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Read before SwiftPM runs: what is judged is the file as it was given.
cp Package.resolved "$WORK/pins.json"
perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 300 swift package show-dependencies --format json \
    > "$WORK/graph.json" 2> "$WORK/graph.err" \
    || { sed 's/^/    /' "$WORK/graph.err" | tail -5; failed "the dependency graph could not be read"; }

python3 - "$WORK/pins.json" "$WORK/graph.json" <<'PY'
import json, sys

pins = {p["identity"]: p["state"] for p in json.load(open(sys.argv[1])).get("pins", [])}
graph = {}
def walk(node):
    for child in node.get("dependencies", []):
        graph[child["identity"]] = child.get("version", "")
        walk(child)
walk(json.load(open(sys.argv[2])))

if not graph:
    print("    the graph has no packages — this check would pass on anything", file=sys.stderr)
    sys.exit(1)

problems = []
for identity, version in sorted(graph.items()):
    state = pins.get(identity)
    if state is None:
        problems.append(f"{identity} is in the build with no pin")
    elif state.get("version") and version not in ("", "unspecified") and state["version"] != version:
        problems.append(f"{identity} is pinned at {state['version']}, the build uses {version}")
for extra in sorted(set(pins) - set(graph)):
    problems.append(f"{extra} is pinned and no longer in the build")

print(f"    {len(graph)} packages in the build, {len(pins)} pinned", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
[ $? -eq 0 ] || failed "Package.resolved does not pin the build"
cmp -s Package.resolved "$WORK/pins.json" \
    || { cp "$WORK/pins.json" Package.resolved; failed "reading the graph rewrote Package.resolved (put back as it was)"; }
# Last, because a pin changed on purpose is judged above first: whatever the
# build uses has to be what was committed, or the gate tested something else.
git diff --quiet -- Package.resolved \
    || failed "Package.resolved differs from the commit: the build moved a pin, or one was changed and not committed"
printf '\033[32m✓\033[0m every package the build reaches is pinned\n'
