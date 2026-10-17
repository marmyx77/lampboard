#!/bin/bash
#
# The contract check as lampd's timer runs it on a Linux machine (E5 of the
# mobile plan, ADR-65 point 11): from the installed copy, outside the checkout,
# on a machine without binutils, with a fake Claude Code that writes down every
# time it is run.
#
# WHY THIS EXISTS
# Scripts/check-contract.sh was written for the Mac and run from the checkout.
# Read for the node in W0 (S-M), it had four defects that would have made the
# timer lie or misbehave there: a note in backticks that ran `claude` while
# printing a sentence; a script called by a path relative to the checkout,
# which is red everywhere else; `strings` used without being asked for, which a
# Linux machine without binutils answers with a traceback; and sections that
# only a Mac can satisfy, red for ever on a node. Each is held here, and each
# has a bite in Scripts/bite.sh.
#
# Runs in a container of the node's image (Ubuntu 24.04, python3, no binutils),
# as an account of its own; nothing of this machine is read.
#
# EXIT CODES
#   0  the timer's run is clean
#   1  it is not
#   3  there is no container engine here: nothing was observed

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NODE_BASE="ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55"
NODE_IMAGE="lampboard-nodelink-tmux:$(printf '%s' "$NODE_BASE openssh-server python3 procps tmux" | shasum | cut -c1-12)"
NAME="lampboard-contract-$$"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || could_not_look "no docker here: the contract on a node was not tried"
docker info >/dev/null 2>&1 || could_not_look "docker is here but its daemon does not answer: the contract on a node was not tried"
if ! docker image inspect "$NODE_IMAGE" >/dev/null 2>&1; then
    docker build -q -t "$NODE_IMAGE" - > /dev/null 2>&1 <<EOF || could_not_look "the node's image could not be prepared"
FROM $NODE_BASE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        openssh-server python3 procps tmux && rm -rf /var/lib/apt/lists/*
EOF
fi

WORK="$(mktemp -d)"
trap 'docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
# The copy lampd-install.sh makes, and nothing else of the repository.
mkdir -p "$WORK/contract/Scripts"
cp Scripts/check-contract.sh Scripts/measure-compaction.py "$WORK/contract/Scripts/"
cp -r Contracts "$WORK/contract/Contracts"
cp deploy/lampd/lampd-contract.sh "$WORK/contract/lampd-contract.sh"

docker run --rm --name "$NAME" -v "$WORK/contract:/opt/contract-src:ro" "$NODE_IMAGE" bash -c '
    set -e
    useradd -m -s /bin/bash dev
    mkdir -p /home/dev/.local/lib/lampd && cp -r /opt/contract-src /home/dev/.local/lib/lampd/contract
    mkdir -p /home/dev/.local/share/claude/versions /home/dev/.local/bin /home/dev/.claude/sessions /home/dev/.claude/projects/-home-dev-work
    # A Claude Code that only writes down that it was run, and with what.
    cat > /home/dev/.local/share/claude/versions/2.1.300 <<"FAKE"
#!/bin/sh
echo "run:$*" >> /tmp/claude-was-run
FAKE
    chmod +x /home/dev/.local/share/claude/versions/2.1.300
    ln -s /home/dev/.local/share/claude/versions/2.1.300 /home/dev/.local/bin/claude
    echo "{\"hooks\": {}}" > /home/dev/.claude/settings.json
    echo "{\"pid\": 1, \"sessionId\": \"s\", \"cwd\": \"/home/dev/work\", \"status\": \"idle\"}" > /home/dev/.claude/sessions/1.json
    echo "{\"type\":\"user\",\"timestamp\":\"2027-01-15T08:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}" > /home/dev/.claude/projects/-home-dev-work/s.jsonl
    chown -R dev:dev /home/dev
    command -v strings > /dev/null && { echo "this image has strings: the check would not see its absence"; exit 9; }
    cd /
    runuser -u dev -- env HOME=/home/dev PATH=/home/dev/.local/bin:/usr/bin:/bin /home/dev/.local/lib/lampd/contract/lampd-contract.sh --force > /tmp/timer.out 2>&1
    echo "timer-exit:$?" >> /tmp/timer.out
    runuser -u dev -- env HOME=/home/dev PATH=/home/dev/.local/bin:/usr/bin:/bin /home/dev/.local/lib/lampd/contract/Scripts/check-contract.sh --node --live > /tmp/live.out 2>&1 || true
    echo "== timer"; cat /tmp/timer.out
    echo "== stamp"; cat /home/dev/.local/state/lampd/contract.json; echo
    echo "== report"; cat /home/dev/.local/state/lampd/contract.log
    echo "== live"; cat /tmp/live.out
    echo "== claude runs"; cat /tmp/claude-was-run 2>/dev/null || true
' > "$WORK/out.txt" 2>&1 || { tail -20 "$WORK/out.txt" | sed 's/^/    /'; failed "the timer's run could not be made"; }

section() { awk -v want="== $1" '$0 == want {on=1; next} /^== / {on=0} on' "$WORK/out.txt"; }
PROBLEMS=0
problem() { printf '    %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }

section timer | grep -q '^timer-exit:0$' || problem "the timer did not end well: $(section timer | tail -2 | tr '\n' ' ')"
section stamp | grep -q '"claudeVersion": "2.1.300"' || problem "the stamp does not name the version read from the installer's folder"
if section claude\ runs | grep -qx 'run:'; then
    problem "claude was run with no arguments: a command in the report's own words"
fi
if section claude\ runs | grep -q 'run:--version'; then
    problem "claude was run for its version on a node, where the folder names it"
fi
if section report | grep -Eq "Traceback|No such file or directory|can't open file|command not found"; then
    problem "the report broke on this machine: $(section report | grep -E "Traceback|No such file|can't open file|command not found" | head -2 | tr '\n' ' ')"
    section report | grep -Eq "measure-compaction" && problem "a script called by a path relative to the checkout"
    section report | grep -Eq "Traceback" && problem "a tool it does not declare (strings) is missing, and it crashed instead of saying so"
fi
section report | grep -q 'IDE lock' && problem "red for ever on a node: it asks for an editor's lock file"
section report | grep -q 'could not look\|not here' || true

if [ "$PROBLEMS" -gt 0 ]; then
    echo "    the report, as the timer left it:"
    section report | sed 's/^/      /' | head -40
    failed "the contract check is not fit for lampd's timer on a node"
fi
printf '\033[32m✓\033[0m the contract check runs from lampd'"'"'s copy on a node: no claude run, no crash, nothing red for ever (%s)\n' \
    "$(section stamp | python3 -c 'import json,sys; print(json.load(sys.stdin)["outcome"])' 2>/dev/null)"
