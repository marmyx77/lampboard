#!/bin/bash
#
# Breaks this repository on purpose, and fails if the checks do not notice.
#
# WHY THIS EXISTS
# A check nobody has ever seen fail is not a check. `Scripts/check-docs.sh` had
# eight of them and one had never, in its whole life, examined a single file: the
# guard against leaking a real home directory into a public repository was
# written with a regular-expression lookahead that `/usr/bin/grep -E` rejects, so
# every run swallowed the error and printed a tick. It was green for weeks, and
# there was a real name in `Contracts/golden/hooks.jsonl` the whole time.
#
# Nothing about that failure was visible from the outside. The only way to tell a
# working guard from a broken one is to commit the violation it claims to catch
# and watch what happens. That is what this script does, once per guard.
#
# HOW IT WORKS
# Every attack copies the files it is about to damage, applies a mutation, runs
# the real gate, and restores what it touched — pass or fail, including on
# Ctrl-C. Three things have to hold for a bite to count:
#
#   1. the mutation actually changed something. A mutation that no longer applies
#      is a bite that quietly stopped testing anything, so it is a failure here;
#   2. the gate exited non-zero;
#   3. it said why, in the words this attack expects. "Something went red" is not
#      a proof — the gate could have tripped over an unrelated problem.
#
# WHAT IT DOES NOT DO
# It does not commit, push, or fix anything, and it refuses to leave the tree
# modified. If it is interrupted at the wrong moment, `git status` is the check.
#
# USAGE
#   ./Scripts/bite.sh            everything
#   ./Scripts/bite.sh --docs     only the documentation gates (a few seconds)
#   ./Scripts/bite.sh --swift    only the test instrument (needs a build)

set -uo pipefail   # deliberately not -e: half of what runs here is meant to fail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WHAT="${1:-all}"
WORK="$(mktemp -d)"
PROTECTED=()

# What the tree looked like before any damage. Compared again at the end: this
# script must give back exactly what it borrowed.
TREE_BEFORE="$(git status --porcelain)"

BITES=0
BLUNT=0

bit()   { BITES=$((BITES+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
blunt() { BLUNT=$((BLUNT+1)); printf '  \033[31m✗\033[0m %s\n' "$1"
          printf '      \033[31m%s\033[0m\n' "$2"; }

# A gate in check-docs.sh. The titles have to match its `head_` lines exactly:
# check-docs.sh compares the two lists and reports any gate with no bite, so a
# rule cannot be added here or there without the other noticing.
gate()    { printf '\n\033[1m%s\033[0m\n' "$1"; }
# Everything that is proven here but is not a documentation gate.
chapter() { printf '\n\033[1m%s\033[0m\n' "$1"; }

protect() {
    # Adds to the list rather than replacing it. Written the other way, two
    # `protect` lines before one `attack` left only the last file restored, and
    # the mutation walked out of the run with the tree still damaged — found
    # exactly that way. `restore` empties the list after every attack, so
    # nothing accumulates between them.
    PROTECTED+=("$@")
    local file
    for file in "$@"; do
        mkdir -p "$WORK/$(dirname "$file")"
        cp "$file" "$WORK/$file"
    done
}

restore() {
    local file
    for file in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
        [ -f "$WORK/$file" ] && cp "$WORK/$file" "$file"
    done
    PROTECTED=()
}

trap 'restore; rm -rf "$WORK"' EXIT INT TERM

# What the protected files look like right now, so that a mutation which no
# longer applies is caught instead of silently proving nothing.
fingerprint() {
    local file
    for file in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
        shasum "$file" 2>/dev/null || echo "absent $file"
    done | shasum | cut -d' ' -f1
}

# Applies the mutation on stdin, runs the gate, and demands it turns red for the
# stated reason.
#   attack <description> <expected fragment of the gate's output>
attack() {
    local description="$1" expected="$2"
    local before after status log="$WORK/gate.log"

    before="$(fingerprint)"
    if ! python3 - ; then
        blunt "$description" "the mutation itself failed to run"
        restore
        return
    fi
    after="$(fingerprint)"

    if [ "$before" = "$after" ]; then
        blunt "$description" "the mutation no longer applies — this bite is stale, and has been proving nothing"
        restore
        return
    fi

    ./Scripts/check-docs.sh > "$log" 2>&1
    status=$?
    restore

    if [ "$status" -eq 0 ]; then
        blunt "$description" "check-docs.sh stayed green with the violation in place"
    elif ! grep -Fq -- "$expected" "$log"; then
        blunt "$description" "it went red, but never said “${expected}” — it tripped over something else"
    else
        bit "$description"
    fi
}

# The same, for the companion mod: Claude Code's own reading of it must go red.
# Where there is no claude to ask it is skipped, and said.
#   attack_mod <description> <expected fragment>
attack_mod() {
    local description="$1" expected="$2" before status log="$WORK/mod.log"
    if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
        cat > /dev/null
        restore
        printf '  no claude here: "%s" is not attacked on this machine\n' "$description"
        return
    fi
    before="$(fingerprint)"
    if ! python3 - ; then blunt "$description" "the mutation itself failed to run"; restore; return; fi
    if [ "$before" = "$(fingerprint)" ]; then
        blunt "$description" "the mutation no longer applies — this bite is stale, and has been proving nothing"
        restore
        return
    fi
    ./Scripts/check-mod.sh > "$log" 2>&1
    status=$?
    restore
    if [ "$status" -eq 0 ]; then
        blunt "$description" "check-mod.sh stayed green with the module broken"
    elif ! grep -Fq -- "$expected" "$log"; then
        blunt "$description" "it went red, but never said “${expected}”"
    else
        bit "$description"
    fi
}

# The same, for a mutation to the Swift sources: builds, runs the domain suite,
# and demands a specific exit code.
#   attack_swift <description> <expected fragment> <expected exit code>
attack_swift() {
    local description="$1" expected="$2" wanted="$3"
    local before after status log="$WORK/suite.log"

    before="$(fingerprint)"
    if ! python3 - ; then
        blunt "$description" "the mutation itself failed to run"
        restore
        return
    fi
    after="$(fingerprint)"

    if [ "$before" = "$after" ]; then
        blunt "$description" "the mutation no longer applies — this bite is stale"
        restore
        return
    fi

    if ! swift build > "$WORK/build.log" 2>&1; then
        blunt "$description" "the mutation does not compile, so it proves nothing"
        restore
        return
    fi

    .build/debug/LampBoardTests > "$log" 2>&1
    status=$?
    restore

    if [ "$status" -ne "$wanted" ]; then
        blunt "$description" "the suite exited $status, expected $wanted"
    elif ! grep -Fq -- "$expected" "$log"; then
        blunt "$description" "it exited $status, but never said “${expected}”"
    else
        bit "$description"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--docs" ]; then

gate "Figures in the code map"

protect docs/05-code-map.md
attack "a per-target line count that drifted" "says 9,999 lines" <<'PY'
import re
p = "docs/05-code-map.md"
# Whatever the number is today. A mutation that names it would need editing
# every time the figure legitimately moves, and a bite nobody maintains is a
# bite that quietly stops proving anything.
s = re.sub(r"(LampBoardCore/\s+)[\d,]+( lines)", r"\g<1>9,999\g<2>", open(p).read(), count=1)
open(p, "w").write(s)
PY

protect docs/05-code-map.md
attack "the table reworded so the search matches nothing" "expected at least 5 per-target rows" <<'PY'
p = "docs/05-code-map.md"
s = open(p).read().replace(" lines · ", " lines, ")
open(p, "w").write(s)
PY

gate "Nothing in the repository is written in Italian"

protect docs/07-traps.md
attack "a sentence in the language the project is thought in" "reads as Italian" <<'PY'
# The rule is inflexible, so it gets a gate; and a gate nobody has watched turn
# red is a rule nobody is keeping.
#
# The sentence is assembled from the gate's own list rather than written out.
# Twice for the price of once: this file stays English, so it does not trip the
# very check it is proving, and an attack built from the list cannot drift out of
# step with what the list actually holds.
words = [
    line.strip() for line in open("Scripts/italian-words.txt", encoding="utf-8")
    if line.strip() and not line.startswith("#")
]
p = "docs/07-traps.md"
s = open(p).read()
open(p, "w").write(s + "\n\n" + " ".join(words[:6]) + ".\n")
PY

protect Scripts/italian-words.txt
attack "the word list emptied, so the check would pass on anything" "would pass on anything" <<'PY'
# The list is the one file the gate skips, which makes it the one place where
# blinding the gate costs nothing and shows nowhere. An empty list is not a
# repository free of Italian; it is a check that has stopped asking.
p = "Scripts/italian-words.txt"
open(p, "w").write("# emptied\n")
PY

gate "Links between documents"

protect README.md
attack "a link that points nowhere" "no such file" <<'PY'
p = "README.md"
s = open(p).read().replace("(docs/07-traps.md)", "(docs/07-trapdoors.md)")
open(p, "w").write(s)
PY

protect Contracts/assumptions.md
attack "a guarded document that quietly disappeared" "no longer exists" <<'PY'
import os
os.remove("Contracts/assumptions.md")
PY

gate "Figures stated outside the code map"

protect docs/08-gates.md
attack "the register of the gates, stating a suite nobody runs" "says 999 cases" <<'PY'
# The blind spot a third audit found: this file said 630 domain cases and 88
# end-to-end while the suites ran 674 and 95, and the check that compares
# figures passed and printed that they agreed everywhere they are stated. The
# document describing what is guarded was the one thing not guarded.
import re
p = "docs/08-gates.md"
s = re.sub(r"\(\d+ cases\)", "(999 cases)", open(p).read(), count=1)
open(p, "w").write(s)
PY

protect README.md
attack "a test count that drifted outside the code map" "says 999 cases" <<'PY'
import re
p = "README.md"
s = re.sub(r"\d+ domain tests", "999 domain tests", open(p).read(), count=1)
open(p, "w").write(s)
PY

protect README.md
attack "the sentence reworded so the count is no longer stated" "expected 1 statement(s)" <<'PY'
import re
p = "README.md"
s = re.sub(r"\d+ domain tests", "the full domain suite", open(p).read())
open(p, "w").write(s)
PY

gate "The status table says how the project stands now"

protect WORKLOG.md
attack "a figure in the status table that no longer holds" "the table says 242 domain tests" <<'PY'
import re
p = "WORKLOG.md"
s = re.sub(r"(\| Domain tests \| \*\*)\d+", r"\g<1>242", open(p).read(), count=1)
open(p, "w").write(s)
PY

protect WORKLOG.md
attack "the status table renamed out of reach" "no status table any more" <<'PY'
p = "WORKLOG.md"
s = open(p).read().replace("## How the project stands now", "## Where things stand")
open(p, "w").write(s)
PY

gate "No personal paths or private addresses in tracked files"

protect docs/07-traps.md
attack "a real home directory committed to the tree" "notarealperson" <<'PY'
p = "docs/07-traps.md"
# Assembled rather than written out: this file is scanned by the very guard it
# is testing, and the alternative — an exemption for it — is exactly the kind of
# list that grows quietly until it is hiding a real leak.
planted = "/Users/" + "notarealperson/Development/thing"
s = open(p).read() + f"\n<!-- planted by bite.sh: {planted} -->\n"
open(p, "w").write(s)
PY

protect docs/07-traps.md
attack "a private VPN address committed to the tree" "101.5.7" <<'PY'
p = "docs/07-traps.md"
planted = "100." + "101.5.7"
s = open(p).read() + f"\n<!-- planted by bite.sh: {planted} -->\n"
open(p, "w").write(s)
PY

# The one that matters most: not "does the guard catch a violation", but "does
# the guard notice that it has stopped being able to catch anything". This is
# exactly how it failed for real, and no amount of planting fake leaks would
# have found it.
protect Scripts/check-docs.sh
attack "the guard blinded, and announcing it" "THE GUARD ITSELF IS BROKEN" <<'PY'
p = "Scripts/check-docs.sh"
s = open(p).read().replace(
    'HOME = re.compile(r"/(?:Users|home)/([A-Za-z0-9][A-Za-z0-9._-]*)")',
    'HOME = re.compile(r"/(?:Users|home)/(nobody-is-called-this)")',
)
open(p, "w").write(s)
PY

gate "The contract knows which events we register"

protect Contracts/required-fields.json
attack "an event the code registers and the contract forgot" "absent from the spec" <<'PY'
p = "Contracts/required-fields.json"
s = open(p).read().replace('"PostToolUse"', '"PostToolUsage"')
open(p, "w").write(s)
PY

protect docs/02-claude-code.md
attack "prose left behind on the old count" 'events", there are' <<'PY'
import re
p = "docs/02-claude-code.md"
text = open(p).read()
spelled = re.search(r"The (\w+) events lampboard registers", text).group(1)
# Any word but the right one; which wrong word it is does not matter.
wrong = "eight" if spelled != "eight" else "seven"
s = text.replace(f"The {spelled} events lampboard registers", f"The {wrong} events lampboard registers")
open(p, "w").write(s)
PY

protect docs/02-claude-code.md docs/05-code-map.md
attack "every statement of the count reworded away" "no document states how many events are registered" <<'PY'
for p, old, new in [
    ("docs/02-claude-code.md", "events lampboard registers", "hook events wired up here"),
    ("docs/05-code-map.md", "events registered by default", "hooks wired up by default"),
]:
    s = open(p).read().replace(old, new)
    open(p, "w").write(s)
PY

gate "Test suites are registered"

protect Sources/LampBoardTests/main.swift
attack "a suite that exists and is never run" "is defined but never registered" <<'PY'
p = "Sources/LampBoardTests/main.swift"
s = open(p).read().replace("    PathNormalizerSuite.suite,\n", "")
open(p, "w").write(s)
PY

gate "Every file is on the map"

protect docs/05-code-map.md
attack "a shipped file that the map stopped mentioning" "is in the tree and not on the map" <<'PY'
p = "docs/05-code-map.md"
s = open(p).read()
# The row that names it, and the name wherever else it appears: the check accepts
# either the file name or the type, so a bite has to remove both or prove nothing.
s = s.replace("| `FinderReveal.swift` | 28 | opens a Finder window **inside** the folder, not on it (D33) |\n", "")
s = s.replace("FinderReveal", "TheFolderOpener")
open(p, "w").write(s)
PY

protect docs/05-code-map.md
attack "a script nobody wrote a line about" "is not in the map's script table" <<'PY'
p = "docs/05-code-map.md"
s = open(p).read().replace("`Scripts/measure-compaction.py`", "`Scripts/measure-compaction-py`")
open(p, "w").write(s)
PY

protect docs/05-code-map.md
attack "vendored code the map stopped mentioning" "is vendored and not on the map" <<'PY'
p = "docs/05-code-map.md"
s = open(p).read().replace("Vendor/SwiftTerm", "Vendor/SomeTerminal")
open(p, "w").write(s)
PY

gate "The mutation count in the documents is the one bite.sh runs"

protect docs/08-gates.md
attack "a mutation count that drifted out of step" "mutations, bite.sh commits" <<'PY'
import re
# The number is read and replaced with a different one, never named. A bite that
# spelled out today's count would have to be edited the next time a gate is
# added, and a bite that needs maintaining is a bite that gets deleted.
p = "docs/08-gates.md"
s = open(p).read()
said = re.search(r"commits ([a-z]+(?:-[a-z]+)?) violations", s).group(1)
other = "ninety-nine" if said != "ninety-nine" else "ninety-eight"
open(p, "w").write(s.replace(f"commits {said} violations", f"commits {other} violations", 1))
PY

protect docs/08-gates.md docs/06-working-here.md docs/05-code-map.md
attack "every sentence stating the count reworded away" "no document states how many mutations" <<'PY'
import re
# Blinding the check costs nothing and shows nowhere. This repository has already
# had one guard that was green because it could not run.
for p in ("docs/08-gates.md", "docs/06-working-here.md", "docs/05-code-map.md"):
    s = open(p).read()
    s = re.sub(r"commits ([a-z]+(?:-[a-z]+)?) violations", r"commits violations", s)
    s = re.sub(r"demands ([a-z]+(?:-[a-z]+)?) catches", r"demands catches", s)
    open(p, "w").write(s)
PY

gate "Every gate here can be shown to bite"

protect Scripts/check-docs.sh
attack "a gate added without anything that proves it works" "has no mutation in bite.sh" <<'PY'
p = "Scripts/check-docs.sh"
s = open(p).read().replace(
    'printf \'\\n%s\\n\' "────',
    'head_ "A gate nobody has ever proven"\nprintf \'\\n%s\\n\' "────',
    1,
)
open(p, "w").write(s)
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--swift" ]; then

chapter "The test instrument"

# The attack that worked. Neutralising one guard clause in the assertion library
# made 497 tests report success while verifying nothing at all — and there was
# nothing in the project that would have said so.
protect Sources/TestKit/Assertions.swift
attack_swift "an assertion that has stopped asserting" "THE INSTRUMENT IS BLUNT" 70 <<'PY'
p = "Sources/TestKit/Assertions.swift"
s = open(p).read().replace(
    "        guard !condition else { return }\n",
    "        if true { return }\n        guard !condition else { return }\n",
    1,
)
open(p, "w").write(s)
PY

protect Sources/TestKit/Assertions.swift
attack_swift "a collector that quietly drops what it is given" "THE INSTRUMENT IS BLUNT" 70 <<'PY'
p = "Sources/TestKit/Assertions.swift"
s = open(p).read().replace(
    '        collected.append("\\(name):\\(line) — \\(message)")',
    "        _ = (name, line, message)",
    1,
)
open(p, "w").write(s)
PY

protect Sources/TestKit/TestRunner.swift
attack_swift "a failing run that still exits zero" "a failing run still exits zero" 70 <<'PY'
p = "Sources/TestKit/TestRunner.swift"
s = open(p).read().replace(
    "        return report.allPassed ? 0 : 1",
    "        return 0",
    1,
)
open(p, "w").write(s)
PY

chapter "A real defect reaches the exit code"

# The whole chain, once, end to end: break a rule the domain tests cover and the
# process must exit 1 — not print a complaint and exit 0, which is how a suite
# ends up running in CI for a year without ever being able to fail it.
protect Sources/LampBoardCore/Update/ReleaseVersion.swift
attack_swift "a broken comparison the suite catches" "0.10.0" 1 <<'PY'
p = "Sources/LampBoardCore/Update/ReleaseVersion.swift"
s = open(p).read().replace(
    "        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)",
    "        (lhs.major, lhs.minor, lhs.patch) > (rhs.major, rhs.minor, rhs.patch)",
    1,
)
open(p, "w").write(s)
PY

# Whatever happened above, the binaries must match the sources again.
swift build > /dev/null 2>&1

fi

# ═════════════════════════════════════════════════════════════════════════════
chapter "The mod loads"

# A streaming hook written as an ordinary function: Claude Code drops the whole
# module, and check-mod.sh must say so.
protect mod/hooks/register.js
attack_mod "a streaming hook that is not a generator" "the mod does not load" <<'PY'
p = "mod/hooks/register.js"
s = open(p).read().replace("on('turn.step', async function* ($, e, next)", "on('turn.step', async ($, e, next)", 1)
open(p, "w").write(s)
PY

# ═════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "────────────────────────────────────────────────────────"
if [ "$(git status --porcelain)" != "$TREE_BEFORE" ]; then
    printf '\033[33m⚠\033[0m the tree is not how this script found it — run `git status` before trusting anything below.\n'
fi

if [ "$BLUNT" -eq 0 ]; then
    printf '\033[32m✓\033[0m %d violations committed, %d caught.\n' "$BITES" "$BITES"
    exit 0
else
    printf '\033[31m✗\033[0m %d of %d guards did not notice the violation they exist for.\n\n' \
        "$BLUNT" "$((BITES + BLUNT))"
    printf '  A guard that cannot be shown to fail is indistinguishable from no guard.\n'
    exit 1
fi
