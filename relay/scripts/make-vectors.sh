#!/bin/bash
#
# Regenerates relay/test/vectors/core-vectors.json from the Core.
#
# The relay's tests check the relay against what the Core really sends:
# envelopes sealed by PushEnvelope, requests built and checked by
# RelayPushRequest, the wire as V1Codec writes it. This runs the Core's code
# (relay/vectors) on Linux, in the same pinned swift:6.4 image as
# Scripts/test-linux.sh, and writes its output where the tests read it.
#
# EXIT CODES
#   0  the vectors were written
#   1  the generator did not build or did not run
#   3  there is no container engine here: nothing was generated
#
# ENVIRONMENT
#   LAMPBOARD_VECTORS_CACHE  where the copy and the build live
#                            (default ~/.cache/lampboard/relay-vectors)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASE="swift:6.4@sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f"
CACHE="${LAMPBOARD_VECTORS_CACHE:-$HOME/.cache/lampboard/relay-vectors}"
OUT="$ROOT/relay/test/vectors/core-vectors.json"

command -v docker >/dev/null 2>&1 || { echo "no docker here: no vectors" >&2; exit 3; }
docker info >/dev/null 2>&1 || { echo "docker does not answer: no vectors" >&2; exit 3; }

SRC="$CACHE/src"
rm -rf "$SRC"
mkdir -p "$SRC" "$CACHE/build" "$CACHE/home"
git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - | tar -xf - -C "$SRC" || { echo "the tree could not be copied" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
if ! docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/h --cpus 8 --memory 8g \
        -v "$SRC:/src" -v "$CACHE/build:/src/relay/vectors/.build" -v "$CACHE/home:/tmp/h" \
        -w /src/relay/vectors "$BASE" \
        bash -c 'swift build -c debug >/tmp/h/build.log 2>&1 || { tail -30 /tmp/h/build.log >&2; exit 1; }; .build/debug/RelayVectors' \
        > "$TMP"; then
    echo "the generator failed" >&2
    exit 1
fi
mv "$TMP" "$OUT"
trap - EXIT
echo "wrote $OUT"
