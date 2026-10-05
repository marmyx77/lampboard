#!/bin/bash
# Renders the Homebrew cask from a published release.
#
#     ./Scripts/make-cask.sh 0.2.0
#
# Reads the checksum from the release asset rather than from the local build:
# the file people install is the one GitHub serves, and a checksum taken from
# `dist/` would be right on this machine and wrong for everybody else the moment
# a rebuild differed by a byte. It downloads to check, which is the point.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 0.2.0"; exit 1; }
VERSION="${VERSION#v}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPL="$ROOT/packaging/lampboard-cask.rb.tmpl"
OUT="$ROOT/dist/lampboard.rb"
URL="https://github.com/marmyx77/lampboard/releases/download/v$VERSION/LampBoard-$VERSION.dmg"

echo "▸ Fetching $URL"
TMP="$(mktemp "${TMPDIR:-/tmp}/lampboard-dmg.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 2 -o "$TMP" "$URL" || {
    echo "  Not there. Publish the release first:  ./Scripts/release.sh"
    exit 1
}

SHA="$(shasum -a 256 "$TMP" | cut -d' ' -f1)"
echo "▸ sha256 $SHA"

mkdir -p "$ROOT/dist"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" "$TMPL" > "$OUT"
echo "  ✓ $OUT"
echo
echo "Then, in the tap:"
echo "  cp '$OUT' <homebrew-tap>/Casks/lampboard.rb"
echo "  git -C <homebrew-tap> commit -am 'lampboard $VERSION' && git push"
echo
echo "And prove it before telling anybody:"
echo "  brew untap marmyx77/tap 2>/dev/null; brew tap marmyx77/tap"
echo "  brew install --cask lampboard"
