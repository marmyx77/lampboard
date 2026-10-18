#!/bin/bash
#
# The parity of the real Mac app with lampd's golden files, on its own: builds
# and runs `LampBoardE2E parity` on a port of its own.
#
# Scripts/test.sh runs the same suite inside the whole end-to-end run; this is
# the piece bite.sh attacks, because a full end-to-end run per mutation would
# take a quarter of an hour. It needs the Mac app, so anywhere else it says it
# cannot look.
#
# EXIT CODES
#   0  the app's lamps are the golden ones, through the sweeps
#   1  they are not, or it does not build
#   3  not a Mac: nothing was observed

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ "$(uname -s)" = "Darwin" ] || { echo "not a Mac: the app's parity cannot be run here"; exit 3; }
PORT="${LAMPBOARD_PARITY_PORT:-9891}"

swift build --product LampBoardE2E > /dev/null 2>&1 && swift build --product LampBoardApp > /dev/null 2>&1 \
    || { echo "it does not build"; exit 1; }
.build/debug/LampBoardE2E --port "$PORT" parity
