#!/bin/bash
#
# Builds the Core and runs the domain suite on Linux, in a container.
#
# WHY THIS EXISTS
# The Core is meant to run in three places: the Mac app, the iPhone and iPad
# app, and a small service on a Linux machine that keeps the lights of the
# sessions living there. The Mac gate cannot see the third. A Mac-only API
# reached for in passing — CoreFoundation's type ids, `Darwin.write`, a file
# descriptor flag — compiles there without a word, and the first anyone hears of
# it is a Linux build that no longer starts. This makes that a red the same day.
#
# It runs where there is a container engine, not on the test Mac: the official
# `swift` image, pinned by digest so that a new toolchain arrives as a commit and
# not as a surprise, plus the tools the suites call out to (python3, node, tmux,
# perl). The build happens with the network, to fetch swift-crypto, which only
# Linux links (the Mac and iOS have CryptoKit); the suite runs without it.
#
# What it builds is the working tree — tracked files and new ones git does not
# ignore — copied to a cache folder outside the checkout, so the checkout never
# gets a Linux `.build`, and `bite.sh` can attack it the way it attacks every
# other gate. The committed Package.resolved comes with it: the pins are the
# Mac's and Linux's alike (Scripts/check-pins.sh).
#
# EXIT CODES
#   0  the Core built and every suite passed
#   1  it does not build on Linux, or a suite failed
#   3  there is no container engine here: nothing was observed
#
# USAGE
#   Scripts/test-linux.sh              build, then every suite
#   Scripts/test-linux.sh <suite>…     build, then those suites
#
# ENVIRONMENT
#   LAMPBOARD_LINUX_CACHE      where the copy, the build and the package cache live
#                              (default ~/.cache/lampboard/linux-gate)
#   LAMPBOARD_LINUX_CONTAINER  the container's name (default lampboard-linux-gate-<pid>)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# swift:6.4 (Swift 6.4.1), by digest.
BASE="swift:6.4@sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f"
CACHE="${LAMPBOARD_LINUX_CACHE:-$HOME/.cache/lampboard/linux-gate}"
NAME="${LAMPBOARD_LINUX_CONTAINER:-lampboard-linux-gate-$$}"
# Seconds. The whole suite takes well under a minute; one that has not finished
# in ten is stuck on something, and a stuck run is a failure.
LIMIT="${LAMPBOARD_LINUX_LIMIT:-600}"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || could_not_look "no docker here: the Core was not built on Linux"
docker info >/dev/null 2>&1 || could_not_look "docker is here but its daemon does not answer: the Core was not built on Linux"

# One run at a time per cache: two would build into the same folder.
mkdir -p "$CACHE"
LOCK="$CACHE/run.lock"
for _ in $(seq 1 120); do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
    kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null || { rm -rf "$LOCK"; continue; }
    sleep 5
done
[ "$(cat "$LOCK/pid" 2>/dev/null)" = $$ ] || failed "another Linux run holds $LOCK and never let go"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$LOCK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# The image: the pinned toolchain plus what the suites run. Rebuilt only when
# this list changes, because docker keeps the layer.
IMAGE="lampboard-linux-gate:$(printf '%s' "$BASE python3 nodejs tmux perl procps jq" | shasum | cut -c1-12)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "▸ Preparing $IMAGE"
    docker build -q -t "$IMAGE" - > "$CACHE/image.log" 2>&1 <<EOF || could_not_look "the image could not be prepared (see $CACHE/image.log)"
FROM $BASE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        python3 nodejs tmux perl procps jq && rm -rf /var/lib/apt/lists/*
EOF
fi

# The working tree, as it is now. The build folder stays between runs, under a
# path that does not move, so a run after a one-line change rebuilds one file.
SRC="$CACHE/src"
rm -rf "$SRC"
mkdir -p "$SRC" "$CACHE/build" "$CACHE/home"
git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - | tar -xf - -C "$SRC" \
    || failed "the working tree could not be copied to $SRC"
# The committed pins decide; the cache only stands in for a tree without them.
[ -f "$SRC/Package.resolved" ] || { [ -f "$CACHE/Package.resolved" ] && cp "$CACHE/Package.resolved" "$SRC/Package.resolved"; }

run() {
    docker run --rm --name "$NAME" --user "$(id -u):$(id -g)" -e HOME=/tmp/h \
        --cpus 8 --memory 8g \
        -v "$SRC:/src" -v "$CACHE/build:/src/.build" -v "$CACHE/home:/tmp/h" -w /src \
        "$@"
}

echo "▸ Building on Linux ($(run "$IMAGE" swift --version 2>/dev/null | grep -o 'Swift version [0-9.]*' | head -1))"
# The network only for this step: swift-crypto comes from its repository.
if ! run "$IMAGE" bash -c 'LAMPBOARD_STRICT=1 swift build --product LampBoardTests 2>&1' > "$CACHE/build.log"; then
    # The compiler's own sentences, without its colours and without the
    # "command failed" lines the build system adds for each of them.
    sed 's/\x1b\[[0-9;]*m//g' "$CACHE/build.log" | grep -E '^/src/.*error:' | sort -u | head -20 | sed 's/^/    /'
    failed "the Core does not build on Linux (the full log is $CACHE/build.log)"
fi
cp "$SRC/Package.resolved" "$CACHE/Package.resolved" 2>/dev/null

# Every wait is bounded, and an exit the suite never gives is read as what it is.
verdict_of() {
    case "$1" in
        0) return 0 ;;
        124|137) failed "$2 was still running on Linux after $LIMIT seconds" ;;
        141) failed "$2 was ended by SIGPIPE on Linux: a write into a closed pipe killed the process" ;;
        *) failed "$2 failed on Linux (exit $1)" ;;
    esac
}

# Without a network, both runs: nothing in the suite has any business reaching
# outside.
if [ $# -eq 0 ]; then
    echo
    echo "▸ A write into a closed pipe, with nothing ignoring SIGPIPE"
    # The Mac turns that write into an error with `F_SETNOSIGPIPE`, a flag Linux
    # does not have; there `Command` ignores the signal itself. The one suite
    # that writes into a tool which never reads runs first, on its own and with
    # the default disposition, so that the run below, which ignores the signal
    # for every fixture, cannot hide a Core that stopped doing it (measured: 141).
    run --network none "$IMAGE" timeout -k 5 "$LIMIT" .build/debug/LampBoardTests "Running a tool" < /dev/null
    verdict_of $? "the suite \"Running a tool\""
fi

echo
echo "▸ Domain tests on Linux"
# SIGPIPE ignored, as a service on Linux runs: the fixtures that feed a tool
# through a pipe write the way the Mac's do, and on the Mac that write is
# allowed to fail.
ARGS=""
for a in "$@"; do ARGS="$ARGS $(printf '%q' "$a")"; done
run --network none "$IMAGE" bash -c "trap '' PIPE; timeout -k 5 $LIMIT .build/debug/LampBoardTests$ARGS < /dev/null"
verdict_of $? "the domain suite"
printf '\033[32m✓\033[0m the Core builds and its domain suite passes on Linux\n'
