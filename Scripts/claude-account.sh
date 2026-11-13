#!/bin/sh
#
# Another Claude Code account on this machine, for LampBoard to start sessions in (D187).
#
# Claude Code keeps accounts apart by configuration folder: CLAUDE_CONFIG_DIR
# names one, and each has its own login. A bare new folder would also have its
# own settings, hooks, skills and history, and LampBoard's lamps would stay off
# in it. So the folder this makes, ~/.claude-<name>, links every entry of
# ~/.claude except the login: one set of settings and one history, two logins.
#
#   Scripts/claude-account.sh add <name>    make it (again: links what is new in ~/.claude)
#   Scripts/claude-account.sh check <name>  say what is not linked
#   Scripts/claude-account.sh list          the accounts here
#
# A name is lowercase letters, digits and dashes inside, at most forty.
# Nothing is ever deleted. Then sign in once, in a terminal:
#
#   CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" claude auth login

set -u

BASE="$HOME/.claude"
MARKER=".lampboard-account"
# Per account, never linked: the login (Linux, and macOS when the Keychain
# refuses it) and the marker. ~/.claude.json is outside ~/.claude, so the
# account's own .claude.json is never a link either.
OWN=".credentials.json $MARKER .claude.json"
# Shared even before ~/.claude has them: the history and the running sessions,
# which LampBoard reads in ~/.claude. Measured on Claude Code 2.1.303: a folder
# missing them gets its own, and its conversations go where nothing looks.
SHARED="projects sessions"

die() { echo "claude-account: $*" >&2; exit 1; }

valid() {
    # Spelled out: in some locales [a-z] takes capitals too, and on a Mac
    # .claude-Work is the same folder as .claude-work.
    case "$1" in
        ""|-*|*-|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    esac
    [ "${#1}" -le 40 ]
}

own() { for o in $OWN; do [ "$1" = "$o" ] && return 0; done; return 1; }

# Every entry of ~/.claude, dotfiles too, one per line.
entries() { ls -A "$BASE"; }

link_all() {
    dir=$1; made=0
    for e in $SHARED; do mkdir -p "$BASE/$e" || die "could not make $BASE/$e"; done
    for e in $(entries); do
        own "$e" && continue
        [ -e "$dir/$e" ] || [ -L "$dir/$e" ] && continue
        ln -s "$BASE/$e" "$dir/$e" || die "could not link $e"
        made=$((made + 1))
    done
    echo "$made linked"
}

# ~/.claude.json without the default account's login: the MCP servers, the
# trusted folders and onboarding stay, the account is the new folder's own.
seed_config() {
    dir=$1
    [ -e "$dir/.claude.json" ] && return 0
    [ -f "$HOME/.claude.json" ] || return 0
    command -v python3 >/dev/null 2>&1 || { echo "no python3: $dir/.claude.json starts empty (onboarding and MCP servers again)"; return 0; }
    (umask 077; python3 -I - "$HOME/.claude.json" "$dir/.claude.json" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    config = json.load(f)
for key in ("oauthAccount", "primaryApiKey"):
    config.pop(key, None)
with open(sys.argv[2], "w") as f:
    json.dump(config, f, indent=2)
EOF
    ) || die "could not write $dir/.claude.json"
    echo "settings from ~/.claude.json copied, without its login"
}

add() {
    name=$1; dir="$HOME/.claude-$name"
    valid "$name" || die "'$name' is not a name: lowercase letters, digits, dashes inside, at most forty"
    [ -d "$BASE" ] || die "there is no $BASE to share"
    if [ -e "$dir" ] && [ ! -f "$dir/$MARKER" ]; then
        die "$dir exists and is not an account this script made: nothing was changed"
    fi
    mkdir -p "$dir" && chmod 700 "$dir" || die "could not make $dir"
    printf '%s\n' "$name" > "$dir/$MARKER"
    link_all "$dir"
    seed_config "$dir"
    echo "account $name: $dir"
    echo "sign in once:  CLAUDE_CONFIG_DIR=\"\$HOME/.claude-$name\" claude auth login"
}

check() {
    name=$1; dir="$HOME/.claude-$name"
    valid "$name" && [ -f "$dir/$MARKER" ] || die "there is no account $name here"
    bad=0
    for e in $(entries); do
        own "$e" && continue
        if [ -L "$dir/$e" ]; then
            [ "$(readlink "$dir/$e")" = "$BASE/$e" ] && continue
            echo "elsewhere: $e -> $(readlink "$dir/$e")"
        elif [ -e "$dir/$e" ]; then
            echo "its own:   $e (Claude Code wrote it in place of the link)"
        else
            echo "missing:   $e (run add $name again)"
        fi
        bad=$((bad + 1))
    done
    # What the account has that ~/.claude has not: its own by right (the
    # managed settings of its organization, its backups), but never the shared ones.
    for p in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        e=${p##*/}
        own "$e" && continue
        [ -e "$BASE/$e" ] || [ -L "$BASE/$e" ] && continue
        case " $SHARED " in
            *" $e "*) echo "its own:   $e (shared by every account: move its content to ~/.claude/$e)"; bad=$((bad + 1)) ;;
            *) echo "only here: $e" ;;
        esac
    done
    [ "$bad" = 0 ] && echo "account $name: everything but the login is ~/.claude's" || exit 1
}

list() {
    for d in "$HOME"/.claude-*; do
        [ -f "$d/$MARKER" ] && echo "${d##*/.claude-}"
    done
    return 0
}

case "${1:-}" in
    add) [ $# = 2 ] || die "usage: add <name>"; add "$2" ;;
    check) [ $# = 2 ] || die "usage: check <name>"; check "$2" ;;
    list) list ;;
    *) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
