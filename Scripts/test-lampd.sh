#!/bin/bash
#
# lampd on a fake node, through a real ssh: its own suite, the `v1`
# conformance battery, the phone's lines it writes, one rule for the files,
# the service stopped, the recorded hooks, and the app one version behind.
#
# WHY THIS EXISTS
# `lampd` is the Linux machine's side of the phone (W3 of the mobile plan). The
# domain suite proves its rules against buffers; the phone reaches it through
# OpenSSH, a forced command, lines in authorized_keys that `lampd` itself
# writes, and Claude Code's real files on disk. None of that is in a buffer.
# This builds the binary exactly as it is installed (static, by
# Scripts/lampd-build.sh), puts it on a node with the Linux machine's versions
# (Ubuntu 24.04: OpenSSH 9.6p1, tmux 3.4, Python 3.12), and asks it everything
# the phone will, the way the phone will.
#
# What it holds, each with a bite in Scripts/bite.sh:
#   - the conformance battery, against `lampd v1-stdio` behind OpenSSH;
#   - one rule for the files: `lampd` and the phone's look over ssh give every
#     session the same lamp, frame by frame (Tests/NodeFixture/sessions.json);
#   - the lines `lampd devices add` writes: the read key gets `v1` and nothing
#     else, no terminal; another network's phone and a revoked phone stay out;
#     the house's own lines are untouched and its key still opens;
#   - the service stopped: the read key still gets the lights, read from the
#     files, and `hello` says so (E10 as amended on 17 October 2026);
#   - the recorded hooks reduced as the tee will reduce them, against the golden
#     files the Mac's end-to-end suite holds the real app to;
#   - the app one version behind (the Core and NodeLink of N1_REV) reading
#     `lampd` and still looking at the machine over ssh;
#   - the node's tmux running with the options of deploy/tmux/lampboard.conf
#     (Q10, E14), installed as the installer leaves them, and doctor saying so.
#
# Nothing of this machine is touched: the containers share a network of their
# own, no port is published, the node's home is the container's, every key is
# made for the run and thrown away with it.
#
# EXIT CODES
#   0  everything held
#   1  something does not build, the node did not start, or a check failed
#   3  there is no container engine here: nothing was observed
#
# USAGE
#   Scripts/test-lampd.sh              everything
#   Scripts/test-lampd.sh --record     writes the golden files of the recorded
#                                      hooks from lampd's replay, then checks
#   Scripts/test-lampd.sh <filter>     the checks over ssh whose name matches
#
# ENVIRONMENT
#   LAMPBOARD_LAMPD_GATE_CACHE  where the copy, the builds and the keys live
#                               (default ~/.cache/lampboard/lampd-gate)
#   LAMPBOARD_LAMPD_N1          the commit of the app one version behind

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE="swift:6.4@sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f"
NODE_BASE="ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55"
# The Core the TestFlight build 8 of the app (the last one out) was made from.
N1_REV="${LAMPBOARD_LAMPD_N1:-be2981b}"
CACHE="${LAMPBOARD_LAMPD_GATE_CACHE:-$HOME/.cache/lampboard/lampd-gate}"
NAME="lampboard-lampd-$$"
NODE="$NAME-node"
NET="$NAME-net"
LIMIT="${LAMPBOARD_LAMPD_GATE_LIMIT:-1200}"

RECORD=0
FILTER=""
for a in "$@"; do
    case "$a" in
        --record) RECORD=1 ;;
        *) FILTER="$a" ;;
    esac
done

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }
passed()         { printf '\033[32m✓\033[0m %s\n' "$1"; }

command -v docker >/dev/null 2>&1 || could_not_look "no docker here: lampd was not tried"
docker info >/dev/null 2>&1 || could_not_look "docker is here but its daemon does not answer: lampd was not tried"

mkdir -p "$CACHE"
LOCK="$CACHE/run.lock"
for _ in $(seq 1 240); do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
    kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null || { rm -rf "$LOCK"; continue; }
    sleep 5
done
[ "$(cat "$LOCK/pid" 2>/dev/null)" = $$ ] || failed "another run holds $LOCK and never let go"
cleanup() {
    docker rm -f "$NODE" "$NAME-build" "$NAME-check" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$CACHE/keys" "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ── The binary, as it is installed ──────────────────────────────────────────
echo "▸ Building lampd static"
mkdir -p "$CACHE/bin"
Scripts/lampd-build.sh --out "$CACHE/bin" > "$CACHE/lampd-build.log" 2>&1
case $? in
    0) ;;
    3) could_not_look "lampd could not be built here (see $CACHE/lampd-build.log)" ;;
    *) tail -5 "$CACHE/lampd-build.log" | sed 's/^/    /'; failed "lampd does not build static" ;;
esac
LAMPD="$CACHE/bin/lampd"

# ── The checks: the toolchain with an ssh client ────────────────────────────
IMAGE="lampboard-nodelink-gate:$(printf '%s' "$BASE openssh-server openssh-client python3 procps tmux" | shasum | cut -c1-12)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "▸ Preparing $IMAGE"
    docker build -q -t "$IMAGE" - > "$CACHE/image.log" 2>&1 <<EOF || could_not_look "the image could not be prepared (see $CACHE/image.log)"
FROM $BASE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        openssh-server openssh-client python3 procps tmux && rm -rf /var/lib/apt/lists/*
EOF
fi
NODE_IMAGE="lampboard-nodelink-tmux:$(printf '%s' "$NODE_BASE openssh-server python3 procps tmux curl" | shasum | cut -c1-12)"
if ! docker image inspect "$NODE_IMAGE" >/dev/null 2>&1; then
    echo "▸ Preparing $NODE_IMAGE"
    docker build -q -t "$NODE_IMAGE" - > "$CACHE/node-image.log" 2>&1 <<EOF || could_not_look "the node's image could not be prepared (see $CACHE/node-image.log)"
FROM $NODE_BASE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        openssh-server python3 procps tmux curl ca-certificates && rm -rf /var/lib/apt/lists/*
EOF
fi

SRC="$CACHE/src"
rm -rf "$SRC" "$CACHE/keys"
mkdir -p "$SRC" "$CACHE/build" "$CACHE/home" "$CACHE/keys"
git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - | tar -xf - -C "$SRC" \
    || failed "the working tree could not be copied to $SRC"
[ -f "$SRC/Package.resolved" ] || { [ -f "$CACHE/Package.resolved" ] && cp "$CACHE/Package.resolved" "$SRC/Package.resolved"; }

in_builder() {
    docker run --rm --name "$NAME-build" --user "$(id -u):$(id -g)" -e HOME=/tmp/h --cpus 8 --memory 8g \
        -v "$SRC:/src" -v "$CACHE/build:/src/.build" -v "$CACHE/home:/tmp/h" -v "$CACHE/keys:/keys" \
        -v "$CACHE/bin:/opt/lampd:ro" -w /src "$IMAGE" "$@"
}

echo "▸ Building lampd's suite and the checks over ssh"
if ! in_builder bash -c 'LAMPBOARD_STRICT=1 swift build --product LampDTests 2>&1 && LAMPBOARD_STRICT=1 swift build --product NodeLinkCheck 2>&1' > "$CACHE/build.log"; then
    sed 's/\x1b\[[0-9;]*m//g' "$CACHE/build.log" | grep -E '^/src/.*error:' | sort -u | head -20 | sed 's/^/    /'
    failed "lampd's checks do not build on Linux (the full log is $CACHE/build.log)"
fi
cp "$SRC/Package.resolved" "$CACHE/Package.resolved" 2>/dev/null

# ── The recorded hooks, reduced as the tee will ─────────────────────────────
echo
echo "▸ Recorded hooks, reduced by lampd, against the golden files the Mac is held to"
REPLAY_FAIL=0
for flow in Tests/NodeFixture/flows/*.jsonl; do
    base="$(basename "$flow" .jsonl)"
    golden="Tests/NodeFixture/parity/$base.json"
    out="$CACHE/replay-$base.json"
    in_builder /opt/lampd/lampd replay "/src/$flow" --workspace /tmp/lampd-replay > "$out" 2> "$out.err" \
        || { cat "$out.err" | sed 's/^/    /'; failed "lampd replay $base failed"; }
    if [ "$RECORD" = 1 ]; then
        cp "$out" "$golden"
        echo "    recorded $golden"
    fi
    if [ ! -f "$golden" ]; then
        echo "    $golden is missing: run with --record once, and check it against the Mac"
        REPLAY_FAIL=1
    elif ! diff -u "$golden" "$out" > "$out.diff"; then
        echo "    $base: lampd's reduction is not the golden one (the reducer drifted from the Mac's):"
        head -30 "$out.diff" | sed 's/^/      /'
        REPLAY_FAIL=1
    else
        echo "    $base: $(grep -c '"event"' "$golden") events, the same lamp after each"
    fi
done
[ "$REPLAY_FAIL" = 0 ] || failed "the recorded hooks are not reduced as the Mac reduces them"

echo
echo "▸ Every route of the hooks' port has an owner in lampd (§2.3)"
in_builder /opt/lampd/lampd routes > "$CACHE/routes.json" 2> "$CACHE/routes.err" || failed "lampd routes failed"
Scripts/check-lampd-routes.sh "$CACHE/routes.json" || failed "a route of the hooks' port has no owner in lampd"

echo
echo "▸ lampd's own suite"
in_builder bash -c "trap '' PIPE; timeout -k 5 600 .build/debug/LampDTests < /dev/null" || failed "lampd's suite failed"

# ── The node ────────────────────────────────────────────────────────────────
for prefix in "" far- lost- house-; do
    in_builder .build/debug/NodeLinkCheck keys /keys "$prefix" || failed "the keys could not be made"
done
pub() { tr -d '\n' < "$CACHE/keys/$1.pub"; }
# The house: lines that are not LampBoard's, which must come out as they went in.
cat > "$CACHE/keys/house.txt" <<EOF
# the house's own keys
$(pub house-action) house
from="192.0.2.0/24" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample build-box
EOF

docker network create "$NET" >/dev/null || failed "the network $NET could not be made"
echo
echo "▸ Starting the node ($NODE)"
docker run -d --init --name "$NODE" --network "$NET" --network-alias node \
    -v "$LAMPD:/opt/lampd/lampd:ro" -v "$ROOT/Tests/NodeFixture:/opt/fixture-src:ro" -v "$CACHE/keys:/keys:ro" \
    -v "$ROOT/deploy/tmux/lampboard.conf:/opt/lampboard-tmux.conf:ro" \
    "$NODE_IMAGE" bash -c '
        set -e
        useradd -m -s /bin/bash dev
        usermod -p "*" dev
        install -d -m 700 -o dev -g dev /home/dev/.ssh /home/dev/.lampd-fixture
        install -m 600 -o dev -g dev /keys/house.txt /home/dev/.ssh/authorized_keys
        install -d -o dev -g dev /home/dev/.local/lib/lampd/0.1.0 /home/dev/.local/bin /home/dev/.config/lampd
        install -m 755 -o dev -g dev /opt/lampd/lampd /home/dev/.local/lib/lampd/0.1.0/lampd
        ln -s /home/dev/.local/lib/lampd/0.1.0/lampd /home/dev/.local/bin/lampd
        echo "{\"name\": \"fake-node\"}" > /home/dev/.config/lampd/config.json
        # The tmux options as Scripts/lampd-install.sh leaves them, read by the
        # one line the owner adds to ~/.tmux.conf (Q10, E14).
        cp /opt/lampboard-tmux.conf /home/dev/.config/lampd/tmux.conf
        echo "source-file -q ~/.config/lampd/tmux.conf" > /home/dev/.tmux.conf
        chown dev:dev /home/dev/.config/lampd/config.json /home/dev/.local/bin/lampd
        chown -R dev:dev /home/dev
        mkdir -p /opt/fixture && cp -r /opt/fixture-src/. /opt/fixture/
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key
        mkdir -p /run/sshd
        printf "Port 2222\nHostKey /etc/ssh/ssh_host_ed25519_key\nSubsystem sftp /usr/lib/openssh/sftp-server\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nPermitRootLogin no\nUsePAM no\nAllowUsers dev\nClientAliveInterval 15\nClientAliveCountMax 3\n" > /etc/ssh/sshd_config
        exec /usr/sbin/sshd -D -e
    ' > /dev/null || failed "the node did not start"

ready=0
for _ in $(seq 1 100); do
    if docker exec "$NODE" bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222' 2>/dev/null; then ready=1; break; fi
    sleep 0.2
done
[ "$ready" = 1 ] || { docker logs "$NODE" 2>&1 | tail -5 | sed 's/^/    /'; failed "the node never listened"; }
docker exec "$NODE" cat /etc/ssh/ssh_host_ed25519_key.pub > "$CACHE/keys/host.pub" || failed "no host key"

as_dev() { docker exec -u dev -e HOME=/home/dev -e PATH=/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin -w /home/dev "$NODE" bash -c "$1"; }

# The phone's lines, written by `lampd devices add` as the owner of the
# machine runs it (gesture 17): the paired phone with the networks lampd finds
# on its own, one phone from another network, one paired and revoked.
as_dev "lampd devices add --id check-phone --name 'Check phone' --read '$(pub read)' --action '$(pub action)'" \
    > "$CACHE/devices.log" 2>&1 || { cat "$CACHE/devices.log"; failed "lampd devices add failed"; }
as_dev "lampd devices add --id far-phone --name 'Far phone' --read '$(pub far-read)' --action '$(pub far-action)' --from 192.0.2.0/24" \
    >> "$CACHE/devices.log" 2>&1 || failed "lampd devices add (far) failed"
as_dev "lampd devices add --id lost-phone --name 'Lost phone' --read '$(pub lost-read)' --action '$(pub lost-action)'" \
    >> "$CACHE/devices.log" 2>&1 || failed "lampd devices add (lost) failed"
as_dev "lampd devices revoke lost-phone" >> "$CACHE/devices.log" 2>&1 || failed "lampd devices revoke failed"
sed 's/^/    /' "$CACHE/devices.log"

as_dev "python3 /opt/fixture/fixture.py frame 0 > /dev/null" || failed "the fixture could not play frame 0"
as_dev "setsid nohup lampd serve >> /tmp/lampd.log 2>&1 < /dev/null & echo \$! > /tmp/lampd.pid"
started=0
for _ in $(seq 1 100); do
    if as_dev "lampd status > /dev/null 2>&1"; then started=1; break; fi
    sleep 0.2
done
[ "$started" = 1 ] || { as_dev "cat /tmp/lampd.log" | tail -5 | sed 's/^/    /'; failed "lampd never answered on the node"; }
echo "    lampd serves on the node: $(as_dev 'lampd status')"

echo
echo "▸ lampd over ssh, as the phone reaches it"
ONLY=""
[ -n "$FILTER" ] && ONLY="$(printf '%q' "$FILTER")"
docker run --rm --name "$NAME-check" --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp/h \
    -v "$CACHE/build:/src/.build:ro" -v "$CACHE/keys:/keys:ro" -w /src "$IMAGE" \
    bash -c "trap '' PIPE; timeout -k 5 $LIMIT .build/debug/NodeLinkCheck lampd --host node --port 2222 --user dev \
        --host-key /keys/host.pub --keys /keys --lampd /home/dev/.local/bin/lampd --fixture /opt/fixture/fixture.py \
        --log /tmp/lampd.log --name fake-node $ONLY < /dev/null"
status=$?
if [ "$status" != 0 ]; then
    echo "    lampd's log on the node, last lines:"
    as_dev "tail -12 /tmp/lampd.log" | sed 's/^/      /'
    case "$status" in
        124|137) failed "the checks over ssh were still running after $LIMIT seconds" ;;
        *) failed "lampd over ssh failed (exit $status)" ;;
    esac
fi

# ── The app one version behind ──────────────────────────────────────────────
echo
echo "▸ The app one version behind ($N1_REV) against this lampd"
# Whatever frame the checks left, the reader starts from the first one.
as_dev "python3 /opt/fixture/fixture.py frame 0 > /dev/null && lampd look > /dev/null" || failed "the fixture could not play frame 0 again"
N1="$CACHE/n1"
mkdir -p "$N1/build" "$N1/home"
if [ "$(cat "$N1/rev" 2>/dev/null)" != "$(git rev-parse "$N1_REV")" ]; then
    rm -rf "$N1/src" && mkdir -p "$N1/src"
    git archive "$N1_REV" Package.swift Package.resolved Sources/LampBoardCore Sources/LampBoardNodeLink Sources/TestKit \
        | tar -x -C "$N1/src" || failed "the commit $N1_REV could not be read"
    python3 - "$N1/src/Package.swift" <<'PY' || failed "the old manifest could not take the reader"
import re, sys
path = sys.argv[1]
s = open(path).read()
# Only the targets the reader needs, plus the reader.
start = s.index("    targets: [")
s = s[:start] + """    targets: [
        .target(name: "LampBoardCore", dependencies: crypto, swiftSettings: strict),
        .target(name: "TestKit", swiftSettings: strict),
        .target(name: "LampBoardNodeLink", dependencies: ["LampBoardCore"] + ssh, swiftSettings: strict),
        .executableTarget(name: "N1Reader", dependencies: ["LampBoardCore", "LampBoardNodeLink", "TestKit"], swiftSettings: strict),
    ]
)
"""
s = re.sub(r"products: \[.*?\],\n", "", s, flags=re.S)
open(path, "w").write(s)
PY
    git rev-parse "$N1_REV" > "$N1/rev"
fi
# The reader is this tree's, on the old Core: copied every run, so a change to it is the one checked.
mkdir -p "$N1/src/Sources/N1Reader"
cp Tests/NodeFixture/n1-reader/main.swift "$N1/src/Sources/N1Reader/main.swift"
if ! docker run --rm --name "$NAME-build" --user "$(id -u):$(id -g)" -e HOME=/tmp/h --cpus 8 --memory 8g \
        -v "$N1/src:/src" -v "$N1/build:/src/.build" -v "$N1/home:/tmp/h" -w /src "$IMAGE" \
        bash -c 'swift build --product N1Reader 2>&1' > "$N1/build.log"; then
    sed 's/\x1b\[[0-9;]*m//g' "$N1/build.log" | grep -E '^/src/.*error:' | sort -u | head -10 | sed 's/^/    /'
    failed "the reader of $N1_REV does not build"
fi
docker run --rm --name "$NAME-check" --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp/h \
    -v "$N1/build:/src/.build:ro" -v "$CACHE/keys:/keys:ro" -w /src "$IMAGE" \
    bash -c "trap '' PIPE; timeout -k 5 300 .build/debug/N1Reader --host node --port 2222 --user dev \
        --host-key /keys/host.pub --keys /keys --flip 'python3 /opt/fixture/fixture.py flip > /dev/null && ~/.local/bin/lampd look' < /dev/null" \
    || failed "the app one version behind cannot read this lampd"

# ── The hooks' port in tee (W5) ─────────────────────────────────────────────
# lampd started again holding the node's hooks' port (the container's own
# loopback: nothing of this machine), with the token and the port the Mac's
# repair would have written, the Mac's end of the tunnel and the push relay
# played by Tests/NodeFixture/tee.py, and a phone registered for notifications.
echo
echo "▸ The hooks' port in tee: heard here, passed on to the Mac, nothing the node may not ask"
HOOKS=31000
MACP=31001
RELAYP=31090
TEE_FAIL=0
TEE="python3 /opt/fixture/tee.py"
tee_check() { if eval "$2"; then echo "    ✓ $1"; else echo "    ✗ $1"; TEE_FAIL=1; fi; }
row() { as_dev "$TEE row $1"; }
alerts() { as_dev "$TEE alerts /tmp/relay.log"; }
presence() { as_dev "echo '{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"presence\":\"$1\"}' > /tmp/link.in"; }
IDLE=a1000000-0000-4000-8000-000000000005
BUSY=a1000000-0000-4000-8000-000000000001

as_dev 'kill "$(cat /tmp/lampd.pid)"; for i in $(seq 1 50); do kill -0 "$(cat /tmp/lampd.pid)" 2>/dev/null || break; sleep 0.1; done'
as_dev "mkdir -p ~/.lampboard && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > ~/.lampboard/token && chmod 600 ~/.lampboard/token && echo $HOOKS > ~/.lampboard/port"
as_dev "$TEE device ~/.local/state/lampd"
as_dev "echo '{\"name\": \"fake-node\", \"probeInterval\": 2, \"relay\": \"http://127.0.0.1:$RELAYP\"}' > ~/.config/lampd/config.json"
as_dev "setsid nohup $TEE mac $MACP /tmp/mac.log > /dev/null 2>&1 < /dev/null & setsid nohup $TEE relay $RELAYP /tmp/relay.log > /dev/null 2>&1 < /dev/null &"
as_dev "python3 /opt/fixture/fixture.py frame 0 > /dev/null"
# A Mac 2.3 whose tunnel already holds the hooks' port (§2.15, compatibility):
# lampd does not take it, says why, and serves the files; the hooks still reach
# that Mac as before.
as_dev "setsid nohup $TEE mac $HOOKS /tmp/mac23.log > /dev/null 2>&1 < /dev/null & echo \$! > /tmp/mac23.pid"
sleep 0.5
as_dev "LAMPD_HOOK_PORT=$HOOKS setsid nohup lampd serve >> /tmp/lampd-tee.log 2>&1 < /dev/null & echo \$! > /tmp/lampd.pid"
for _ in $(seq 1 100); do as_dev "lampd status > /dev/null 2>&1" && break; sleep 0.2; done
tee_check "a Mac 2.3's tunnel on the hooks' port: lampd leaves it, says why, and serves the files" \
    'as_dev "lampd status" | grep -q "not held: 127.0.0.1:$HOOKS is taken" && [ "$(row $BUSY | cut -d" " -f2)" = "sessionFile" ]'
tee_check "and the hooks still reach that Mac" \
    'as_dev "$TEE hook $HOOKS UserPromptSubmit $BUSY" | grep -q "^200" && as_dev "grep -q /signal /tmp/mac23.log"'
as_dev 'kill "$(cat /tmp/lampd.pid)" "$(cat /tmp/mac23.pid)"; for i in $(seq 1 50); do kill -0 "$(cat /tmp/lampd.pid)" 2>/dev/null || break; sleep 0.1; done'
as_dev "LAMPD_HOOK_PORT=$HOOKS setsid nohup lampd serve >> /tmp/lampd-tee.log 2>&1 < /dev/null & echo \$! > /tmp/lampd.pid"
for _ in $(seq 1 100); do as_dev "lampd status > /dev/null 2>&1" && break; sleep 0.2; done
sleep 1

tee_check "the hooks' port is bound on 127.0.0.1 only" '[ "$(as_dev "$TEE listening $HOOKS")" = "127.0.0.1" ]'
tee_check "status says lampd holds it and passes on to the Mac on $MACP" \
    'as_dev "lampd status" | grep -q "lampd on 127.0.0.1:$HOOKS, passed on to the Mac on $MACP"'
tee_check "token adopted: a hook with the token written before the switch is heard, the row changes colour" \
    '[ "$(as_dev "$TEE hook $HOOKS UserPromptSubmit $IDLE")" = "204 " ] && [ "$(row $IDLE | cut -d" " -f1-2)" = "working hooks" ]'
tee_check "and passed on to the Mac, named with X-LampBoard-Event (E3)" \
    'sleep 0.5; as_dev "grep /signal /tmp/mac.log | tail -1" | grep -q "\"x-lampboard-event\": \"tee-"'
tee_check "green to read when its Stop comes" \
    'as_dev "$TEE hook $HOOKS Stop $IDLE '"'"'{\"last_assistant_message\": \"Done.\"}'"'"'" > /dev/null; [ "$(row $IDLE | cut -d" " -f1)" = "ready" ]'
tee_check "a token that is not the hooks' is refused, and changes nothing" \
    'as_dev "$TEE hook $HOOKS UserPromptSubmit $IDLE --token $(printf "%064d" 0)" | grep -q "^401" && [ "$(row $IDLE | cut -d" " -f1)" = "ready" ]'
tee_check "/new and /chat from the node are refused (R2), so is a route nobody named, and none reaches the Mac" \
    'as_dev "$TEE post $HOOKS /new --body {}" | grep -q "^403" && as_dev "$TEE post $HOOKS /chat --body {}" | grep -q "^403" \
     && as_dev "$TEE post $HOOKS /a-route-of-tomorrow --body {}" | grep -q "^404" \
     && ! as_dev "grep -qE \"\\\"path\\\": \\\"/(new|chat|a-route-of-tomorrow)\" /tmp/mac.log"'
tee_check "/health is lampd's own" '[ "$(as_dev "$TEE post $HOOKS /health")" = "200 lampboard" ]'

# Q8, and «no double notification»: with the Mac at the desk an amber of this
# machine does not ring the phone (the Mac's banner does); away, it does.
as_dev "rm -f /tmp/link.in; mkfifo /tmp/link.in; setsid nohup sleep 900 > /tmp/link.in 2>/dev/null < /dev/null & echo \$! > /tmp/link-writer.pid; setsid nohup lampd mac-link < /tmp/link.in > /tmp/link.out 2> /tmp/link.err & echo \$! > /tmp/link.pid"
presence here
sleep 2
tee_check "mac-link beats that lampd is serving, and sends the choices once" \
    '[ "$(as_dev "grep -c \"serving\\\":true\" /tmp/link.out")" -gt 2 ] && as_dev "grep -q \"preferences\" /tmp/link.out"'
tee_check "status says the Mac is at the desk" 'as_dev "lampd status" | grep -q "at the Mac: the phone stays quiet"'
BEFORE="$(alerts)"
as_dev "python3 /opt/fixture/fixture.py ask 2 > /dev/null"
sleep 10
tee_check "the Mac at the desk: an amber of this machine sends the phone nothing" '[ "$(alerts)" = "$BEFORE" ]'
as_dev "python3 /opt/fixture/fixture.py ask 2 off > /dev/null"
sleep 3
presence away
sleep 1
as_dev "python3 /opt/fixture/fixture.py ask 2 > /dev/null"
sleep 10
tee_check "the Mac away: the same amber rings the phone" '[ "$(alerts)" -gt "$BEFORE" ]'

# A question the Mac holds (M9): amber here with its text at once, and the push
# leaves while the Mac still holds it (tee.py's Mac holds /check for 8 s).
BEFORE="$(alerts)"
as_dev "setsid nohup $TEE post $HOOKS /check --body '{\"v\":1,\"session\":\"$BUSY\",\"id\":\"toolu_01\",\"tool\":\"Bash\",\"detail\":\"npm publish\"}' > /tmp/check.out 2>&1 < /dev/null &"
sleep 1.5
tee_check "while the Mac holds a question the row is amber, held by the Mac, with the question" \
    'row $BUSY | grep -q "^awaiting .* true Bash: npm publish$"'
sleep 5
tee_check "and the push leaves while the Mac still holds it" '[ "$(alerts)" -gt "$BEFORE" ]'
sleep 3
tee_check "the Mac's answer goes back to the mod untouched" '[ "$(as_dev "cat /tmp/check.out")" = "200 allow.signed" ]'

# The idle compaction's flow through the tee, recorded at the Mac's end: the
# Mac receives exactly what the hooks sent.
as_dev "$TEE play $HOOKS /opt/fixture/flows/idle-compaction.jsonl --token ~/.lampboard/token" || TEE_FAIL=1
sleep 1
as_dev "$TEE flow /tmp/mac.log idle-compaction-01 idle-compaction-02" > "$CACHE/idle-compaction.recorded.jsonl"
tee_check "the idle compaction's flow reaches the Mac through the tee as it was sent" \
    'python3 -c "
import json, sys
sent = [json.loads(l)[\"payload\"] for l in open(\"Tests/NodeFixture/flows/idle-compaction.jsonl\") if l.strip()]
got = [json.loads(l)[\"payload\"] for l in open(\"$CACHE/idle-compaction.recorded.jsonl\") if l.strip()]
sys.exit(0 if sent == got else 1)"'

tee_check "lampd release gives the port back to the Mac" \
    'as_dev "lampd release" > /dev/null; sleep 0.5; [ -z "$(as_dev "$TEE listening $HOOKS")" ] && as_dev "lampd status" | grep -q "released with lampd release"'
as_dev 'kill "$(cat /tmp/link.pid)" "$(cat /tmp/link-writer.pid)" 2>/dev/null; true'
if [ "$TEE_FAIL" != 0 ]; then
    echo "    lampd's log on the node, last lines:"
    as_dev "tail -15 /tmp/lampd-tee.log" | sed 's/^/      /'
    failed "the hooks' port in tee did not hold"
fi

echo
passed "lampd builds static, keeps the conformance battery behind OpenSSH, holds the phone's lines to what they may do, lights what the probe lights, serves the files when stopped, reduces the hooks as the Mac does, answers the app one version behind, and holds the hooks' port in tee"
