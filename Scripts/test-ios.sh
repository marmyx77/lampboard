#!/bin/bash
#
# Builds the Core for iOS, for the simulator.
#
# WHY THIS EXISTS
# The iPhone and iPad app reuses the Core as it is: the models, the reducer, the
# transcript parsers, the remote scripts, the signed envelopes. Nothing on the
# Mac side would notice a Mac-only API reaching it — `Process`, AppKit, a home
# folder an iOS app does not have — until the app stopped building. This makes
# that a red in the Mac's own gate.
#
# Only the Core, and only a build: the domain suite runs on the Mac and on Linux
# (Scripts/test-linux.sh), and what it proves does not change with the screen.
# Warnings are errors, as everywhere else in our own targets.
#
# EXIT CODES
#   0  the Core builds for the iOS simulator
#   1  it does not
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

echo "▸ Building the Core for the iOS simulator ($(xcodebuild -version | head -1))"
# Every wait is bounded: an xcodebuild that never returns is a gate that never ends.
LAMPBOARD_STRICT=1 perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 900 \
    xcodebuild build -quiet -scheme LampBoardCore -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$WORK/derived" > "$WORK/build.log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
    grep -E 'error:' "$WORK/build.log" | sort -u | head -20 | sed 's/^/    /'
    failed "the Core does not build for iOS (xcodebuild exited $status)"
fi
printf '\033[32m✓\033[0m the Core builds for the iOS simulator\n'
