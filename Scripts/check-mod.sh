#!/bin/bash
#
# The companion mod as Claude Code itself reads it.
#
# Claude Code checks a mod's module before it runs any of it, and one rule broken
# anywhere drops the whole module without a word in the session: on 5 October a
# variable named like a function the module hands `$` to, and before that a
# streaming hook written as an ordinary `async` function, each left every session
# without the mod. `claude plugin validate` names the cause in one sentence, so
# the gate asks it. A machine without `claude` says so and checks nothing.

set -uo pipefail
cd "$(dirname "$0")/.."

CLAUDE="$(command -v claude || true)"
[ -n "$CLAUDE" ] || [ ! -x "$HOME/.local/bin/claude" ] || CLAUDE="$HOME/.local/bin/claude"
if [ -z "$CLAUDE" ]; then
    echo "  no claude on this machine: the mod is not validated here"
    exit 0
fi

# A minute at most: the gate waits on it, and a hung validation is a red, not a wait.
out="$(perl -e 'alarm 60; exec @ARGV' "$CLAUDE" plugin validate mod 2>&1)"
status=$?
if [ "$status" -ne 0 ] || ! grep -q "Validation passed" <<<"$out"; then
    grep -E "❯|✘" <<<"$out" | sed 's/^/  /'
    printf '  \033[31m✗\033[0m the mod does not load: Claude Code would drop it whole\n'
    exit 1
fi
printf '  \033[32m✓\033[0m the mod loads as Claude Code reads it\n'

# The mod's own tests (`mod/tests`): the Hub's signed commands are run only
# when the panel's key signed them for this session, now, once (D152).
out="$(cd mod && perl -e 'alarm 120; exec @ARGV' "$CLAUDE" plugin test 2>&1)"
status=$?
if [ "$status" -ne 0 ] || ! grep -q " 0 fail" <<<"$out"; then
    grep -E "\(fail\)|Error" <<<"$out" | head -10 | sed 's/^/  /'
    printf "  \033[31m✗\033[0m the mod's tests fail\n"
    exit 1
fi
printf "  \033[32m✓\033[0m the mod's tests pass (%s)\n" "$(grep -oE '[0-9]+ pass' <<<"$out" | head -1)"
