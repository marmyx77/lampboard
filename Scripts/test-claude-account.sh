#!/bin/sh
#
# Scripts/claude-account.sh in a home of its own (D187): what it links, what it
# never links, what it refuses, and that `check` turns red on a link Claude
# Code replaced with a file. Nothing outside a temporary folder is touched.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/claude-account.sh"
H="$(mktemp -d "${TMPDIR:-/tmp}/claude-account.XXXXXX")"
trap 'rm -rf "$H"' EXIT
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails + 1)); }
expect() { if eval "$2"; then ok "$1"; else no "$1"; fi; }
run() { HOME="$H" sh "$SCRIPT" "$@"; }

mkdir -p "$H/.claude/skills" "$H/.claude-mem"
echo '{"hooks":{}}' > "$H/.claude/settings.json"
echo 'secret' > "$H/.claude/.credentials.json"
echo '{"oauthAccount":{"emailAddress":"a@example.com"},"primaryApiKey":"k","mcpServers":{"m":{}},"hasCompletedOnboarding":true}' > "$H/.claude.json"

run add work > "$H/out" 2>&1
A="$H/.claude-work"
expect "add makes the folder with its marker" '[ -f "$A/.lampboard-account" ]'
expect "settings, skills and history are links to ~/.claude" \
    '[ "$(readlink "$A/settings.json")" = "$H/.claude/settings.json" ] && [ -L "$A/skills" ] && [ -L "$A/projects" ]'
expect "history and sessions are shared even when ~/.claude had none yet" \
    '[ -d "$H/.claude/projects" ] && [ -L "$A/projects" ] && [ -d "$H/.claude/sessions" ] && [ -L "$A/sessions" ]'
expect "the login is never linked" '[ ! -e "$A/.credentials.json" ] && [ ! -L "$A/.credentials.json" ]'
expect ".claude.json is copied without the login" \
    'grep -q mcpServers "$A/.claude.json" && grep -q hasCompletedOnboarding "$A/.claude.json" && ! grep -q -e oauthAccount -e primaryApiKey "$A/.claude.json"'
expect ".claude.json is the account's own file, private" '[ ! -L "$A/.claude.json" ] && [ "$(ls -l "$A/.claude.json" | cut -c1-10)" = "-rw-------" ]'
expect "check is green on a fresh account" 'run check work > /dev/null 2>&1'
expect "list names it, and not ~/.claude-mem" '[ "$(run list)" = "work" ]'

mkdir -p "$H/.claude/agents"
expect "check sees a new entry of ~/.claude not linked yet" '! run check work > /dev/null 2>&1'
run add work > /dev/null 2>&1
expect "add again links what is new, and check is green" '[ -L "$A/agents" ] && run check work > /dev/null 2>&1'

# The bite: Claude Code writing settings.json by rename replaces the link.
rm "$A/settings.json"; echo '{}' > "$A/settings.json"
expect "check turns red on a link replaced by a file" '! run check work > /dev/null 2>&1'
expect "and names it" 'run check work 2>&1 | grep -q "its own:   settings.json"'

# The bite for the shared ones: a history of its own is red, other files of its own are not.
rm "$A/settings.json"; run add work > /dev/null 2>&1
echo '{}' > "$A/remote-settings.json"
expect "a file only the account has is no failure" 'run check work > /dev/null 2>&1'
rm "$A/projects"; mkdir "$A/projects"
expect "a history of its own is red" '! run check work > /dev/null 2>&1'
rm -r "$A/projects"; run add work > /dev/null 2>&1

expect "a folder the script did not make is refused" '! run add mem > /dev/null 2>&1 && [ ! -e "$H/.claude-mem/.lampboard-account" ]'
for bad in Work -x x- "a b" '../x' ''; do
    expect "a bad name is refused: '$bad'" '! run add "$bad" > /dev/null 2>&1'
done
expect "nothing was made for a bad name" '[ "$(ls -A "$H" | grep -c "^.claude-")" = 2 ]'

echo; [ "$fails" = 0 ] && echo "claude-account: all passed" || { echo "claude-account: $fails failed"; exit 1; }
