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
#
# The release runs **detached** on the signing Mac and is asked after every
# half minute, because the connection is not to be trusted for twenty: on
# 5 October the test Mac dropped off the network twice in an hour, and the
# first version — one ssh held open for the whole release — hung with it. An
# ssh that fails is a question not answered yet, never a release failed; the
# release says it is over by writing its exit status beside its log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: Scripts/release-remote.sh vX.Y.Z}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a release tag: $TAG" >&2; exit 2; }
VERSION="${TAG#v}"
# How long the whole release may take before this side stops asking.
DEADLINE_MINUTES="${LAMPBOARD_RELEASE_DEADLINE:-90}"

# shellcheck disable=SC1091
[ -f "$ROOT/.env.machines" ] && . "$ROOT/.env.machines"
SIGNER="${LAMPBOARD_SIGNER:?set LAMPBOARD_SIGNER (user@host) in .env.machines}"
MIRROR="${LAMPBOARD_RUNNER_MIRROR:?set LAMPBOARD_RUNNER_MIRROR in .env.machines}"
SIGNER_REPO="${LAMPBOARD_SIGNER_REPO:?set LAMPBOARD_SIGNER_REPO, the mirror as a path on the signing Mac}"
RUNS="Development/lampboard-release-run"

git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "no tag $TAG here" >&2; exit 2; }
git -C "$ROOT" push -q "$MIRROR" "refs/tags/$TAG"

ask() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "$SIGNER" "$@"; }
# A step that must happen, tried for ten minutes before giving up.
again() { local i; for i in $(seq 1 20); do "$@" && return 0; sleep 30; done; return 1; }

# The run, as a file there: what it does is readable, and it writes its own
# status on the way out, whatever ended it.
RUN="$(mktemp)"; trap 'rm -f "$RUN"' EXIT
cat > "$RUN" <<EOF
#!/bin/bash
set -euo pipefail
trap 'echo \$? > "\$HOME/$RUNS/$TAG.status"' EXIT
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
dir="\$HOME/Development/lampboard-release"
[ -d "\$dir/.git" ] || git clone -q '$SIGNER_REPO' "\$dir"
cd "\$dir"
git fetch -q --tags origin
git checkout -q --detach '$TAG'
git clean -qfdx -e .build
LAMPBOARD_NOTARY_PROFILE=lampboard \\
LAMPBOARD_NOTARY_KEYCHAIN="\$HOME/Library/Keychains/lampboard-release.keychain-db" \\
LAMPBOARD_NOTARY_KEYCHAIN_PASSWORD_FILE="\$HOME/.config/lampboard-release/keychain-password" \\
    ./Scripts/release.sh
EOF
send() { ask "mkdir -p $RUNS && cat > $RUNS/$TAG.sh" < "$RUN"; }
again send || { echo "release-remote: could not reach $SIGNER" >&2; exit 1; }

# Started once: a run already going is asked after, not started again.
# shellcheck disable=SC2029
start() { ask "cd $RUNS
    if [ -f $TAG.pid ] && kill -0 \"\$(cat $TAG.pid)\" 2>/dev/null; then echo 'release-remote: already running there'; exit 0; fi
    rm -f $TAG.status
    nohup /bin/bash $TAG.sh > $TAG.log 2>&1 < /dev/null &
    echo \$! > $TAG.pid
    echo 'release-remote: started there'"; }
again start || { echo "release-remote: could not start the release on $SIGNER" >&2; exit 1; }

deadline=$(( $(date +%s) + DEADLINE_MINUTES * 60 ))
status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 30
    # shellcheck disable=SC2029
    status="$(ask "cat $RUNS/$TAG.status 2>/dev/null" 2>/dev/null || true)"
    [ -n "$status" ] && break
done
[ -n "$status" ] || { echo "release-remote: no answer within $DEADLINE_MINUTES minutes; the run may still be going there ($RUNS/$TAG.log)" >&2; exit 1; }
# shellcheck disable=SC2029
ask "tail -40 $RUNS/$TAG.log" || true
[ "$status" = "0" ] || { echo "release-remote: release.sh ended with $status there" >&2; exit 1; }

mkdir -p "$ROOT/dist"
for f in "LampBoard-$VERSION.dmg" LampBoard.dmg "LampBoard-$VERSION.pkg" LampBoard.pkg; do
    for attempt in 1 2 3 4 5; do
        scp -q -o BatchMode=yes -o ConnectTimeout=15 "$SIGNER:Development/lampboard-release/dist/$f" "$ROOT/dist/$f" && break
        [ "$attempt" = 5 ] && { echo "release-remote: could not bring $f back" >&2; exit 1; }
        sleep 30
    done
done
echo "✓ dist/: the four files of $TAG, signed and notarized on $SIGNER"
