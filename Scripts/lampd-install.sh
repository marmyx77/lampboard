#!/bin/bash
#
# Installs lampd for this account on this Linux machine, from this checkout.
#
# WHY THIS EXISTS
# What runs on a machine must come from a repository (ADR-59 of the node's
# register): a unit edited by hand and not brought back is how a timer ran at
# one time while its repository said another for a month. So the binary, the
# units and the contract's runner are installed only from here, each copy
# marked with the commit it came from, and nothing is edited where it lands.
#
# What it does (ADR-65 points 1, 2, 11):
#   - the static binary (Scripts/lampd-build.sh, or --binary) into
#     ~/.local/lib/lampd/<version>-<commit>/lampd, and the link
#     ~/.local/bin/lampd, which the unit and the phones' lines run;
#   - the contract's runner and what it reads into ~/.local/lib/lampd/contract/;
#   - deploy/lampd/*.service and *.timer into ~/.config/systemd/user/, each with
#     a first line naming its commit; a unit of the same name that is not one of
#     these copies is refused, never overwritten;
#   - deploy/tmux/lampboard.conf into ~/.config/lampd/tmux.conf (Q10, E14),
#     marked like the units; the person's ~/.tmux.conf reads it with a line of
#     their own, which this script prints and never writes;
#   - daemon-reload, then lampd.service and lampd-contract.timer enabled and
#     started, unless --no-start.
# It binds no port, writes nothing in ~/.claude, touches no line of
# authorized_keys and needs no sudo. Pairing a phone is `lampd devices add`,
# the owner's own gesture.
#
# USAGE
#   Scripts/lampd-install.sh [--binary <path>] [--no-start] [--dry-run]
#   Scripts/lampd-install.sh --uninstall      units, binaries and the phones'
#                                             lines go; state and configuration stay

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failed() { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }
say()    { printf '  %s\n' "$1"; }

BINARY=""
START=1
DRY=0
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --no-start) START=0; shift ;;
        --dry-run) DRY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "usage: Scripts/lampd-install.sh [--binary <path>] [--no-start] [--dry-run] | --uninstall" >&2; exit 2 ;;
    esac
done

[ "$(uname -s)" = Linux ] || failed "lampd is installed on Linux"
[ "$(id -u)" != 0 ] || failed "lampd is installed for a person's account, not root"
command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 \
    || failed "no systemd --user manager answers for this account"

LIB="$HOME/.local/lib/lampd"
BIN_LINK="$HOME/.local/bin/lampd"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MARK="# Installed from clawd-light"
run() { if [ "$DRY" = 1 ]; then say "would run: $*"; else "$@"; fi; }

ours() { [ -f "$1" ] && head -1 "$1" | grep -q "^$MARK"; }

if [ "$UNINSTALL" = 1 ]; then
    echo "▸ Removing lampd"
    for unit in lampd-contract.timer lampd.service; do
        run systemctl --user disable --now "$unit" 2>/dev/null
    done
    if [ -x "$BIN_LINK" ]; then
        for device in $("$BIN_LINK" devices list 2>/dev/null | awk '$2 ~ /^\[/ {print $1}'); do
            run "$BIN_LINK" devices revoke "$device"
        done
    fi
    for file in deploy/lampd/*.service deploy/lampd/*.timer; do
        target="$UNITS/$(basename "$file")"
        if ours "$target"; then run rm -f "$target"; elif [ -e "$target" ]; then say "left $target: not one of these copies"; fi
    done
    run systemctl --user daemon-reload
    run rm -f "$BIN_LINK"
    run rm -rf "$LIB"
    say "kept ~/.local/state/lampd and ~/.config/lampd: remove them by hand if wanted"
    printf '\033[32m✓\033[0m lampd removed\n'
    exit 0
fi

COMMIT="$(git rev-parse --short HEAD)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || COMMIT="$COMMIT-dirty"

# Every unit that would be replaced must be one of these copies.
for file in deploy/lampd/*.service deploy/lampd/*.timer; do
    target="$UNITS/$(basename "$file")"
    if [ -e "$target" ] && ! ours "$target"; then
        failed "$target exists and is not a copy this script made: nothing was installed"
    fi
done

if [ -z "$BINARY" ]; then
    echo "▸ Building lampd"
    Scripts/lampd-build.sh > /tmp/lampd-install-build.$$.log 2>&1 || { tail -5 /tmp/lampd-install-build.$$.log; failed "lampd does not build"; }
    BINARY="$(tail -1 /tmp/lampd-install-build.$$.log)"
    rm -f /tmp/lampd-install-build.$$.log
fi
[ -x "$BINARY" ] || failed "$BINARY is not an executable"
VERSION="$("$BINARY" version | awk '{print $2}')"
[ -n "$VERSION" ] || failed "$BINARY does not say its version"
DEST="$LIB/$VERSION-$COMMIT"

echo "▸ Installing lampd $VERSION from $COMMIT"
run mkdir -p "$DEST" "$HOME/.local/bin" "$UNITS"
run install -m 0755 "$BINARY" "$DEST/lampd"
run ln -sfn "$DEST/lampd" "$BIN_LINK.new"
run mv -T "$BIN_LINK.new" "$BIN_LINK"
say "binary: $DEST/lampd, linked from $BIN_LINK"

# The contract's runner, and what it reads, replaced whole.
STAGE="$LIB/contract.new"
run rm -rf "$STAGE"
run mkdir -p "$STAGE/Scripts"
run cp Scripts/check-contract.sh Scripts/measure-compaction.py "$STAGE/Scripts/"
run cp -r Contracts "$STAGE/Contracts"
run install -m 0755 deploy/lampd/lampd-contract.sh "$STAGE/lampd-contract.sh"
run rm -rf "$LIB/contract"
run mv "$STAGE" "$LIB/contract"
say "contract: $LIB/contract"

for file in deploy/lampd/*.service deploy/lampd/*.timer; do
    target="$UNITS/$(basename "$file")"
    if [ "$DRY" = 1 ]; then say "would write $target"; continue; fi
    { echo "$MARK $COMMIT ($file) by Scripts/lampd-install.sh: edit the repository, not this copy."; cat "$file"; } > "$target.new"
    mv "$target.new" "$target"
    say "unit: $target"
done
run systemctl --user daemon-reload

# The tmux options a phone's sessions want (Q10, E14), as a file the person's
# ~/.tmux.conf reads with one line of their own: that file is never edited here.
TMUX_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/lampd/tmux.conf"
if [ -e "$TMUX_CONF" ] && ! ours "$TMUX_CONF"; then
    say "left $TMUX_CONF: not a copy this script made"
elif [ "$DRY" = 1 ]; then
    say "would write $TMUX_CONF"
else
    mkdir -p "$(dirname "$TMUX_CONF")"
    { echo "$MARK $COMMIT (deploy/tmux/lampboard.conf) by Scripts/lampd-install.sh: edit the repository, not this copy."
      cat deploy/tmux/lampboard.conf; } > "$TMUX_CONF.new"
    mv "$TMUX_CONF.new" "$TMUX_CONF"
    say "tmux options: $TMUX_CONF"
fi
if ! grep -qs 'lampd/tmux.conf' "$HOME/.tmux.conf"; then
    say "your ~/.tmux.conf does not read them yet; the line to add there, once:"
    say "    source-file -q ~/.config/lampd/tmux.conf"
fi

# Older versions beyond the last three go.
if [ "$DRY" = 0 ]; then
    ls -1dt "$LIB"/*-* 2>/dev/null | grep -v '/contract' | tail -n +4 | while read -r old; do
        [ "$old" != "$DEST" ] && rm -rf "$old" && say "removed $old"
    done
fi

if [ "$START" = 1 ]; then
    run systemctl --user enable lampd.service lampd-contract.timer
    run systemctl --user restart lampd.service
    run systemctl --user start lampd-contract.timer
    if [ "$DRY" = 0 ]; then
        for _ in $(seq 1 50); do "$BIN_LINK" status > /dev/null 2>&1 && break; sleep 0.2; done
        "$BIN_LINK" status > /dev/null 2>&1 || failed "lampd.service started but lampd does not answer: journalctl --user -u lampd"
        echo
        "$BIN_LINK" doctor
    fi
fi
if [ "$DRY" = 1 ]; then
    printf '\nnothing was changed: lampd %s from %s would be installed as above\n' "$VERSION" "$COMMIT"
else
    printf '\n\033[32m✓\033[0m lampd %s installed from %s\n' "$VERSION" "$COMMIT"
fi
