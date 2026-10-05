#!/bin/bash
#
# Runs both suites.
#
# There are two because they cover different things: the first verifies pure
# functions and is instantaneous, the second launches the real binary and talks
# to it over HTTP. The second one is needed because this project's worst defects
# all hid in the seams, where domain tests don't reach.
#
# Neither of them touches ~/.claude, the preferences or the system permissions:
# the end-to-end run uses a temporary home that it deletes at the end.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A dedicated port: never the default one, or a test session would collide with
# the panel you have open.
PORT="${LAMPBOARD_TEST_PORT:-9899}"

# Warnings as errors, the same way CI does it: a warning that only appears on a
# build machine is a warning that gets discovered by whoever is trying to ship.
echo "▸ Building…"
swift build -Xswiftc -warnings-as-errors

echo
echo "▸ Domain tests"
# The built binary, not `swift run`. The build happened two lines above, so
# `swift run` would re-enter the package manager only to exec something that is
# already on disk — and on 2026-08-29 that re-entry died with SIGSEGV inside
# llbuild while other builds were running, reporting a red that had nothing to do
# with this project. The suite itself ran clean three times immediately after,
# and the crash report named `swift-package`, not `LampBoardTests`.
#
# The end-to-end line below always did it this way. Now both do.
.build/debug/LampBoardTests "$@"

echo
echo "▸ End-to-end tests (port $PORT)"
.build/debug/LampBoardE2E --port "$PORT" "$@"

# The companion mod as Claude Code reads it: a module that breaks one of its rules
# is dropped whole, silently, from every session.
echo
echo "▸ The mod"
"$ROOT/Scripts/check-mod.sh"

# Third, because documentation that states figures is documentation that can be
# wrong, and nothing else in this repository would ever notice. Twenty-one of the
# forty-seven figures in the code map had drifted before this ran for the first
# time. Cheap, offline, and it has no opinion about the prose.
echo
echo "▸ Documentation"
"$ROOT/Scripts/check-docs.sh"

# Fourth, and last because it is the one that judges the other three: every gate
# above is made to fail on purpose. A check nobody has ever seen fail is a check
# that has never been distinguished from a broken one — and one of them was
# broken, silently, for weeks.
echo
echo "▸ The gates bite"
"$ROOT/Scripts/bite.sh"
