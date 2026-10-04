#!/bin/bash
#
# Runs Scripts/test.sh for a branch on another Mac, from this one.
#
# The Mac you work on is the wrong place for a gate: a full run compiles the
# package twenty-eight times (once, then once per mutation in bite.sh) and the
# person at the keyboard is often in a call. This pushes the branch to a bare
# repository on the test Mac, checks it out in a worktree of its own there, and
# runs the gate under caffeinate and a time limit. The last line it prints is
# the gate's own verdict.
#
# What it tests is the commit, never the working tree: uncommitted changes stay
# here, and it says so before it starts.
#
# Where the test Mac is lives in .env.machines, which git ignores, so that no
# host name or account ever reaches this public repository:
#
#   LAMPBOARD_RUNNER_SSH=<user>@<host>       the account that runs the gate
#   LAMPBOARD_RUNNER_MIRROR=ssh://<host>/<path>.git
#                                            the bare repository it fetches from
#   LAMPBOARD_RUNNER_CLONE=Development/lampboard
#                                            its clone, relative to its home
#                                            (remote "hub" pointing at the mirror)
#
# Usage:
#   Scripts/run-remote.sh                  the current branch
#   Scripts/run-remote.sh <branch> [args]  that branch; args go to test.sh
#   Scripts/run-remote.sh --clean <branch> remove the branch's worktree there

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env.machines" ] && . "$ROOT/.env.machines"

RUNNER="${LAMPBOARD_RUNNER_SSH:?set LAMPBOARD_RUNNER_SSH in .env.machines}"
MIRROR="${LAMPBOARD_RUNNER_MIRROR:?set LAMPBOARD_RUNNER_MIRROR in .env.machines}"
CLONE="${LAMPBOARD_RUNNER_CLONE:-Development/lampboard}"
# Seconds. A full gate takes about ten minutes on the test Mac; a run that has
# not finished in an hour is stuck, and a stuck run is a failure.
LIMIT="${LAMPBOARD_RUNNER_LIMIT:-3600}"

# Every wait is bounded. An ssh that never returns is the classic way for an
# agent to hang for hours believing it is still testing.
bounded() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; }

CLEAN=0
if [ "${1:-}" = "--clean" ]; then CLEAN=1; shift; fi
BRANCH="${1:-$(git -C "$ROOT" symbolic-ref --short HEAD)}"
[ $# -gt 0 ] && shift
# A leading '-' would reach git as an option; anything else odd would reach a
# remote shell. Both are refused.
case "$BRANCH" in -*|*[!A-Za-z0-9._/-]*) echo "run-remote: invalid branch name" >&2; exit 2;; esac
SLUG="${BRANCH//\//-}"
WT="${CLONE}-wt/$SLUG"

if [ "$CLEAN" = 1 ]; then
    bounded 60 ssh -o BatchMode=yes "$RUNNER" \
        "cd ~/$CLONE && git worktree remove --force ~/$WT 2>/dev/null; git worktree prune" \
        && echo "run-remote: worktree $SLUG removed"
    exit $?
fi

if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "run-remote: uncommitted changes stay here; testing the last commit of $BRANCH" >&2
fi

# The mirror is a scratch copy that only this script writes to, so a rebased
# branch simply replaces what was there.
bounded 120 git -C "$ROOT" push -q "$MIRROR" "+$BRANCH:refs/heads/$BRANCH" \
    || { echo "run-remote: push to the test Mac failed" >&2; exit 2; }

ARGS=""
for a in "$@"; do ARGS="$ARGS $(printf '%q' "$a")"; done

# One gate at a time: two would share the end-to-end port. The lock is a
# directory because mkdir is atomic; one left by a dead process is taken over.
bounded $((LIMIT + 2100)) ssh -o BatchMode=yes "$RUNNER" "set -e
LOCK=~/.local/state/lampboard/run.lock
mkdir -p ~/.local/state/lampboard
for i in \$(seq 1 360); do
    if mkdir \$LOCK 2>/dev/null; then echo \$\$ > \$LOCK/pid; break; fi
    kill -0 \"\$(cat \$LOCK/pid 2>/dev/null)\" 2>/dev/null || { rm -rf \$LOCK; continue; }
    [ \$i = 1 ] && echo 'run-remote: another gate is running there; waiting' >&2
    sleep 5
done
[ -d \$LOCK ] && [ \"\$(cat \$LOCK/pid)\" = \$\$ ] || { echo 'run-remote: the lock never freed' >&2; exit 2; }
trap 'rm -rf \$LOCK' EXIT
cd ~/$CLONE
git fetch -q hub --prune
if [ -d ~/$WT ]; then git -C ~/$WT checkout -q --detach 'hub/$BRANCH'; else git worktree add -q --detach ~/$WT 'hub/$BRANCH'; fi
cd ~/$WT
export PATH=/opt/homebrew/bin:\$PATH
echo \"run-remote: \$(git log --oneline -1) on \$(sw_vers -productVersion), \$(swift --version 2>&1 | grep -o 'Swift version [0-9.]*')\"
caffeinate -dims perl -e 'alarm shift; exec @ARGV or die' $LIMIT Scripts/test.sh$ARGS"
