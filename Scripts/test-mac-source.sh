#!/bin/bash
#
# The Mac as a source for the phone (W5 of the mobile plan): builds and runs
# MacSourceTests — the Mac's `v1` source, the ssh server inside the app, the
# pairing, the PTY bridge and the named actions, reached by a phone made of
# NodeLink over a real ssh on loopback.
#
# WHY THIS EXISTS
# The server is the only door into a person's Mac from the network that this
# project opens, and its rules (paired keys only, the read key reads, nothing
# runs while the switch is off, no command of the phone's own) are what make
# opening it acceptable. They are checked here against the server itself, not a
# description of it, and every one of them has a bite in Scripts/bite.sh.
#
# On a Mac it runs where it is. Elsewhere it runs in the pinned toolchain's
# container (the target has no AppKit), with tmux and python3, without a network.
#
# EXIT CODES
#   0  every case passed
#   1  something does not build, a case failed, or the suite crashed
#   3  neither a Mac nor a container engine: nothing was observed
#
# USAGE
#   Scripts/test-mac-source.sh [filter]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIMIT="${LAMPBOARD_MACSOURCE_LIMIT:-600}"
could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

# A suite that dies says nothing of its own: the status says it for it.
verdict() {
    case "$1" in
        0) printf '\033[32m✓\033[0m the Mac as a source: every case passed\n'; exit 0 ;;
        124|137) failed "MacSourceTests was still running after $LIMIT seconds" ;;
        *) if [ "$1" -gt 128 ]; then failed "MacSourceTests crashed (signal $(($1 - 128)))"; fi
           failed "MacSourceTests failed (exit $1)" ;;
    esac
}

if [ "$(uname -s)" = Darwin ]; then
    LAMPBOARD_STRICT=1 swift build --product MacSourceTests > /tmp/lampboard-macsource-build.$$ 2>&1 || {
        grep -E 'error:' /tmp/lampboard-macsource-build.$$ | sort -u | head -20 | sed 's/^/    /'
        rm -f /tmp/lampboard-macsource-build.$$
        failed "MacSourceTests does not build"
    }
    rm -f /tmp/lampboard-macsource-build.$$
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$LIMIT" .build/debug/MacSourceTests "$@"
    verdict $?
fi

command -v docker >/dev/null 2>&1 || could_not_look "neither a Mac nor docker here: the Mac's server was not tried"
docker info >/dev/null 2>&1 || could_not_look "docker is here but its daemon does not answer: the Mac's server was not tried"

# The same toolchain and image as Scripts/test-nodelink.sh: tmux, python3, ssh.
BASE="swift:6.4@sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f"
IMAGE="lampboard-nodelink-gate:$(printf '%s' "$BASE openssh-server openssh-client python3 procps tmux" | shasum | cut -c1-12)"
CACHE="${LAMPBOARD_MACSOURCE_CACHE:-$HOME/.cache/lampboard/macsource-gate}"
NAME="lampboard-macsource-$$"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    mkdir -p "$CACHE"
    docker build -q -t "$IMAGE" - > "$CACHE/image.log" 2>&1 <<EOF || could_not_look "the image could not be prepared (see $CACHE/image.log)"
FROM $BASE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        openssh-server openssh-client python3 procps tmux && rm -rf /var/lib/apt/lists/*
EOF
fi

mkdir -p "$CACHE"
LOCK="$CACHE/run.lock"
for _ in $(seq 1 120); do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
    kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null || { rm -rf "$LOCK"; continue; }
    sleep 5
done
[ "$(cat "$LOCK/pid" 2>/dev/null)" = $$ ] || failed "another run holds $LOCK and never let go"
trap 'docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$LOCK"' EXIT
trap 'exit 130' INT TERM

SRC="$CACHE/src"
rm -rf "$SRC"
mkdir -p "$SRC" "$CACHE/build" "$CACHE/home"
git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - | tar -xf - -C "$SRC" \
    || failed "the working tree could not be copied to $SRC"

run() {
    docker run --rm --name "$NAME" --user "$(id -u):$(id -g)" -e HOME=/tmp/h --cpus 8 --memory 8g \
        -v "$SRC:/src" -v "$CACHE/build:/src/.build" -v "$CACHE/home:/tmp/h" -w /src "$@"
}

# The network only for the build: the packages come from their repositories.
if ! run "$IMAGE" bash -c 'LAMPBOARD_STRICT=1 swift build --product MacSourceTests 2>&1' > "$CACHE/build.log"; then
    sed 's/\x1b\[[0-9;]*m//g' "$CACHE/build.log" | grep -E '^/src/.*error:' | sort -u | head -20 | sed 's/^/    /'
    failed "MacSourceTests does not build on Linux (the full log is $CACHE/build.log)"
fi
ARGS=""
for a in "$@"; do ARGS="$ARGS $(printf '%q' "$a")"; done
run --network none "$IMAGE" bash -c "timeout -k 5 $LIMIT .build/debug/MacSourceTests$ARGS < /dev/null"
verdict $?
