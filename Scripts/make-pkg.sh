#!/bin/bash
#
# Builds the installer package a fleet manager deploys.
#
#     ./Scripts/make-pkg.sh            after ./Scripts/release.sh, in the same run
#
# WHY A PACKAGE AS WELL AS A DISK IMAGE
# A `.dmg` is a disk image and the format has no version field anywhere in it. A
# person mounting one does not care; an MDM does, because it has to answer "is
# the copy on that Mac older than this?" before it sends anything. With nothing
# to read, the administrator types the number by hand — and typing it high means
# update commands that never stop, typing it low means updates that never start.
#
# A package carries `identifier` and `version` in its own metadata, which is what
# the MDM reads. Same application, same bytes inside, one fact more on the
# outside.
#
# WHAT IT TAKES AND WHAT IT REFUSES
# It packages the bundle `release.sh` has already signed, notarized and stapled —
# `.build/release-app/LampBoard.app` — and never builds one of its own. A package
# is a wrapper: wrapping an unstapled application would produce something that
# installs and then refuses to open, on the machines of people who are not
# watching.
#
# It refuses to produce an unsigned package. The disk image has a use unsigned —
# a tester who knows how to answer Gatekeeper — and this has none: every path
# that would deploy it checks the signature first.
#
# The identity is a **Developer ID Installer** certificate, which is a different
# certificate from the one that signs the app. Having one does not give you the
# other.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LampBoard"
BUNDLE_ID="com.lampboard.app"
APP="$ROOT/.build/release-app/$APP_NAME.app"
NOTARY_PROFILE="${LAMPBOARD_NOTARY_PROFILE:-}"
NOTARY_DEADLINE="${LAMPBOARD_NOTARY_TIMEOUT:-20m}"

[ -d "$APP" ] || {
    echo "No signed bundle at $APP." >&2
    echo "Run ./Scripts/release.sh first: this wraps what that produces." >&2
    exit 1
}

# The version is read from the bundle rather than taken as an argument, because
# two numbers that must agree and are typed twice are two numbers that will one
# day disagree. `release.sh` stamped it from the tag.
VERSION="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
PKG="$ROOT/dist/$APP_NAME-$VERSION.pkg"
# The name with no version in it, for `/releases/latest/download/LampBoard.pkg`.
STABLE_PKG="$ROOT/dist/$APP_NAME.pkg"

# Refused rather than wrapped: an application whose ticket is not attached will
# be stopped by Gatekeeper on first launch, and a package is exactly the channel
# where nobody sees that happen.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "The bundle at $APP is not stapled." >&2
    echo "Only a notarized, stapled application is worth packaging." >&2
    exit 1
fi

IDENTITY="${LAMPBOARD_INSTALLER_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    MATCHES="$(security find-identity -v 2>/dev/null | grep 'Developer ID Installer' || true)"
    COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
    if [ "$COUNT" = "1" ]; then
        IDENTITY="$(printf '%s\n' "$MATCHES" | sed -n 's/.*"\(.*\)".*/\1/p')"
    elif [ "$COUNT" -gt 1 ]; then
        echo "▸ Several Developer ID Installer certificates are installed:"
        printf '%s\n' "$MATCHES"
        echo
        echo "  Say which one:  export LAMPBOARD_INSTALLER_IDENTITY='Developer ID Installer: …'"
        exit 1
    fi
fi

if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Installer certificate in the keychain." >&2
    echo >&2
    echo "  It is not the one that signs the app: that is Developer ID Application," >&2
    echo "  and having it does not give you this. Make one at developer.apple.com" >&2
    echo "  (Certificates -> + -> Developer ID Installer), then:" >&2
    echo "    security find-identity -v | grep Installer" >&2
    exit 1
fi

echo "▸ $APP_NAME $VERSION, packaged"
echo "    signing with: $IDENTITY"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root"
cp -R "$APP" "$STAGE/root/"

mkdir -p "$ROOT/dist"
rm -f "$PKG" "$STABLE_PKG"
# No install scripts, and that is a decision. The hooks live in each person's own
# `~/.claude/settings.json`, and a package runs as root with nobody's session
# around it; the application asks on first launch, which is where somebody is
# there to answer. A package that wrote into a home directory it guessed would be
# writing into the wrong one on any Mac with two accounts.
pkgbuild \
    --root "$STAGE/root" \
    --install-location /Applications \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --sign "$IDENTITY" \
    "$PKG" >/dev/null

echo "    $(basename "$PKG") built and signed"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "▸ Notarizing (deadline $NOTARY_DEADLINE)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout "$NOTARY_DEADLINE"
    xcrun stapler staple "$PKG"
else
    echo "▸ Not notarized: LAMPBOARD_NOTARY_PROFILE is unset."
    echo "  Gatekeeper refuses an unnotarized package on a Mac that has never seen it."
fi

# ---------------------------------------------------------------------------
# What the system says about it, not what we believe
# ---------------------------------------------------------------------------
echo
echo "▸ Asked here:"
pkgutil --check-signature "$PKG" | sed -n '2,3p' | sed 's/^/    /'
# `-t install` is the assessment an installer package gets; `-t open` would
# answer about a document and pass on things that will not install.
spctl -a -vv -t install "$PKG" 2>&1 | sed 's/^/    /' || GATE=1

if [ -n "$NOTARY_PROFILE" ] && [ "${GATE:-0}" != "0" ]; then
    echo >&2
    echo "✗ Gatekeeper refused a package we notarized. It would be refused on" >&2
    echo "  every other Mac too, so it is not something to publish." >&2
    exit 1
fi

# The copy last, from the stapled file, for the same reason the disk image's is:
# a copy taken earlier is an unstapled artefact wearing a trusted name.
cp "$PKG" "$STABLE_PKG"

echo
echo "✓ $PKG"
echo "✓ $STABLE_PKG  (the same file, under the name the latest address serves)"
