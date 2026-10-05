#!/bin/bash
#
# Cuts a release on the Mac that signs, from any machine that can reach it
# (D106): the tag goes to the mirror, the signing account checks it out and
# runs `release.sh` with its own keychain, and the four files come back into
# dist/ here, ready for `gh release create`.
#
#   Scripts/release-remote.sh v0.7.0
#
# The signing account holds the Developer ID identities and the notarytool
# profile in a keychain of its own, unlocked from a file only it can read; see
# release.sh. Nothing secret crosses this connection.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: Scripts/release-remote.sh vX.Y.Z}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a release tag: $TAG" >&2; exit 2; }
VERSION="${TAG#v}"

# shellcheck disable=SC1091
[ -f "$ROOT/.env.machines" ] && . "$ROOT/.env.machines"
SIGNER="${LAMPBOARD_SIGNER:?set LAMPBOARD_SIGNER (user@host) in .env.machines}"
MIRROR="${LAMPBOARD_RUNNER_MIRROR:?set LAMPBOARD_RUNNER_MIRROR in .env.machines}"
SIGNER_REPO="${LAMPBOARD_SIGNER_REPO:?set LAMPBOARD_SIGNER_REPO, the mirror as a path on the signing Mac}"

git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "no tag $TAG here" >&2; exit 2; }
git -C "$ROOT" push -q "$MIRROR" "refs/tags/$TAG"

# shellcheck disable=SC2029
ssh "$SIGNER" "set -euo pipefail
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    dir=\$HOME/Development/lampboard-release
    [ -d \"\$dir/.git\" ] || git clone -q '$SIGNER_REPO' \"\$dir\"
    cd \"\$dir\"
    git fetch -q --tags origin
    git checkout -q --detach '$TAG'
    git clean -qfdx -e .build
    LAMPBOARD_NOTARY_PROFILE=lampboard \\
    LAMPBOARD_NOTARY_KEYCHAIN=\$HOME/Library/Keychains/lampboard-release.keychain-db \\
    LAMPBOARD_NOTARY_KEYCHAIN_PASSWORD_FILE=\$HOME/.config/lampboard-release/keychain-password \\
        ./Scripts/release.sh"

mkdir -p "$ROOT/dist"
for f in "LampBoard-$VERSION.dmg" LampBoard.dmg "LampBoard-$VERSION.pkg" LampBoard.pkg; do
    scp -q "$SIGNER:Development/lampboard-release/dist/$f" "$ROOT/dist/$f"
done
echo "✓ dist/: the four files of $TAG, signed and notarized on $SIGNER"
