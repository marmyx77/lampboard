#!/bin/bash
#
# Builds the disk image you hand to somebody else.
#
# The script has three honest outcomes and never pretends to have reached a
# better one than it did:
#
#   no certificate      → a disk image that Gatekeeper refuses, useful only to
#                         a tester who knows how to answer it
#   Developer ID        → a signed disk image, still refused on a Mac that has
#                         never seen it: notarization is what lifts that
#   Developer ID + key  → signed, notarized, stapled: it opens with a double
#                         click on a Mac that has never heard of us
#
# Both secrets come from the environment, because this file is public:
#
#   export LAMPBOARD_SIGNING_IDENTITY='Developer ID Application: … (TEAMID)'
#   export LAMPBOARD_NOTARY_PROFILE='lampboard'
#
# The notarization profile is created once, and lives in the keychain:
#
#   xcrun notarytool store-credentials lampboard \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
# An app-specific password is made at appleid.apple.com in two minutes and is
# enough; an App Store Connect API key (--key/--key-id/--issuer) works too and
# is the one to use from a machine nobody logs into.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LampBoard"

# The bundle that gets released is a copy, never the one in dist/. A Developer
# ID signature is a different identity from the local one, and macOS grants
# Accessibility and Automation to an identity: signing dist/ in place would
# silently revoke the permissions of the app you are running right now.
BUILT="$ROOT/dist/$APP_NAME.app"
APP_DIR="$ROOT/.build/release-app/$APP_NAME.app"

# Two modes, and the difference is what may be published.
#
#   ./Scripts/release.sh                 the real thing, and it is fail-closed
#   ./Scripts/release.sh --dry-run 0.2.0 a rehearsal, and it says so on the tin
#
# The number used to come from `git describe --tags --abbrev=0`, which answers
# with the **nearest** tag rather than a tag on HEAD. Measured on this
# repository: HEAD was 62 commits past `v0.1.0`, so the documented command would
# have built new code as `LampBoard-0.1.0.dmg` — a name already published, and
# published under the project's previous name at that. A third audit found it
# before anybody ran it.
#
# So in the real mode the version is not derived, guessed or defaulted. It comes
# from a tag that points at HEAD, or the script stops.
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi
VERSION="${1:-}"

if [ "$DRY_RUN" = "0" ]; then
    if [ -n "$VERSION" ]; then
        echo "A version cannot be handed to a real release: it comes from the tag." >&2
        echo "  rehearse:  ./Scripts/release.sh --dry-run $VERSION" >&2
        exit 1
    fi
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        echo "The checkout is not clean, so what would be published is not what is" >&2
        echo "committed. Commit or stash first:" >&2
        git -C "$ROOT" status --short >&2
        exit 1
    fi
    # `[0-9][0-9]*` and not `[0-9]\+`: the second is GNU syntax, and the `sed`
    # on macOS simply does not match it. Written that way this gate refused
    # every release, including correctly tagged ones — a check that always says
    # no is as broken as one that always says yes, and it hides better.
    VERSION="$(git -C "$ROOT" tag --points-at HEAD \
        | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | head -1)"
    if [ -z "$VERSION" ]; then
        echo "HEAD carries no SemVer tag, so this release would have no identity." >&2
        echo "  tag it first:  git tag -a v0.2.0 -m 'lampboard 0.2.0' && git push origin v0.2.0" >&2
        echo "  or rehearse:   ./Scripts/release.sh --dry-run 0.2.0" >&2
        exit 1
    fi
    if git -C "$ROOT" ls-remote --exit-code --tags origin "v$VERSION" >/dev/null 2>&1; then
        if gh release view "v$VERSION" >/dev/null 2>&1; then
            echo "v$VERSION is already published. A second artefact under a name that" >&2
            echo "is already taken is how two different builds come to share a version." >&2
            exit 1
        fi
    fi
else
    VERSION="${VERSION:-0.0.0-dry}"
    echo "▸ DRY RUN: version $VERSION is invented, and nothing here may be published."
fi

DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
# The same image under a name that carries no version: what
# `/releases/latest/download/LampBoard.dmg` serves. Written at the end, from the
# stapled file.
STABLE_DMG="$ROOT/dist/$APP_NAME.dmg"
IDENTITY="${LAMPBOARD_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LAMPBOARD_NOTARY_PROFILE:-}"

# How long Apple gets before we call it a failure.
#
# `--wait` on its own waits for ever, and that is not a theoretical problem:
# measured once, a disk image submission printed "initiating connection to the
# Apple notary service" and then held the terminal for two and a half hours,
# never reaching the queue — the submission does not even appear in
# `notarytool history`. Notarization normally takes one to five minutes, so
# twenty is generous and a hang stops looking like patience.
NOTARY_DEADLINE="${LAMPBOARD_NOTARY_TIMEOUT:-20m}"

# One Developer ID in the keychain is unambiguous, so we use it without being
# told. Several are a choice that belongs to the person releasing, not to us.
if [ -z "$IDENTITY" ]; then
    MATCHES="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' || true)"
    COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
    if [ "$COUNT" = "1" ]; then
        IDENTITY="$(printf '%s\n' "$MATCHES" | sed -n 's/.*"\(.*\)".*/\1/p')"
    elif [ "$COUNT" -gt 1 ]; then
        echo "▸ Several Developer ID certificates are installed:"
        printf '%s\n' "$MATCHES"
        echo
        echo "  Say which one:  export LAMPBOARD_SIGNING_IDENTITY='Developer ID Application: …'"
        exit 1
    fi
fi

echo "▸ lampboard $VERSION"
echo

LAMPBOARD_VERSION="$VERSION" "$ROOT/Scripts/build-app.sh" release >/dev/null
rm -rf "$ROOT/.build/release-app"
mkdir -p "$ROOT/.build/release-app"
cp -R "$BUILT" "$APP_DIR"
echo "▸ Bundle built and copied aside."

# ---------------------------------------------------------------------------
# Signature
# ---------------------------------------------------------------------------
#
# Two entitlements, and no more. The hardened runtime is what notarization
# requires, and by default it takes away exactly the two things this app does
# for a living: talking to other applications and listening to the microphone.
ENTITLEMENTS="$ROOT/.build/lampboard.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Raising the window of the session you clicked: AppleScript towards
         Terminal, iTerm2, Ghostty, System Events. Without this the hardened
         runtime denies every Apple Event and the click does nothing. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>

    <!-- Dictation, held down on the button. The Info.plist string explains it
         to the user; this entitlement is what lets the runtime allow it. -->
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
PLIST

if [ -n "$IDENTITY" ]; then
    echo "▸ Signing with “${IDENTITY}”…"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
else
    echo "▸ No Developer ID certificate: the local signature stays on."
fi

# ---------------------------------------------------------------------------
# Notarization of the app
# ---------------------------------------------------------------------------
#
# The app is notarized before the disk image and stapled on its own, so that
# the copy dragged out of the image carries its own ticket and opens even on a
# Mac that is offline.
NOTARIZED=0
if [ -n "$IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    ZIP="$ROOT/.build/$APP_NAME-$VERSION.zip"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    echo "▸ Notarizing the app (Apple takes a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout "$NOTARY_DEADLINE"
    xcrun stapler staple "$APP_DIR"
    rm -f "$ZIP"
    NOTARIZED=1
fi

# ---------------------------------------------------------------------------
# Disk image
# ---------------------------------------------------------------------------
STAGE="$ROOT/.build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Building the disk image…"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [ "$NOTARIZED" = "1" ]; then
    echo "▸ Notarizing the disk image…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout "$NOTARY_DEADLINE"
    xcrun stapler staple "$DMG"
fi

# ---------------------------------------------------------------------------
# What Gatekeeper actually says
# ---------------------------------------------------------------------------
#
# Not our opinion of the signature: the verdict of the same service that will
# decide on somebody else's Mac, asked here before the file leaves.
echo
echo "▸ Gatekeeper, asked here:"
GATE=0
spctl -a -vvv -t exec "$APP_DIR" 2>&1 | sed 's/^/    app: /' || GATE=1
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 \
    | sed 's/^/    dmg: /' || GATE=1

# It used to end `|| true`, so the one service whose opinion decides whether
# anybody can open this could say no and the script would still print a tick.
# A real release stops here; a rehearsal is allowed to be honest about it and
# carry on, because there is nothing to publish either way.
if [ "$GATE" != "0" ]; then
    if [ "$DRY_RUN" = "0" ]; then
        echo
        echo "✗ Gatekeeper refused. This artefact would be refused on every other" >&2
        echo "  Mac too, so it is not a release." >&2
        exit 1
    fi
    echo "    (dry run: refused, and that would stop a real release)"
fi

# ---------------------------------------------------------------------------
# The second name, which is the one machines use
# ---------------------------------------------------------------------------
#
# A byte-for-byte copy under a name with no version in it, published beside the
# versioned one. It exists so that
#
#     …/releases/latest/download/LampBoard.dmg
#
# is an address that never has to be edited: GitHub redirects `latest` to the
# newest published release, and the file inside it is found by name. A link
# carrying a version is correct on the day it is written and wrong at the next
# release, silently, while still answering 200 — which is the failure mode for
# anything that fetches on a schedule rather than by hand. Asked for by the
# people deploying this through an MDM, which polls exactly such an address.
#
# The copy is made **after** notarization and stapling, so the ticket travels
# with it: a copy made earlier would be an unstapled image wearing a trusted
# name. Same bytes, same checksum, both verifiable against each other.
cp "$DMG" "$STABLE_DMG"

# ---------------------------------------------------------------------------
# The package, for the Macs nobody sits in front of
# ---------------------------------------------------------------------------
#
# Built here rather than left to a line in the runbook, because a manual step in
# a runbook is a step nobody does — measured in this very project, where a gate's
# own mutation went stale for three releases behind exactly such a line.
#
# Only when the disk image was notarized: a package wraps the stapled bundle, and
# wrapping an unstapled one produces something that installs and then refuses to
# open. Only when there is a certificate for it, which is a different certificate
# from the one that signs the app — a machine without it still cuts a release,
# and the gate in the site's `check.py` is what refuses to publish one that is
# missing its package.
PKG=""
STABLE_PKG=""
if [ "$NOTARIZED" = "1" ] && [ "$DRY_RUN" = "0" ] \
   && security find-identity -v 2>/dev/null | grep -q 'Developer ID Installer'; then
    echo
    "$ROOT/Scripts/make-pkg.sh"
    PKG="$ROOT/dist/$APP_NAME-$VERSION.pkg"
    STABLE_PKG="$ROOT/dist/$APP_NAME.pkg"
elif [ "$NOTARIZED" = "1" ] && [ "$DRY_RUN" = "0" ]; then
    echo
    echo "▸ No package: no Developer ID Installer certificate here."
    echo "  The fleet manager needs one — see Scripts/make-pkg.sh for why and how."
fi

echo
echo "✓ $DMG"
echo "✓ $STABLE_DMG  (the same file, under the name the latest address serves)"
echo
if [ "$NOTARIZED" = "1" ]; then
    echo "  Notarized and stapled: it opens with a double click on any Mac."
    echo "  Publish:  gh release create v$VERSION '$DMG' '$STABLE_DMG'${PKG:+ '$PKG' '$STABLE_PKG'} --title 'lampboard $VERSION'"
elif [ -n "$IDENTITY" ]; then
    echo "  Signed but not notarized: on a Mac that has never seen it, macOS"
    echo "  will still refuse the first launch. Set the profile and run again:"
    echo "    export LAMPBOARD_NOTARY_PROFILE='lampboard'"
else
    echo "  Signed locally only. On somebody else's Mac this image is refused;"
    echo "  the way through, for a tester who accepts it knowingly, is"
    echo "  right-click on the app › Open, then Open again in the dialog."
    echo "  For a public release you need a Developer ID certificate:"
    echo "    export LAMPBOARD_SIGNING_IDENTITY='Developer ID Application: … (TEAMID)'"
fi
echo
