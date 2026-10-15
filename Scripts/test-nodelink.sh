#!/bin/bash
#
# NodeLink over a real ssh: the `v1` conformance battery and the key bites,
# from one container to a node in another.
#
# WHY THIS EXISTS
# The battery in the domain suite proves the protocol against a buffer. The
# phone will reach it through ssh: OpenSSH on a node, a forced command for the
# read key, a pinned host key, channels that end. None of that is in a buffer,
# and the first anyone would hear of a NodeLink that cannot carry `v1` — or of a
# read key that can run something else — would be the phone. This makes both a
# red the same day (D175).
#
# The node is the pinned `swift` image with OpenSSH, an account `demo`, its own
# host key, the reference `v1` daemon (V1ReferenceNode, the shape `lampd` will
# have) and two keys written the way a node's `authorized_keys` holds them: the
# read key forced to `V1ReferenceNode stdio` with `restrict`, the action key
# with `restrict,pty`. Nothing of this machine is touched: the two containers
# share a network of their own, no port is published, and every key is made
# for the run and thrown away with it.
#
# EXIT CODES
#   0  every case passed
#   1  something does not build, the node did not start, or a case failed
#   3  there is no container engine here: nothing was observed
#
# USAGE
#   Scripts/test-nodelink.sh             everything
#   Scripts/test-nodelink.sh <filter>    the cases whose name matches
#
# ENVIRONMENT
#   LAMPBOARD_NODELINK_CACHE  where the copy, the build and the keys live
#                             (default ~/.cache/lampboard/nodelink-gate)
#   LAMPBOARD_NODELINK_NAME   prefix of the containers and the network
#                             (default lampboard-nodelink-<pid>)
#   LAMPBOARD_NODELINK_NODE   the node container's name (default <prefix>-node)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The same toolchain as Scripts/test-linux.sh, by digest.
BASE="swift:6.4@sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f"
CACHE="${LAMPBOARD_NODELINK_CACHE:-$HOME/.cache/lampboard/nodelink-gate}"
NAME="${LAMPBOARD_NODELINK_NAME:-lampboard-nodelink-$$}"
NODE="${LAMPBOARD_NODELINK_NODE:-$NAME-node}"
NET="$NAME-net"
LIMIT="${LAMPBOARD_NODELINK_LIMIT:-900}"

could_not_look() { printf '\033[33m⚠\033[0m %s\n' "$1"; exit 3; }
failed()         { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || could_not_look "no docker here: NodeLink was not tried over ssh"
docker info >/dev/null 2>&1 || could_not_look "docker is here but its daemon does not answer: NodeLink was not tried over ssh"

mkdir -p "$CACHE"
LOCK="$CACHE/run.lock"
for _ in $(seq 1 120); do
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

# One image for building, checking and being the node: the toolchain, and
# OpenSSH for the node's side. Rebuilt only when this list changes.
IMAGE="lampboard-nodelink-gate:$(printf '%s' "$BASE openssh-server openssh-client python3 procps" | shasum | cut -c1-12)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "▸ Preparing $IMAGE"
    docker build -q -t "$IMAGE" - > "$CACHE/image.log" 2>&1 <<EOF || could_not_look "the image could not be prepared (see $CACHE/image.log)"
FROM $BASE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        openssh-server openssh-client python3 procps && rm -rf /var/lib/apt/lists/*
EOF
fi

# The working tree as it is now, as Scripts/test-linux.sh copies it.
SRC="$CACHE/src"
rm -rf "$SRC" "$CACHE/keys"
mkdir -p "$SRC" "$CACHE/build" "$CACHE/home" "$CACHE/keys"
git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - | tar -xf - -C "$SRC" \
    || failed "the working tree could not be copied to $SRC"
[ -f "$CACHE/Package.resolved" ] && cp "$CACHE/Package.resolved" "$SRC/Package.resolved"

in_builder() {
    docker run --rm --name "$NAME-build" --user "$(id -u):$(id -g)" -e HOME=/tmp/h --cpus 8 --memory 8g \
        -v "$SRC:/src" -v "$CACHE/build:/src/.build" -v "$CACHE/home:/tmp/h" -v "$CACHE/keys:/keys" -w /src \
        "$IMAGE" "$@"
}

echo "▸ Building NodeLink and the reference node on Linux"
# The network only for this step: the packages come from their repositories.
if ! in_builder bash -c 'LAMPBOARD_STRICT=1 swift build --product NodeLinkCheck 2>&1 && LAMPBOARD_STRICT=1 swift build --product V1ReferenceNode 2>&1' > "$CACHE/build.log"; then
    sed 's/\x1b\[[0-9;]*m//g' "$CACHE/build.log" | grep -E '^/src/.*error:' | sort -u | head -20 | sed 's/^/    /'
    failed "NodeLink does not build on Linux (the full log is $CACHE/build.log)"
fi
cp "$SRC/Package.resolved" "$CACHE/Package.resolved" 2>/dev/null

# The phone's two keys, made for this run.
in_builder .build/debug/NodeLinkCheck keys /keys || failed "the keys could not be made"

# The node. The read key's line is the one `lampd devices add` will write: the
# forced command, `restrict`, and the marker. The action key may have a PTY and
# nothing else beyond its session.
READ_LINE="restrict,command=\"/opt/ref/V1ReferenceNode stdio --socket /tmp/v1ref/v1.sock --device check-phone --role read\" $(cat "$CACHE/keys/read.pub" | tr -d '\n') lampboard-device:check-phone:read"
ACTION_LINE="restrict,pty $(cat "$CACHE/keys/action.pub" | tr -d '\n') lampboard-device:check-phone:action"
printf '%s\n%s\n' "$READ_LINE" "$ACTION_LINE" > "$CACHE/keys/authorized_keys"

docker network create "$NET" >/dev/null || failed "the network $NET could not be made"
echo "▸ Starting the node ($NODE)"
docker run -d --name "$NODE" --network "$NET" --network-alias node \
    -v "$CACHE/build/debug/V1ReferenceNode:/opt/ref/V1ReferenceNode:ro" -v "$CACHE/keys:/keys:ro" \
    "$IMAGE" bash -c '
        set -e
        useradd -m -s /bin/bash demo
        usermod -p "*" demo   # no password, and not locked: sshd without PAM refuses a locked account
        install -d -m 700 -o demo -g demo /home/demo/.ssh
        install -m 600 -o demo -g demo /keys/authorized_keys /home/demo/.ssh/authorized_keys
        install -d -m 700 -o demo -g demo /tmp/v1ref
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key
        ssh-keygen -q -t ed25519 -N "" -f /tmp/wrong_host_key
        mkdir -p /run/sshd
        cat > /etc/ssh/sshd_config <<CONF
Port 2222
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
UsePAM no
AllowUsers demo
CONF
        runuser -u demo -- bash -c "/opt/ref/V1ReferenceNode serve --socket /tmp/v1ref/v1.sock 2> /tmp/v1ref/node.log &"
        python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"0.0.0.0\", 2223)); s.listen(8)
held=[]
while True:
    c,_=s.accept(); held.append(c)" &
        exec /usr/sbin/sshd -D -e
    ' > /dev/null || failed "the node did not start"

ready=0
for _ in $(seq 1 100); do
    if docker exec "$NODE" bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222 && [ -S /tmp/v1ref/v1.sock ]' 2>/dev/null; then ready=1; break; fi
    sleep 0.2
done
[ "$ready" = 1 ] || { docker logs "$NODE" 2>&1 | tail -5 | sed 's/^/    /'; failed "the node never listened"; }
docker exec "$NODE" cat /etc/ssh/ssh_host_ed25519_key.pub > "$CACHE/keys/host.pub" || failed "no host key"
docker exec "$NODE" cat /tmp/wrong_host_key.pub > "$CACHE/keys/wrong.pub" || failed "no second key"

echo
echo "▸ NodeLink over ssh, against the node"
ARGS=""
for a in "$@"; do ARGS="$ARGS $(printf '%q' "$a")"; done
# SIGPIPE ignored, as a service runs; every wait bounded.
docker run --rm --name "$NAME-check" --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp/h \
    -v "$CACHE/build:/src/.build:ro" -v "$CACHE/keys:/keys:ro" -w /src "$IMAGE" \
    bash -c "trap '' PIPE; timeout -k 5 $LIMIT .build/debug/NodeLinkCheck run --host node --port 2222 --user demo \
        --host-key /keys/host.pub --wrong-host-key /keys/wrong.pub --keys /keys \
        --reference /opt/ref/V1ReferenceNode --socket /tmp/v1ref/v1.sock --log /tmp/v1ref/node.log \
        --silent-port 2223$ARGS < /dev/null"
status=$?
case "$status" in
    0) printf '\033[32m✓\033[0m NodeLink carries v1 over ssh, and the keys are held to what they may do\n' ;;
    124|137) failed "the check was still running after $LIMIT seconds" ;;
    *) echo "    the node's sshd, last lines:"
       docker logs "$NODE" 2>&1 | tail -12 | sed 's/^/      /'
       failed "NodeLink over ssh failed (exit $status)" ;;
esac
