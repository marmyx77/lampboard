#!/bin/bash
# Takes the images the README shows, from the real app, against a fake home.
#
#     ./Scripts/make-screenshots.sh            # docs/images/*.png
#     ./Scripts/make-screenshots.sh --keep     # leave the fake home for poking at
#
# Why a script and not a person with ⌘⇧4. Three reasons, in order of how much
# they cost when ignored.
#
# **The names.** A screenshot of the panel on a working machine is a list of that
# person's projects. `Scripts/check-docs.sh` has a gate that refuses a real home
# directory anywhere in the tree, and it is right to: the picture at the top of a
# public README is the least private thing in a repository. Every row here is
# invented, and lives under a temporary `LAMPBOARD_HOME`.
#
# **The states.** A hand-taken shot shows whatever the machine happened to be
# doing. The panel has six states and three ring conditions, and the one worth
# photographing — six different colours at once — has never once happened by
# accident. The demo plays them, deliberately, from its script.
#
# **It works with the screen locked.** `screencapture -l <window>` asks the window
# server for that window's backing store, which is drawn whether or not anybody
# is looking. A full-screen capture on a locked Mac returns the lock screen; this
# returns the panel. Measured, because the opposite was assumed for a while.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/images"
APP="$ROOT/dist/LampBoard.app"
# The bundle's binary, or any build named by LAMPBOARD_BIN: on the test Mac the
# debug build, since bundling signs with a keychain that is not ours to use.
BIN="${LAMPBOARD_BIN:-$APP/Contents/MacOS/lampboard}"
PORT=9899                       # not 9877: never disturb the panel actually in use
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

[ -x "$BIN" ] || { echo "Build it first:  ./Scripts/build-app.sh  (or set LAMPBOARD_BIN)"; exit 1; }

HOME_DIR="$(mktemp -d /tmp/lampboard-shots.XXXXXX)"
mkdir -p "$OUT"

cleanup() {
    kill "${APP_PID:-0}" 2>/dev/null || true
    [ "$KEEP" = "1" ] && echo "  fake home kept at $HOME_DIR" || rm -rf "$HOME_DIR"
}
trap cleanup EXIT

# The sessions are the demo's script, `Sources/LampBoardCore/Demo/DemoScript.swift`:
# one place for demo data, checked by the tests to hold nothing real (D64). The
# trial sets the stage itself — an editor lock per project, a stand-in process per
# session, the transcripts and the Codex rollout — and plays the script into its
# own server twenty times faster, so the six states below are the reducer's own.
echo "▸ Starting the trial on port $PORT"
env LAMPBOARD_HOME="$HOME_DIR" "$BIN" --trial --trial-pace 20 --port "$PORT" --skip-setup-prompt &
APP_PID=$!
for _ in $(seq 1 40); do
    curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.25
done
# The last beat is at twenty seconds of script, one second here; the sweep that
# settles the rows comes every five.
sleep 7

# The panel is a borderless NSPanel belonging to an accessory app, so it is
# absent from `.optionOnScreenOnly` — the list most examples reach for. `.optionAll`
# finds it. Run through the Swift interpreter rather than compiled: there is
# nothing here worth a build product, and Command Line Tools is enough.
find_panel_window() {   # find_panel_window <pid>
    /usr/bin/env swift - "$1" <<'SWIFT'
import CoreGraphics
import Foundation

// **By pid, never by name.** The person running this almost certainly has their
// own panel open, full of their own project names, and matching on the owner's
// name would photograph that one instead — putting exactly the thing this script
// exists to avoid into a public README, silently, and looking right.
guard let wanted = CommandLine.arguments.dropFirst().first.flatMap(Int.init) else { exit(1) }

// A borderless NSPanel owned by an accessory app is absent from
// `.optionOnScreenOnly`, the list most examples reach for. `.optionAll` finds it.
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let all = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == wanted }
// The visible ones, when there are any: a text field leaves an off-screen window
// of its own behind, wider than the column, and a picture of it is a grey square.
let shown = all.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
let mine = shown.isEmpty ? all : shown

// The widest: the column itself, never a tooltip or the legend that may be up.
let widest = mine.max {
    let a = ($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
    let b = ($1[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
    return a < b
}
if let id = widest?[kCGWindowNumber as String] as? Int { print(id) }
SWIFT
}

echo "▸ Capturing"
WINDOW_ID="$(find_panel_window "$APP_PID" 2>/dev/null | tail -1)"
if [ -z "$WINDOW_ID" ]; then
    echo "  No window for pid $APP_PID. Did the panel start?"
    exit 1
fi
# Amber blinks, so a single frame catches it dark half the time — and a picture
# of the panel with its most important state switched off is worse than no
# picture. Six frames, keep the brightest: the one where everything that can be
# lit is lit. Without Pillow every frame measures zero and the first is kept:
# a picture that may catch amber dark, rather than none.
BEST=""; BEST_SUM=-1
for frame in $(seq 1 6); do
    screencapture -x -o -l "$WINDOW_ID" "$HOME_DIR/frame-$frame.png" 2>/dev/null || continue
    sum=$(/usr/bin/env python3 -c "
from PIL import Image, ImageStat
import sys
try: print(int(ImageStat.Stat(Image.open(sys.argv[1]).convert('L')).sum[0]))
except Exception: print(0)" "$HOME_DIR/frame-$frame.png" 2>/dev/null || echo 0)
    if [ "$sum" -gt "$BEST_SUM" ]; then BEST_SUM=$sum; BEST="$HOME_DIR/frame-$frame.png"; fi
    sleep 0.35
done
[ -n "$BEST" ] || { echo "  No frame captured."; exit 1; }
cp "$BEST" "$OUT/panel.png"
echo "  ✓ $OUT/panel.png  (brightest of six frames)"

echo
echo "The images are regenerated, never edited. If one looks wrong, the panel is"
echo "wrong: fix the panel and run this again."
