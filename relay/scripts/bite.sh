#!/bin/bash
#
# Every gate of the relay, seen failing.
#
# A test that has never been red proves nothing. For each gate this commits the
# violation the gate exists to catch, in a copy of relay/, runs the gate's
# tests, and expects them to fail. A mutation that leaves its tests green is a
# gate that does not bite, and this script exits 1.
#
# USAGE
#   relay/scripts/bite.sh           every bite
#   relay/scripts/bite.sh <name>…   those bites

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$RELAY/node_modules" ] || { echo "run npm ci in relay/ first" >&2; exit 3; }

# name | test file | file to mutate | perl substitution (s{...}{...}) ; more pairs after another |
BITES=(
  "capability-forged|test/capability.test.js|lib/capability.js|s{if \(equal\(expected, cap\)\) ok = true;}{ok = true;}"
  "capability-any-token|test/capability.test.js|lib/capability.js|s{lampboard-relay-cap(.*?)\\\$\{token\.toLowerCase\(\)\}}{lampboard-relay-cap\$1}"
  "envelope-readable|test/reads-nothing.test.js|lib/validate.js|s{if \(looksReadable\(bytes\)\) throw new Invalid\('envelope is readable', 422\);}{}"
  "token-in-logs|test/reads-nothing.test.js|lib/log.js|s{/\^\[0-9a-f\]\{8\}\\\$/}{/^[0-9a-f]+\$/}|lib/relay.js|s{note.tok = tokenTag\(token\);\n    note.env = environment;\n    note.kind = kind;}{note.tok = token;\n    note.env = environment;\n    note.kind = kind;}"
  "content-in-alert|test/reads-nothing.test.js|lib/payload.js|s{alert: \{ \.\.\.PLACEHOLDER \}}{alert: { ...PLACEHOLDER, body: push.envelope }}"
  "no-quota|test/quota.test.js|lib/quota.js|s{if \(count > limit\)}{if (false)}"
  "liveactivity-topic|test/payload.test.js|lib/payload.js|s{\.push-type\.liveactivity}{.liveactivity}"
  "no-stale-date|test/payload.test.js|lib/payload.js|s{'stale-date': stale,}{}"
  "background-urgent|test/payload.test.js|lib/validate.js|s{if \(forKind === 'background' && value !== 5\)}{if (false)}"
  "jwt-every-time|test/jwt.test.js|lib/jwt.js|s{seconds - held.iat < RENEW_AFTER}{seconds - held.iat < 0}"
  "envelope-size|test/vectors.test.js|lib/validate.js|s{export const ENVELOPE_MAX = 3 \* 1024;}{export const ENVELOPE_MAX = 4 * 1024;}"
)

missed=0
ran=0
for bite in "${BITES[@]}"; do
  IFS='|' read -r -a parts <<< "$bite"
  name="${parts[0]}"
  testfile="${parts[1]}"
  if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi
  work="$(mktemp -d)"
  cp -r "$RELAY/lib" "$RELAY/test" "$RELAY/package.json" "$work/"
  ln -s "$RELAY/node_modules" "$work/node_modules"
  applied=1
  for ((i = 2; i < ${#parts[@]}; i += 2)); do
    target="$work/${parts[$i]}"
    cp "$target" "$work/.before"
    perl -0pi -e "${parts[$((i + 1))]}" "$target"
    cmp -s "$target" "$work/.before" && applied=0
  done
  ran=$((ran + 1))
  if [ "$applied" -eq 0 ]; then
    printf '  \033[31m✗\033[0m %s: the mutation did not apply (the code moved; edit the bite)\n' "$name"
    missed=$((missed + 1))
  elif (cd "$work" && node --test "$testfile" >/dev/null 2>&1); then
    printf '  \033[31m✗\033[0m %s: %s stayed green\n' "$name" "$testfile"
    missed=$((missed + 1))
  else
    printf '  \033[32m✓\033[0m %s: %s went red\n' "$name" "$testfile"
  fi
  rm -rf "$work"
done

[ "$ran" -gt 0 ] || { echo "no bite ran" >&2; exit 1; }
echo
if [ "$missed" -gt 0 ]; then echo "$missed of $ran bites missed"; exit 1; fi
echo "all $ran bites bit"
