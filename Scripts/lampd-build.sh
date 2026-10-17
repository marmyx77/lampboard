#!/bin/bash
#
# Builds `lampd` as one static Linux binary, in a container.
#
# WHY THIS EXISTS
# `lampd` runs on a Linux machine that has no Swift installed and must not get
# one (ADR-65 point 2 of the node's register): an update of the toolchain on the
# machine would be one more thing that moves under a running service. So it is
# built here, with the Static Linux SDK, in the same pinned `swift` image the
# Linux gates use, and what leaves the container is a binary that needs nothing
# but the kernel (S-G: 13.8 MB resident, no libswiftCore anywhere).
#
# The SDK is tied to the compiler's patch release: the image is pinned by digest
# and the SDK by its URL and checksum, together. When the image moves to a new
# patch, both lines change in the same commit.
#
# What it builds is the working tree, tracked files and new ones git does not
# ignore, copied to a cache folder outside the checkout (as Scripts/test-linux.sh
# does), so the checkout never gets a Linux `.build`.
#
# EXIT CODES
#   0  the binary is at the path printed last
#   1  it does not build
#   3  there is no container engine here: nothing was built
#
# USAGE
#   Scripts/lampd-build.sh [--out <dir>]     (default: ~/.cache/lampboard/lampd-build/out)
#
# ENVIRONMENT
#   LAMPBOARD_LAMPD_CACHE   where the copy, the build and the SDK live
#                           (default ~/.cache/lampboard/lampd-build)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# swift:6.4 (Swift 6.4.1), by digest, and the Static Linux SDK of that patch.
BASE="swift:6.4@sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f"
SDK_URL="https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
SDK_SUM="cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c"
SDK_BUNDLE="swift-6.4.1-RELEASE_static-linux-0.1.0"
SDK_ID="x86_64-swift-linux-musl"
CACHE="${LAMPBOARD_LAMPD_CACHE:-$HOME/.cache/lampboard/lampd-build}"
NAME="lampboard-lampd-build-$$"
LIMIT="${LAMPBOARD_LAMPD_LIMIT:-1800}"

OUT="$CACHE/out"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) echo "usage: Scripts/lampd-build.sh [--out <dir>]" >&2; exit 2 ;;
    esac
done

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || could_not_look "no docker here: lampd was not built"
docker info >/dev/null 2>&1 || could_not_look "docker is here but its daemon does not answer: lampd was not built"

mkdir -p "$CACHE" "$OUT"
LOCK="$CACHE/run.lock"
for _ in $(seq 1 240); do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
    kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null || { rm -rf "$LOCK"; continue; }
    sleep 5
done
[ "$(cat "$LOCK/pid" 2>/dev/null)" = $$ ] || failed "another build holds $LOCK and never let go"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$LOCK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

SRC="$CACHE/src"
rm -rf "$SRC"
mkdir -p "$SRC" "$CACHE/build" "$CACHE/home" "$CACHE/sdks"
git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - | tar -xf - -C "$SRC" \
    || failed "the working tree could not be copied to $SRC"
[ -f "$SRC/Package.resolved" ] || { [ -f "$CACHE/Package.resolved" ] && cp "$CACHE/Package.resolved" "$SRC/Package.resolved"; }

run() {
    docker run --rm --name "$NAME" --user "$(id -u):$(id -g)" -e HOME=/tmp/h --cpus 8 --memory 12g \
        -v "$SRC:/src" -v "$CACHE/build:/src/.build" -v "$CACHE/home:/tmp/h" -v "$CACHE/sdks:/sdks" -w /src \
        "$BASE" timeout -k 10 "$LIMIT" "$@"
}

if ! run swift sdk list --swift-sdks-path /sdks 2>/dev/null | grep -qx "$SDK_BUNDLE"; then
    echo "▸ Installing the Static Linux SDK (checksum $SDK_SUM)"
    run swift sdk install "$SDK_URL" --checksum "$SDK_SUM" --swift-sdks-path /sdks > "$CACHE/sdk.log" 2>&1 \
        || failed "the SDK could not be installed (see $CACHE/sdk.log)"
fi

echo "▸ Building lampd, static, for $SDK_ID"
if ! run bash -c "LAMPBOARD_STRICT=1 swift build -c release --product LampD --swift-sdks-path /sdks --swift-sdk $SDK_ID 2>&1" \
        > "$CACHE/build.log"; then
    sed 's/\x1b\[[0-9;]*m//g' "$CACHE/build.log" | grep -E '^/src/.*error:' | sort -u | head -20 | sed 's/^/    /'
    failed "lampd does not build static (the full log is $CACHE/build.log)"
fi
cp "$SRC/Package.resolved" "$CACHE/Package.resolved" 2>/dev/null

BIN="$CACHE/build/out/Products/Release-staticlinux-x86_64/LampD"
[ -f "$BIN" ] || BIN="$(find "$CACHE/build" -path '*release*' -name LampD -type f -perm -u+x 2>/dev/null | head -1)"
[ -n "$BIN" ] && [ -f "$BIN" ] || failed "the build said yes and left no binary"
run strip -o /src/.build/lampd.stripped "/src/.build/${BIN#"$CACHE/build/"}" || failed "the binary could not be stripped"
install -m 0755 "$CACHE/build/lampd.stripped" "$OUT/lampd" || failed "the binary could not be put in $OUT"
rm -f "$CACHE/build/lampd.stripped"

# Static, or it is not what the unit expects to run.
file "$OUT/lampd" 2>/dev/null | grep -q 'statically linked' || failed "$OUT/lampd is not statically linked"
printf '\033[32m✓\033[0m lampd %s, static, %s bytes, commit %s\n' \
    "$("$OUT/lampd" version 2>/dev/null | awk '{print $2}')" "$(stat -c %s "$OUT/lampd")" "$(git rev-parse --short HEAD)"
echo "$OUT/lampd"
