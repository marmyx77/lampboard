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
#   ./Scripts/bite.sh --ios      only the Core's iOS build (needs Xcode)
#   ./Scripts/bite.sh --linux    only the Core's Linux build (needs docker)
#   ./Scripts/bite.sh --nodelink only NodeLink over ssh (needs docker)
#   ./Scripts/bite.sh --lampd    only lampd on a fake node and its watchdog
#                                (needs docker, and systemd --user for the watchdog)
#   ./Scripts/bite.sh --links    only what the Mac app links (needs a Mac)
#   ./Scripts/bite.sh --pins     only the pins of the packages (needs swift)
#   ./Scripts/bite.sh --parity   only the Mac app's parity with lampd (needs a Mac)

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

# The same, for a gate that lives in a script of its own because it needs
# something a machine may not have: a container engine, the iOS SDK. Such a gate
# exits 3 where it cannot look, and then the attack is skipped and said, like
# the mod's where there is no claude.
#   attack_platform <gate script> <description> <expected fragment>
attack_platform() {
    local gate="$1" description="$2" expected="$3" before status log="$WORK/platform.log"
    before="$(fingerprint)"
    if ! python3 - ; then blunt "$description" "the mutation itself failed to run"; restore; return; fi
    if [ "$before" = "$(fingerprint)" ]; then
        blunt "$description" "the mutation no longer applies — this bite is stale, and has been proving nothing"
        restore
        return
    fi
    "$gate" > "$log" 2>&1
    status=$?
    restore
    if [ "$status" -eq 3 ]; then
        printf '  %s cannot look on this machine: "%s" is not attacked here\n' "$gate" "$description"
    elif [ "$status" -eq 0 ]; then
        blunt "$description" "$gate stayed green with the violation in place"
    elif ! grep -Fq -- "$expected" "$log"; then
        blunt "$description" "it went red, but never said “${expected}”"
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

chapter "One protocol, every source"

# The conformance battery holds every source of the `v1` protocol to a contract
# written by hand. A field renamed in what a source writes must turn it red, and
# say which field. The client in the same Core would rename it too and keep
# reading, so only a contract written apart can notice (D174).
protect Sources/LampBoardCore/V1/V1Row.swift
attack_swift "a field of a row renamed in what a source writes" 'missing "owner"' 1 <<'PY'
p = "Sources/LampBoardCore/V1/V1Row.swift"
s = open(p).read().replace("        case source, owner\n", "        case source, owner = \"ownedBy\"\n", 1)
open(p, "w").write(s)
PY

chapter "Honest pushes (W4)"

# «Push oneste» (§6.2): what is already amber when a source starts is not news.
# A planner that forgets to remember it rings ten times at the first look.
protect Sources/LampBoardCore/Push/PushPlanner.swift
attack_swift "the announced memory emptied at the first look" "Ten amber rows at start are zero notifications" 1 <<'PY'
p = "Sources/LampBoardCore/Push/PushPlanner.swift"
s = open(p).read()
open(p, "w").write(s.replace("                memory.announced.insert(row.id)\n                memory.amberSince[row.id] = row.session.statusSince",
                             "                memory.amberSince[row.id] = row.session.statusSince", 1))
PY

# Amber after four seconds: a permission the agent answers itself is no alert.
protect Sources/LampBoardCore/Push/PushPlanner.swift
attack_swift "amber announced at once" "answered within four seconds never rings" 1 <<'PY'
p = "Sources/LampBoardCore/Push/PushPlanner.swift"
s = open(p).read()
open(p, "w").write(s.replace("public static let amberDelay: TimeInterval = 4", "public static let amberDelay: TimeInterval = 0", 1))
PY

# The device last used rings, the others quietly two minutes later (Q9).
protect Sources/LampBoardCore/Push/PushPlanner.swift
attack_swift "every device rings at once" "the other gets a quiet copy two minutes later" 1 <<'PY'
p = "Sources/LampBoardCore/Push/PushPlanner.swift"
s = open(p).read()
open(p, "w").write(s.replace("due: now.addingTimeInterval(othersAfter)", "due: now", 1))
PY

# A gone token (APNs 410) is the one answer that makes a source drop a device.
protect Sources/LampBoardCore/V1/RelayClient.swift
attack_swift "410 read as an ordinary refusal" "Each answer of the relay is one outcome" 1 <<'PY'
p = "Sources/LampBoardCore/V1/RelayClient.swift"
s = open(p).read()
open(p, "w").write(s.replace("case 410: return .gone(reason)", "case 410: return .refused(reason)", 1))
PY

# «Il relay non legge»: a source refuses to send a push whose bytes say what
# the envelope was meant to hide.
protect Sources/LampBoardCore/V1/RelayRequest.swift
attack_swift "a readable envelope let through" "A push that was never sealed is refused before it leaves" 1 <<'PY'
p = "Sources/LampBoardCore/V1/RelayRequest.swift"
s = open(p).read()
open(p, "w").write(s.replace("if secrets.contains(where: { Self.contains(Array(bytes), Array($0.utf8)) }) { throw Refusal.readable }", "", 1))
PY

chapter "Claude Code's word against its own transcript"

# A conversation Claude Code compacts while idle says `busy` in its file
# meanwhile, and that lit its row yellow for good on 2.3.0 (D177). The
# compaction's end must rest a row only the file lit: without the rule the
# recorded morning stays yellow and the suite must turn red.
protect Sources/LampBoardCore/Reducer/StateReducer.swift
attack_swift "an idle compaction that leaves its row working" "an idle compaction leaves the row at rest" 1 <<'PY'
p = "Sources/LampBoardCore/Reducer/StateReducer.swift"
s = open(p).read()
open(p, "w").write(s.replace("existing.baseStatus == .working, existing.litByFile {", "existing.baseStatus == .working, existing.litByFile, false {", 1))
PY

# And the way back when no hook comes at all: Claude Code's own `idle`, held a
# minute. With the threshold removed, the file's rest never outweighs a yellow.
protect Sources/LampBoardCore/Config/AppConfig.swift
attack_swift "a yellow the file's idle never rests" "outweighs a yellow nothing renews" 1 <<'PY'
p = "Sources/LampBoardCore/Config/AppConfig.swift"
s = open(p).read()
open(p, "w").write(s.replace("fileRestOutweighsWorkingAfter: TimeInterval = 60", "fileRestOutweighsWorkingAfter: TimeInterval = .infinity", 1))
PY

# Nor at once: a reading taken between a prompt and its `busy` must not rest it.
protect Sources/LampBoardCore/Config/AppConfig.swift
attack_swift "a yellow the file's first idle rests at once" "is not yet a rest" 1 <<'PY'
p = "Sources/LampBoardCore/Config/AppConfig.swift"
s = open(p).read()
open(p, "w").write(s.replace("fileRestOutweighsWorkingAfter: TimeInterval = 60", "fileRestOutweighsWorkingAfter: TimeInterval = 0", 1))
PY

chapter "When a session on another machine last spoke"

# The phone's first build showed a day and a half of silence as "13m": the
# probe dated every session by the newest file in its project's folder. When a
# session last spoke is the last timestamp in its own tail, read by the rule the
# Mac applies to its own transcripts; dropping that rule must turn the suite red.
protect Sources/LampBoardCore/Workspace/RemoteSessionsDecoder.swift
attack_swift "a remote session dated by its files, not by when it last spoke" "the tail's last spoken moment wins" 1 <<'PY'
p = "Sources/LampBoardCore/Workspace/RemoteSessionsDecoder.swift"
s = open(p).read()
open(p, "w").write(s.replace("modifiedAt: spoken ?? Date(", "modifiedAt: Date(", 1))
PY

# And where nothing in the tail carries a time, the session's own file dates
# it: a neighbour in the same folder speaking must not move it.
protect Sources/LampBoardCore/Workspace/RemoteProbeScript.swift
attack_swift "a remote session dated by its project folder's newest file" "never a neighbour's" 1 <<'PY'
p = "Sources/LampBoardCore/Workspace/RemoteProbeScript.swift"
s = open(p).read()
old = "            activity = max(activity, os.path.getmtime(own))\n"
new = ("            for other in glob.glob(os.path.dirname(own) + \"/*.jsonl\"):\n"
       "                activity = max(activity, os.path.getmtime(other))\n")
open(p, "w").write(s.replace(old, new, 1))
PY

# Busy in Claude Code's file stays busy while background agents run after a
# turn ended: blue on the Mac, it was yellow on the phone. A decoder that trusts
# the file alone again, never reading the turn, must turn the suite red.
protect Sources/LampBoardCore/Workspace/RemoteSessionsDecoder.swift
attack_swift "a remote session working on its file's word alone" "is not yellow, whatever its file says" 1 <<'PY'
p = "Sources/LampBoardCore/Workspace/RemoteSessionsDecoder.swift"
s = open(p).read()
open(p, "w").write(s.replace('turnIsOpen: (record["contextTail"] as? String).flatMap {',
                             'turnIsOpen: (nil as String?).flatMap {', 1))
PY

# And that same session is blue, not resting: build 2 collapsed busy with the
# turn ended into idle, and the phone showed neutral what the Mac showed blue.
protect Sources/LampBoardCore/Workspace/LiveSession.swift
attack_swift "a remote session paused on background work drawn resting" "blue, as on the Mac" 1 <<'PY'
p = "Sources/LampBoardCore/Workspace/LiveSession.swift"
s = open(p).read()
open(p, "w").write(s.replace("return turnIsOpen == false ? .waiting : .working",
                             "return turnIsOpen == false ? .idle : .working", 1))
PY

# Claude Code writes `shell` once the turn is over and only a background shell
# runs (measured with build 3: five minutes of it, blue on the Mac, resting on
# the phone, which knew only `busy`). Reading it as idle again must turn red.
protect Sources/LampBoardCore/Workspace/LiveSession.swift
attack_swift "a remote session paused on a background shell drawn resting" "a background shell after the turn" 1 <<'PY'
p = "Sources/LampBoardCore/Workspace/LiveSession.swift"
s = open(p).read()
open(p, "w").write(s.replace("case .shell: return .waiting", "case .shell: return .idle", 1))
PY

# `waiting` in the file is amber on the phone, which re-reads the file at every
# look, and never on the Mac's rows: their hooks carry the question and its way
# back, and a dialog closed fires no hook. Amber from the file there must turn red.
protect Sources/LampBoardCore/Workspace/LiveSession.swift
attack_swift "amber from the file lit on a row its hooks keep" "amber is the hooks'" 1 <<'PY'
p = "Sources/LampBoardCore/Workspace/LiveSession.swift"
s = open(p).read()
open(p, "w").write(s.replace("statusFromFile == .awaiting ? .idle : statusFromFile", "statusFromFile", 1))
PY

# The context windows live twice: the contract check-contract.sh holds against
# Claude Code's binary, and the table the panel divides by. One copy corrected
# alone (Claude Code 2.1.302 and claude-haiku-5-5, 17/10/2026) must turn red.
protect Sources/LampBoardCore/Transcript/ContextReading.swift
attack_swift "a context window corrected in one copy of the table only" "the contract says" 1 <<'PY'
p = "Sources/LampBoardCore/Transcript/ContextReading.swift"
s = open(p).read()
open(p, "w").write(s.replace('"claude-haiku-5-5": 1_000_000,\n', "", 1))
PY

chapter "A device's actions on another machine"

# End from a phone (W3, L.H6): the process is found by its session file, and a
# pid reused since the file was written is another program. Without the start
# check the script ends whatever now has that pid, and the suite must say so.
protect Sources/LampBoardCore/Live/RemoteEnd.swift
attack_swift "End that signals a reused pid" "a reused pid: not it" 1 <<'PY'
p = "Sources/LampBoardCore/Live/RemoteEnd.swift"
s = open(p).read()
open(p, "w").write(s.replace(" and started_at(pid) == start:", ":", 1))
PY

# Move with its lock (H1.5-3): a second Move of the same conversation, from
# another device or the Mac, ends nothing while the first holds the lock.
protect Sources/LampBoardCore/Live/RemoteMove.swift
attack_swift "a second Move that does not see the first one's lock" "the second is refused" 1 <<'PY'
p = "Sources/LampBoardCore/Live/RemoteMove.swift"
s = open(p).read()
open(p, "w").write(s.replace("        if not take():\n", "        if False:\n", 1))
PY

# Resume only what no process holds (H1.4-7, R5-3): a second writer forks the
# conversation. A check that always finds it free must turn the suite red.
protect Sources/LampBoardCore/Live/NodeActions.swift
attack_swift "a Resume of a conversation a live process holds" "held: refused before tmux is touched" 1 <<'PY'
p = "Sources/LampBoardCore/Live/NodeActions.swift"
s = open(p).read()
open(p, "w").write(s.replace("                sys.exit(4)\n", "                sys.exit(0)\n", 1))
PY

# Never a second `claude attach` (D130): the lock held by whoever waits for the
# attach. Taken away, a second window attaches beside the first.
protect Sources/LampBoardCore/Live/BackgroundAttach.swift
attack_swift "a second claude attach beside the first" "the second is refused" 1 <<'PY'
p = "Sources/LampBoardCore/Live/BackgroundAttach.swift"
s = open(p).read()
open(p, "w").write(s.replace("fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass", 1))
PY

# Whatever happened above, the binaries must match the sources again.
swift build > /dev/null 2>&1

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--ios" ]; then

chapter "The Core builds for iOS"

# The Core is the iPhone and iPad app's as it is. A framework only the Mac has,
# imported where the Core can see it, must stop the build for the simulator.
protect Sources/LampBoardCore/Update/ReleaseVersion.swift
attack_platform Scripts/test-ios.sh "a Mac-only framework imported into the Core" "'AppKit'" <<'PY'
p = "Sources/LampBoardCore/Update/ReleaseVersion.swift"
s = open(p).read()
open(p, "w").write("import AppKit\n" + s)
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--linux" ]; then

chapter "The Core builds and tests on Linux"

# The Core is also the Linux service's. Darwin, imported with no condition,
# compiles on every Mac and on no Linux machine: the Linux gate must say so.
# Where there is no container engine (the test Mac) this one is not attacked;
# `Scripts/bite.sh --linux` runs it on a machine that has one.
protect Sources/LampBoardCore/Update/ReleaseVersion.swift
attack_platform Scripts/test-linux.sh "Darwin imported into the Core with no condition" "'Darwin'" <<'PY'
p = "Sources/LampBoardCore/Update/ReleaseVersion.swift"
s = open(p).read()
open(p, "w").write("import Darwin\n" + s)
PY

# A tool run that leaves its pipe open: on Linux one descriptor per run, which
# killed lampd at the 1024 limit after two hours on the Linux machine.
protect Sources/LampBoardCore/System/Command.swift
attack_platform Scripts/test-linux.sh "a tool run that leaves its pipe open" "descriptors open" <<'PY'
p = "Sources/LampBoardCore/System/Command.swift"
s = open(p).read()
open(p, "w").write(s.replace("            try? pipe.fileHandleForReading.close()\n", "", 1))
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--links" ]; then

chapter "The Mac app links only its own"

# NodeLink's ssh stack is declared in the same manifest as the app (D175). The
# app naming NodeLink must turn the check red, and say through what.
protect Package.swift
attack_platform Scripts/check-app-links.sh "the Mac app made to link NodeLink" "LampBoardNodeLink → Citadel" <<'PY'
p = "Package.swift"
s = open(p).read()
old = 'dependencies: ["LampBoardCore", "SwiftTerm", "ClarcChatKit"],'
open(p, "w").write(s.replace(old, 'dependencies: ["LampBoardCore", "SwiftTerm", "ClarcChatKit", "LampBoardNodeLink"],', 1))
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--pins" ]; then

chapter "Every package the build reaches is pinned"

# A package of the ssh stack that no pin names: SwiftPM resolves it to whatever
# is newest and says nothing (measured), so the check has to.
protect Package.resolved
attack_platform Scripts/check-pins.sh "a package of the ssh stack with no pin" "bigint is in the build with no pin" <<'PY'
import json
p = "Package.resolved"
d = json.load(open(p))
d["pins"] = [pin for pin in d["pins"] if pin["identity"] != "bigint"]
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--nodelink" ]; then

chapter "NodeLink over ssh"

# The read key's line in the node's authorized_keys without its forced command:
# the key can run anything, and the check must see the command run.
protect Scripts/test-nodelink.sh
attack_platform Scripts/test-nodelink.sh "a read key whose line lost its forced command" "the command's own output never came" <<'PY'
p = "Scripts/test-nodelink.sh"
s = open(p).read()
old = 'READ_LINE="restrict,command=\\"/opt/ref/V1ReferenceNode stdio --socket /tmp/v1ref/v1.sock --device check-phone --role read\\" '
open(p, "w").write(s.replace(old, 'READ_LINE="restrict ', 1))
PY

# A host key verdict that lets any key in: the changed key must be noticed by
# the check over ssh, not only by the domain suite.
protect Sources/LampBoardNodeLink/NodeKeys.swift
attack_platform Scripts/test-nodelink.sh "a pinned host key that lets any other in" "a connection was made to a machine with another key" <<'PY'
p = "Sources/LampBoardNodeLink/NodeKeys.swift"
s = open(p).read()
old = "self = presented == expected ? .accepted(presented) : .refused(presented: presented, expected: expected)"
open(p, "w").write(s.replace(old, "_ = expected; self = .accepted(presented)", 1))
PY

# One protocol, every source: a field renamed in what a source writes, seen
# through ssh as it is seen through a buffer (D174).
protect Sources/LampBoardCore/V1/V1Row.swift
attack_platform Scripts/test-nodelink.sh "a field of a row renamed, seen over ssh" 'missing "owner"' <<'PY'
p = "Sources/LampBoardCore/V1/V1Row.swift"
s = open(p).read().replace("        case source, owner\n", "        case source, owner = \"ownedBy\"\n", 1)
open(p, "w").write(s)
PY

# The terminal (D176): a byte lost on the way in must show in the 10 MiB
# compared byte for byte on the raw channel.
protect Sources/LampBoardNodeLink/NodeTerminal.swift
attack_platform Scripts/test-nodelink.sh "the terminal losing a byte of every piece on the way in" "the raw channel did not carry the bytes unchanged" <<'PY'
p = "Sources/LampBoardNodeLink/NodeTerminal.swift"
s = open(p).read()
old = "for piece in V1Frame.pieces(Array(buffer.readableBytesView))"
open(p, "w").write(s.replace(old, "for piece in V1Frame.pieces(Array(buffer.readableBytesView.dropLast()))", 1))
PY

# The read key's line on the Linux machine allowing a PTY: the check must see
# the terminal open where it has to be refused.
protect Scripts/test-nodelink.sh
attack_platform Scripts/test-nodelink.sh "a read key whose line lets a terminal open" "the read key's terminal was not refused" <<'PY'
p = "Scripts/test-nodelink.sh"
s = open(p).read()
old = "printf 'restrict,command=\"echo no-v1-here\" %s"
open(p, "w").write(s.replace(old, "printf 'restrict,pty,command=\"echo no-v1-here\" %s", 1))
PY

# Q7 (D176): the background rule with `ignore-size` and no detach. With three
# clients the Mac stays as narrow as the phone (S-D, B2), and the check on
# tmux 3.4 must say so.
protect Sources/LampBoardCore/Live/TmuxSizeRule.swift
attack_platform Scripts/test-nodelink.sh "the background rule without its detach" "the Mac stayed narrow after the phone went to the background" <<'PY'
p = "Sources/LampBoardCore/Live/TmuxSizeRule.swift"
s = open(p).read()
old = ' -f ignore-size \\\\; detach-client -t \\"$c\\" "'
open(p, "w").write(s.replace(old, ' -f ignore-size "', 1))
PY

# The lights read over ssh write nothing (D176): a look that leaves a file in
# the machine's home must be seen doing it.
protect Sources/LampBoardCore/V1/V1ProbeReading.swift
attack_platform Scripts/test-nodelink.sh "a look at the lights that writes in the home" "the look wrote nothing in the home" <<'PY'
p = "Sources/LampBoardCore/V1/V1ProbeReading.swift"
s = open(p).read()
old = 'let probe = "python3 -B -c "'
open(p, "w").write(s.replace(old, 'let probe = "touch $HOME/.probe-was-here; python3 -B -c "', 1))
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--lampd" ]; then

chapter "lampd on a fake node"

# One rule for the files (§6.2): a copy of the rule in lampd that reads a
# background shell as resting must give a lamp the phone's look does not.
protect Sources/LampDKit/NodeRows.swift
attack_platform Scripts/test-lampd.sh "lampd reading the files with a rule of its own" "the same lamp for" <<'PY'
p = "Sources/LampDKit/NodeRows.swift"
s = open(p).read()
old = "V1ProbeSource.rows(from: reading.report, identity: identity, at: now)"
new = ("V1ProbeSource.rows(from: RemoteSessionsDecoder.Report(sessions: reading.report.sessions.map { "
       "$0.fileStatus == .shell ? $0.with(statusFromFile: .idle) : $0 }, windows: reading.report.windows), "
       "identity: identity, at: now)")
open(p, "w").write(s.replace(old, new, 1))
PY

# The service stopped does not turn the lights off (E10 as amended): the
# forced command giving up without the service, as it did before, is a red.
protect Sources/LampDKit/LampDStdio.swift
attack_platform Scripts/test-lampd.sh "v1-stdio that exits 69 when the service is down" "hello says the files are read" <<'PY'
p = "Sources/LampDKit/LampDStdio.swift"
s = open(p).read()
old = "        let log = LampDLog(file:"
open(p, "w").write(s.replace(old, "        if !device.isEmpty { exit(69) }\n" + old, 1))
PY

# The read key's line allowing a terminal: OpenSSH must be seen opening it.
protect Scripts/test-lampd.sh
attack_platform Scripts/test-lampd.sh "a read key's line that lets a terminal open" "the read key's terminal was not refused" <<'PY'
p = "Scripts/test-lampd.sh"
s = open(p).read()
old = 'as_dev "lampd devices revoke lost-phone" >> "$CACHE/devices.log" 2>&1 || failed "lampd devices revoke failed"\n'
new = old + "as_dev \"sed -i 's/^restrict,from=/restrict,pty,from=/' ~/.ssh/authorized_keys\"\n"
open(p, "w").write(s.replace(old, new, 1))
PY

# A phone paired for another network: without its from= it gets in.
protect Scripts/test-lampd.sh
attack_platform Scripts/test-lampd.sh "a phone's line without its from=" "a key from the wrong network got in" <<'PY'
p = "Scripts/test-lampd.sh"
s = open(p).read()
open(p, "w").write(s.replace("--action '$(pub far-action)' --from 192.0.2.0/24", "--action '$(pub far-action)'", 1))
PY

# A revocation that leaves the lines in authorized_keys.
protect Sources/LampDKit/DevicesStore.swift
attack_platform Scripts/test-lampd.sh "a revocation that leaves the phone's lines" "the file as it was" <<'PY'
p = "Sources/LampDKit/DevicesStore.swift"
s = open(p).read()
old = "let rewritten = try AuthorizedKeys.rewrite(text, removing: id, adding: [])"
open(p, "w").write(s.replace(old, "let rewritten = text", 1))
PY

# The house's own lines: a rewrite that drops its comments, with the guard
# that refuses it taken away, must be seen in the file it gives back.
protect Sources/LampDKit/AuthorizedKeys.swift
attack_platform Scripts/test-lampd.sh "authorized_keys rewritten without the house's comments" "the house first, unchanged" <<'PY'
p = "Sources/LampDKit/AuthorizedKeys.swift"
s = open(p).read()
s = s.replace("let kept = lines.filter { line in", 'let kept = lines.filter { !$0.hasPrefix("#") }.filter { line in', 1)
s = s.replace("guard others(in: result) == others(in: text) else {", "guard true else {", 1)
open(p, "w").write(s)
PY

# The journal replaying, after a reconnection, the event the phone holds.
protect Sources/LampDKit/NodeJournal.swift
attack_platform Scripts/test-lampd.sh "a journal that replays the event the phone already holds" "the event after what the phone held" <<'PY'
p = "Sources/LampDKit/NodeJournal.swift"
s = open(p).read()
open(p, "w").write(s.replace("return .events(log.filter { $0.seq > since })", "return .events(log.filter { $0.seq >= since })", 1))
PY

# Parity with the Mac's reducer on the recorded flows (§6.2): an answer that
# no longer resists a late signal reduces the flows to other lamps.
protect Sources/LampBoardCore/Models/SessionStatus.swift
attack_platform Scripts/test-lampd.sh "the reducer's downgrade rule inverted for an answer" "the reducer drifted from the Mac's" <<'PY'
p = "Sources/LampBoardCore/Models/SessionStatus.swift"
s = open(p).read()
i = s.index("public var blocksDowngrade: Bool {")
open(p, "w").write(s[:i] + s[i:].replace("{", "{\n        if self == .ready { return false }", 1))
PY

# The app one version behind (compatibility, §6.2): minClient raised without
# saying so shuts it out.
protect Sources/LampBoardCore/V1/V1Protocol.swift
attack_platform Scripts/test-lampd.sh "minClient raised without a word" "it answers a protocol-1 client" <<'PY'
p = "Sources/LampBoardCore/V1/V1Protocol.swift"
s = open(p).read()
open(p, "w").write(s.replace("public static let minClient = 1", "public static let minClient = 2", 1))
PY

# A token APNs says is gone (410) is dropped: kept, every alert for that
# device is a refusal for ever (W4).
protect Sources/LampDKit/NodePushes.swift
attack_platform Scripts/test-lampd.sh "a gone token kept" "410: the token is dropped" <<'PY'
p = "Sources/LampDKit/NodePushes.swift"
s = open(p).read()
open(p, "w").write(s.replace("if case .gone = outcome { forget(device: device, kind: kind, token: request.token) }", "", 1))
PY

# A Live Activity updated at every look spends the relay's hourly quota in a
# quarter of an hour on a busy machine (seen on the fake node, W4).
protect Sources/LampDKit/NodePushes.swift
attack_platform Scripts/test-lampd.sh "the Live Activity updated at every look" "at most once a minute" <<'PY'
p = "Sources/LampDKit/NodePushes.swift"
s = open(p).read()
open(p, "w").write(s.replace("public static let liveActivityQuiet: TimeInterval = 60", "public static let liveActivityQuiet: TimeInterval = 0", 1))
PY

chapter "A phone's actions on a fake node"

# Attachments by SFTP (H1.2-9): a new file only. Without SSH_FXF_EXCL a second
# copy under a name already there overwrites the first.
protect Sources/LampBoardNodeLink/NodeConnection.swift
attack_platform Scripts/test-lampd.sh "an attachment copied over a file already there" "a second copy under the same name is refused" <<'PY'
p = "Sources/LampBoardNodeLink/NodeConnection.swift"
s = open(p).read()
open(p, "w").write(s.replace("flags: [.write, .create, .forceCreate]", "flags: [.write, .create, .truncate]", 1))
PY

# `@name` arrives once (W3): a box script that writes the message twice is a
# conversation that reads it twice.
protect Sources/LampBoardCore/Peer/RemotePeerScripts.swift
attack_platform Scripts/test-lampd.sh "a message written into the box twice" "the message arrived once" <<'PY'
p = "Sources/LampBoardCore/Peer/RemotePeerScripts.swift"
s = open(p).read()
i = s.index('                box.sendall((json.dumps({"type": "user"')
j = s.index("\n", s.index('.encode("utf-8"))', i)) + 1
line = s[i:j]
open(p, "w").write(s[:j] + line + s[j:])
PY

# End from a phone closes a tmux session only when one of its panes holds the
# conversation's process: a name alone is not enough.
protect Sources/LampBoardCore/Live/RemoteEnd.swift
attack_platform Scripts/test-lampd.sh "End that closes whatever tmux session it is named" "a tmux session that does not hold the conversation is not closed" <<'PY'
p = "Sources/LampBoardCore/Live/RemoteEnd.swift"
s = open(p).read()
open(p, "w").write(s.replace("if not set(int(p) for p in panes if p.isdigit()) & set(ancestors(pid)):", "if False:", 1))
PY

# End closes a tmux session only when the conversation is all it holds: other
# panes are somebody's other work.
protect Sources/LampBoardCore/Live/RemoteEnd.swift
attack_platform Scripts/test-lampd.sh "End that closes a tmux session other panes still use" "the tmux session and its other pane are still there" <<'PY'
p = "Sources/LampBoardCore/Live/RemoteEnd.swift"
s = open(p).read()
open(p, "w").write(s.replace("            if len(panes) == 1:\n", "            if True:\n", 1))
PY

# The tmux options a phone's sessions want come from the repository (Q10, E14):
# the file that the installer copies losing focus-events must be seen on the node.
protect deploy/tmux/lampboard.conf
attack_platform Scripts/test-lampd.sh "focus-events dropped from the repository's tmux options" "focus-events, extended-keys and allow-passthrough on" <<'PY'
p = "deploy/tmux/lampboard.conf"
s = open(p).read()
open(p, "w").write(s.replace("set -s focus-events on\n", "", 1))
PY

chapter "lampd's contract timer"

# The four defects of the contract check read for the node in W0 (E5), each
# put back: the timer's run on a node must say so.
protect Scripts/check-contract.sh
attack_platform Scripts/test-contract-node.sh "a note in backticks that runs claude" "claude was run with no arguments" <<'PY'
p = "Scripts/check-contract.sh"
s = open(p).read()
open(p, "w").write(s.replace("check that 'claude' is authenticated", "check that `claude` is authenticated", 1))
PY

protect Scripts/check-contract.sh
attack_platform Scripts/test-contract-node.sh "a script called by a path relative to the checkout" "a script called by a path relative to the checkout" <<'PY'
p = "Scripts/check-contract.sh"
s = open(p).read()
open(p, "w").write(s.replace('python3 "$ROOT/Scripts/measure-compaction.py"', "python3 Scripts/measure-compaction.py", 1))
PY

protect Scripts/check-contract.sh
attack_platform Scripts/test-contract-node.sh "strings used where nobody asked whether it is there" "it crashed instead of saying so" <<'PY'
p = "Scripts/check-contract.sh"
s = open(p).read()
open(p, "w").write(s.replace('elif [ "$HAVE_STRINGS" = 0 ]; then\n    skip "strings (binutils) is not here - the hook event inventory was not examined"\n', "", 1))
PY

protect Scripts/check-contract.sh
attack_platform Scripts/test-contract-node.sh "the editor's lock asked for on a node" "red for ever on a node" <<'PY'
p = "Scripts/check-contract.sh"
s = open(p).read()
open(p, "w").write(s.replace('if os.environ.get("CONTRACT_NODE") != "1":', "if True:", 1))
PY

chapter "lampd's watchdog"

# The heartbeat from a thread of its own: a stopped loop is never restarted,
# and only the age in hello gives it away (S-G v2, row E). The gate must see it.
protect Sources/LampDKit/LampDService.swift
attack_platform Scripts/test-lampd-watchdog.sh "the heartbeat sent from a thread of its own" "the heartbeat does not come from the loop" <<'PY'
p = "Sources/LampDKit/LampDService.swift"
s = open(p).read()
old = "        Thread.detachNewThread { [self] in pollLoop() }\n"
new = old + '        Thread.detachNewThread { while true { SystemdNotify.send("WATCHDOG=1"); sleep(5) } }\n'
open(p, "w").write(s.replace(old, new, 1))
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$WHAT" = "all" ] || [ "$WHAT" = "--parity" ]; then

chapter "The Mac's parity holds through the sweeps"

# The recorded flows played into the real app (ParityE2ESuite) must survive the
# app's realignment, which keeps a terminal row only while its process lives.
# Without a process per session, the flows race the sweep: red on 18 October in
# every gate, green by hand.
protect Sources/LampBoardE2E/ParityE2ESuite.swift
attack_platform Scripts/test-parity-e2e.sh "the recorded sessions played with no process" "after two sweeps" <<'PY'
p = "Sources/LampBoardE2E/ParityE2ESuite.swift"
s = open(p).read()
old = "app.writeLiveSession(sessionId: id(original), cwd: workspace, entrypoint: \"cli\", pid: process.processIdentifier)"
open(p, "w").write(s.replace(old, "if original == \"neighbour\" { " + old + " }", 1))
PY

fi

# ═════════════════════════════════════════════════════════════════════════════
# Everywhere but the platform runs, as before they existed.
if [ "$WHAT" != "--ios" ] && [ "$WHAT" != "--linux" ] && [ "$WHAT" != "--nodelink" ] && [ "$WHAT" != "--links" ] \
    && [ "$WHAT" != "--pins" ] && [ "$WHAT" != "--lampd" ] && [ "$WHAT" != "--parity" ]; then

chapter "The mod loads"

# A streaming hook written as an ordinary function: Claude Code drops the whole
# module, and check-mod.sh must say so.
protect mod/hooks/register.js
attack_mod "a streaming hook that is not a generator" "the mod does not load" <<'PY'
p = "mod/hooks/register.js"
s = open(p).read().replace("on('turn.step', async function* ($, e, next)", "on('turn.step', async ($, e, next)", 1)
open(p, "w").write(s)
PY

fi

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
