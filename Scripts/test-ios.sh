#!/bin/bash
#
# Builds the Core and NodeLink for iOS, for the simulator.
#
# WHY THIS EXISTS
# The iPhone and iPad app reuses the Core as it is: the models, the reducer, the
# transcript parsers, the remote scripts, the signed envelopes. Nothing on the
# Mac side would notice a Mac-only API reaching it — `Process`, AppKit, a home
# folder an iOS app does not have — until the app stopped building. This makes
# that a red in the Mac's own gate.
#
# NodeLink too (D175): the app's way into a machine, Citadel on swift-nio-ssh,
# which nothing else here builds for iOS. The Core first, on its own, so that a
# Core that does not build says so without waiting for the ssh stack.
#
# Only a build: the domain suite runs on the Mac and on Linux
# (Scripts/test-linux.sh), and what it proves does not change with the screen.
# Warnings are errors, as everywhere else in our own targets.
#
# EXIT CODES
#   0  the Core and NodeLink build for the iOS simulator
#   1  one of them does not
#   3  there is no Xcode with the iOS simulator SDK here: nothing was observed
#
# USAGE
#   Scripts/test-ios.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || could_not_look "no xcodebuild here: the Core was not built for iOS"
xcodebuild -showsdks 2>/dev/null | grep -q iphonesimulator \
    || could_not_look "no iOS simulator SDK in this Xcode: the Core was not built for iOS"

# Its own derived data, gone at the end: a build folder shared with anything
# else would be a cache this gate trusts without having made it.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The packages' clones are kept between runs: they are fetched at the revisions
# the manifest pins, and fetching them again proves nothing about our code.
PACKAGES="${LAMPBOARD_IOS_PACKAGES:-$HOME/.cache/lampboard/ios-packages}"
mkdir -p "$PACKAGES"

# Every wait is bounded: an xcodebuild that never returns is a gate that never ends.
build() {
    local scheme="$1" what="$2" status
    echo "▸ Building $what for the iOS simulator ($(xcodebuild -version | head -1))"
    LAMPBOARD_STRICT=1 perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 1500 \
        xcodebuild build -quiet -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$WORK/derived" -clonedSourcePackagesDirPath "$PACKAGES" > "$WORK/build.log" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        grep -E 'error:' "$WORK/build.log" | sort -u | head -20 | sed 's/^/    /'
        failed "$what does not build for iOS (xcodebuild exited $status)"
    fi
    printf '\033[32m✓\033[0m %s builds for the iOS simulator\n' "$what"
}

build LampBoardCore "the Core"
build LampBoardNodeLink "NodeLink"
