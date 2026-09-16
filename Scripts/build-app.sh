#!/bin/bash
#
# Builds LampBoard.app from the SwiftPM executable.
#
# The bundle isn't an affectation: macOS grants the Accessibility and Automation
# permissions to a bundle identity, not to a bare binary. Without a signed .app
# the user would have to re-authorize the app on every rebuild.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_NAME="LampBoard"
BUNDLE_ID="com.lampboard.app"
# The version comes from the release script when there is one, so a disk
# image cannot carry a number no tag ever had.
VERSION="${LAMPBOARD_VERSION:-0.1.0}"

BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP_DIR="$ROOT/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "▸ Building ($CONFIGURATION)…"
cd "$ROOT"
swift build -c "$CONFIGURATION" --product LampBoardApp

echo "▸ Assembling the bundle…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/LampBoardApp" "$MACOS_DIR/lampboard"

# The icon is committed, not generated here: a build should not depend on
# Python being present. Scripts/make-icon.py redraws it when the design changes.
# Keeps Spotlight out of the build directory.
#
# `.build` is around 700 MB and every object in it is rewritten on each build.
# Indexed, that is a background process re-reading hundreds of megabytes each
# time somebody compiles, and the cost lands as disk queue rather than CPU:
# the load average climbs while the processor looks idle, and the compositor
# starts missing frames. Measured on this machine at a load average of 87 on
# eight cores, with the processor at 40 per cent.
#
# One empty file, and Spotlight skips the whole tree.
touch "$ROOT/.build/.metadata_never_index" 2>/dev/null || true

ICON="$ROOT/Resources/$APP_NAME.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$RESOURCES_DIR/$APP_NAME.icns"
else
    echo "  ⚠ Resources/$APP_NAME.icns is missing: the bundle gets the generic icon."
    echo "     Rebuild it with: python3 Scripts/make-icon.py"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>lampboard</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>

    <!-- The two keys nothing here reads and a fleet manager might.
         An MDM tracks the installed version through CFBundleShortVersionString,
         falls back to CFBundleVersion, and falls back again to
         CFBundleInfoDictionaryVersion; the first two are above and the third was
         simply absent, because this plist is written by hand rather than by
         Xcode, which puts both of these in every bundle it produces. They cost
         nothing and they remove a question — is this bundle missing something? —
         that is expensive to answer from the other side of a deployment. -->
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>

    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>

    <!-- No Dock icon: it's a widget, not an application you keep open. -->
    <key>LSUIElement</key>
    <true/>

    <!-- Required to drive System Events and bring the VS Code window to the
         front. Without this key macOS blocks the AppleScript. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>lampboard uses the microphone only while you hold the dictation button, to turn what you say into the message you are writing. Nothing is recorded and nothing leaves the Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>lampboard transcribes your dictation on this Mac, using the on-device speech model. No audio is sent anywhere.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>lampboard uses system events to bring the Visual Studio Code window matching the traffic light you clicked to the front.</string>

    <key>NSHumanReadableCopyright</key>
    <string>lampboard</string>
</dict>
</plist>
PLIST

# If a stable signing identity exists, use it: the TCC authorizations survive
# rebuilds, because the requirement hooks onto the identity and not onto the
# binary's hash. Otherwise fall back to the ad-hoc signature, which invalidates
# the permissions on every build (see Scripts/create-signing-identity.sh).
#
# Asked of the keychain rather than spelled here, and that is not tidiness. The
# name was written in once, the project was renamed, and this line went on
# looking for a certificate that no longer existed: every build after the rename
# fell back to ad-hoc while saying so in one line nobody was reading, and the
# installed copy stayed on the last signature that had been real.
#
# The Developer ID comes first when it is there, because it is the identity the
# authorizations already belong to.
SIGNING_IDENTITY=""
for candidate in \
    "$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)" \
    "$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\([^"]*Local Signing\)".*/\1/p' | head -1)"
do
    if [ -n "$candidate" ]; then SIGNING_IDENTITY="$candidate"; break; fi
done

SIGNED_STABLY=0

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "▸ Signing with the stable identity “${SIGNING_IDENTITY}”…"

    # The signing has to be attempted with a deadline. If the private key isn't
    # authorized for codesign, the command doesn't fail: it hangs waiting for a
    # macOS dialog. A build that never returns is worse than a build that falls
    # back, because it says nothing.
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR" \
        >/dev/null 2>&1 &
    SIGN_PID=$!

    for _ in $(seq 1 20); do
        kill -0 "$SIGN_PID" 2>/dev/null || break
        sleep 1
    done

    if kill -0 "$SIGN_PID" 2>/dev/null; then
        kill "$SIGN_PID" 2>/dev/null || true
        echo "  ⏳ codesign was left waiting on a dialog: falling back to ad-hoc."
        echo "     Look for the macOS window asking for access to the key and"
        echo "     press “Always Allow”, then rebuild."
    elif wait "$SIGN_PID"; then
        SIGNED_STABLY=1
    else
        echo "  ✗ Signing with the stable identity failed: falling back to ad-hoc."
    fi
fi

if [ "$SIGNED_STABLY" = "0" ]; then
    echo "▸ Ad-hoc signing…"
    codesign --force --sign - --timestamp=none "$APP_DIR" 2>/dev/null
fi

echo
echo "✓ $APP_DIR"
echo
echo "  Launch:         open '$APP_DIR'"
echo "  From terminal:  '$MACOS_DIR/lampboard' help"
echo
if [ "$SIGNED_STABLY" = "1" ]; then
    echo "  Stable signature: the Accessibility and Automation authorizations"
    echo "  survive this rebuild and the next ones."
else
    echo "  MIND THE PERMISSIONS: the ad-hoc signature changes on every build, so macOS"
    echo "  treats this as a different app from the one you already authorized."
    echo "  If clicking the traffic lights stops raising the right window:"
    echo
    echo "    System Settings › Privacy & Security › Accessibility"
    echo "      → select lampboard, press '−', then add it back from dist/"
    echo "    System Settings › Privacy & Security › Automation"
    echo "      → lampboard → System Events"
    echo
    echo "  To never do this again:  ./Scripts/create-signing-identity.sh"
fi
echo
echo "  Remember to restart the app: a new bundle does not replace the process"
echo "  that is already running."
echo "    pkill -x lampboard; sleep 1; open '$APP_DIR'"

# The trap this exists for cost a whole night's work. There are two copies of
# this app on a machine that has ever installed one — the build in dist/ and the
# one in /Applications — and only the second is what a login item starts in the
# morning. A fix built, tested and verified in dist/ was reported as "nothing has
# changed", because the app answering on the port was the older copy.
#
# So the script says it, every time, rather than leaving it to be remembered.
INSTALLED="/Applications/LampBoard.app"
if [ -d "$INSTALLED" ]; then
    echo
    if [ "$MACOS_DIR/lampboard" -nt "$INSTALLED/Contents/MacOS/lampboard" ]; then
        echo "  ⚠ THE INSTALLED COPY IS OLDER THAN THIS BUILD."
        echo "    $INSTALLED is what starts at login, so testing dist/ proves"
        echo "    nothing about what you will be running tomorrow. To update it:"
        echo
        echo "      pkill -x lampboard; sleep 1"
        echo "      rm -rf '$INSTALLED' && cp -R '$APP_DIR' /Applications/"
        echo "      open '$INSTALLED'"
    else
        echo "  The copy in /Applications is not older than this build."
    fi
fi
echo
echo "  Check:  '$MACOS_DIR/lampboard' status"
