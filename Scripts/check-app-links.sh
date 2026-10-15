#!/bin/bash
#
# Says what the Mac app links, as the manifest reads on a Mac, and fails if it
# links anything from another package.
#
# WHY THIS EXISTS
# The package now declares an ssh stack — Citadel, a fork of swift-nio-ssh,
# swift-nio, swift-crypto — for NodeLink and its checks (D175). SwiftPM builds a
# target with what that target names and what those name in turn, so the Mac
# app is untouched as long as nothing on its path names one of them. One line
# is all it would take — `LampBoardCore` reaching for NodeLink, the app naming
# it for a convenience — and the app would carry a third party's ssh stack into
# every Mac, without a test anywhere going red. This makes that line red.
#
# It reads `swift package dump-package`, walks the app's dependencies through
# the package's own targets, and wants no product of another package on the
# way. The vendored SwiftTerm and Clarc are targets of this package (D129) and
# count as ours.
#
# EXIT CODES
#   0  the Mac app links nothing from another package
#   1  it does, or the manifest could not be read
#   3  not on a Mac: the manifest reads differently elsewhere, nothing was observed
#
# USAGE
#   Scripts/check-app-links.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

[ "$(uname -s)" = Darwin ] || could_not_look "not a Mac: what the Mac app links was not read"

MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 300 swift package dump-package > "$MANIFEST" 2> "$MANIFEST.err" \
    || { sed 's/^/    /' "$MANIFEST.err" | tail -5; rm -f "$MANIFEST.err"; failed "the manifest could not be read"; }
rm -f "$MANIFEST.err"

python3 - "$MANIFEST" <<'PY'
import json, sys

manifest = json.load(open(sys.argv[1]))
targets = {t["name"]: t for t in manifest["targets"]}
APP = "LampBoardApp"
if APP not in targets:
    print(f"    no target {APP} in the manifest: this check is looking at the wrong thing", file=sys.stderr)
    sys.exit(1)

def edges(target):
    for dep in target.get("dependencies", []):
        kind, value = next(iter(dep.items()))
        name = value[0]
        if kind == "product":
            yield ("product", f"{name} (package {value[1]})")
        elif name in targets:
            yield ("target", name)
        else:
            # byName naming something that is not one of ours is a product.
            yield ("product", name)

seen, foreign, stack = set(), [], [(APP, [APP])]
while stack:
    name, path = stack.pop()
    if name in seen:
        continue
    seen.add(name)
    for kind, other in edges(targets[name]):
        if kind == "product":
            foreign.append(" → ".join(path + [other]))
        else:
            stack.append((other, path + [other]))

print(f"    {APP} reaches {len(seen) - 1} targets of this package: {', '.join(sorted(seen - {APP}))}", file=sys.stderr)
for line in foreign:
    print(f"    links another package's product: {line}", file=sys.stderr)
sys.exit(1 if foreign else 0)
PY
status=$?
[ "$status" -eq 0 ] || failed "the Mac app links a product of another package"
printf '\033[32m✓\033[0m the Mac app links nothing from another package\n'
