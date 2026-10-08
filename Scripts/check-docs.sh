#!/bin/bash
#
# Checks that the documentation still describes this repository.
#
# WHY THIS EXISTS
# `docs/05-code-map.md` states figures — lines per target, lines per file, the
# longest file, how many test cases there are — and every one of them was written
# by hand and never checked again. Twenty-one of forty-seven were stale before this
# script existed, some by fifty per cent.
#
# That is the same criticism this project levelled at tmux: a hand-maintained table
# describing something that moves, with no test that any of it is still true. The
# answer there and here is the same one — if a document makes a claim a script can
# verify, a script should verify it.
#
# WHY EVERY SEARCH DECLARES WHAT IT EXPECTS TO FIND
# A checker built out of `findall` loops has a failure mode that looks exactly like
# success: reword the sentence it hunts for, and the loop runs zero times, reports
# nothing, and the check goes green. Absence gets mistaken for permission. It was
# not hypothetical here — the guard against personal paths (below) had never
# examined a single file, because `/usr/bin/grep -E` rejects the lookahead it was
# written with, and the error was being swallowed. Ten green runs, zero files read.
#
# So every search in this file states how many matches it expects. Finding fewer
# is a finding: either a sentence was reworded and the check just went blind, or a
# claim was deliberately removed and the expectation below has to be edited on
# purpose. Both are things a person should see.
#
# WHAT IT DOES NOT DO
# It does not rewrite the documentation. A number that drifted is usually a sign
# that the prose around it drifted too, and only a person can tell whether the file
# grew because it gained a responsibility or because it gained six lines.
#
# EXIT CODES
#   0  every check looked, and every check passed
#   1  at least one claim is false
#   3  at least one check could not observe reality — a green with a skip in it
#      is not a green, so it does not exit 0
#
# USAGE
#   ./Scripts/check-docs.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECKS=0
FAILURES=0
SKIPS=0
ok()   { CHECKS=$((CHECKS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { CHECKS=$((CHECKS+1)); SKIPS=$((SKIPS+1));   printf '  \033[33m⚠\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Turns an exit status into one of the three honest outcomes. A checker that only
# knows "pass" and "fail" has to pretend it looked when it could not, and that
# pretence is the thing this whole file exists to make impossible.
#   verdict <status> <passed> <failed> [<could-not-look>]
verdict() {
    case "$1" in
        0) ok "$2" ;;
        2) skip "${4:-could not verify: $2}" ;;
        *) bad "$3" ;;
    esac
}

MAP="docs/05-code-map.md"
[ -f "$MAP" ] || { echo "missing $MAP"; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────
head_ "Figures in the code map"

STATUS=0
python3 - "$MAP" <<'PY' || STATUS=$?
import glob, os, re, sys

doc = open(sys.argv[1]).read()
problems = []

# What this document is known to state today. A search that comes back with less
# than this found nothing because the wording moved, not because the repository
# is clean — and those two have to be told apart.
EXPECTED = {
    "per-target rows": 5,      # one per target in Sources/
    "per-target case counts": 4,
    "per-file figures": 60,
}

def lines_of(path):
    with open(path) as handle:
        return sum(1 for _ in handle)

swift = {os.path.basename(p): p for p in glob.glob("Sources/**/*.swift", recursive=True)}
if not swift:
    print("    no Swift sources found — this check cannot observe anything", file=sys.stderr)
    sys.exit(2)

def declared(name, found):
    """Reports a search that came back emptier than the document it reads."""
    wanted = EXPECTED[name]
    if len(found) < wanted:
        problems.append(
            f"expected at least {wanted} {name} in the code map, found {len(found)} — "
            f"either the wording changed and this check just went blind, or the "
            f"claims were removed and EXPECTED in check-docs.sh needs editing"
        )
    return found

# Per-target totals: "  LampBoardCore/    4,087 lines · 36 files"
for target, claimed_lines, claimed_files in declared("per-target rows", re.findall(
    r'^\s+(\w+)/\s+([\d,]+) lines · \s*(\d+) files', doc, re.M
)):
    paths = glob.glob(f"Sources/{target}/**/*.swift", recursive=True)
    if not paths:
        problems.append(f"{target}/ is described but no longer exists")
        continue
    actual_lines = sum(lines_of(p) for p in paths)
    if actual_lines != int(claimed_lines.replace(",", "")):
        problems.append(
            f"{target}/ says {claimed_lines} lines, has {actual_lines:,}"
        )
    if len(paths) != int(claimed_files):
        problems.append(
            f"{target}/ says {claimed_files} files, has {len(paths)}"
        )

# The self-imposed ceiling: "No file exceeds 590 lines. The limit … is 800."
ceiling = re.search(r'No file exceeds (\d+) lines\. The limit .*? is (\d+)', doc)
if not ceiling:
    problems.append("the sentence stating the longest file and the limit is gone")
else:
    stated, limit = int(ceiling.group(1)), int(ceiling.group(2))
    longest = max(swift.values(), key=lines_of)
    actual = lines_of(longest)
    if actual > limit:
        problems.append(
            f"{longest} is {actual} lines, over the project's own limit of {limit}"
        )
    elif actual != stated:
        problems.append(
            f'"no file exceeds {stated}" — {os.path.basename(longest)} is {actual}'
        )

# Test-case counts, stated next to the target they belong to.
for target, claimed in declared("per-target case counts", re.findall(
    r'(LampBoard(?:Tests|E2E))/.*?(\d+) cases', doc
)):
    actual = sum(
        open(p).read().count("TestCase(")
        for p in glob.glob(f"Sources/{target}/**/*.swift", recursive=True)
    )
    if actual != int(claimed):
        problems.append(f"{target}/ says {claimed} cases, has {actual}")

# Per-file sizes, from headings "### `X.swift` · 220" and table rows.
for name, claimed in declared("per-file figures", re.findall(
    r'`([A-Za-z0-9_]+\.swift)`\s*(?:·|\|)\s*(\d+)', doc
)):
    path = swift.get(name)
    if path is None:
        problems.append(f"{name} is documented but no longer in Sources/")
        continue
    actual = lines_of(path)
    # Rounded on purpose in the prose; only real drift is worth a report.
    if abs(actual - int(claimed)) > max(15, int(claimed) * 0.12):
        problems.append(f"{name} says {claimed} lines, has {actual}")

for p in problems:
    print(f"    {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
verdict "$STATUS" \
    "every stated figure matches the repository" \
    "the code map states figures that are no longer true" \
    "the code map could not be measured against the sources"

# ─────────────────────────────────────────────────────────────────────────────
head_ "Links between documents"

STATUS=0
python3 - <<'PY' || STATUS=$?
import glob, os, re, sys

# The documentation is known to cross-reference itself heavily. If this number
# collapses, the links were not fixed — the files stopped being found.
EXPECTED_LINKS = 90


def anchors_of(path):
    """GitHub's slug for every heading in a Markdown file."""
    slugs = set()
    for line in open(path):
        if not line.startswith("#"):
            continue
        text = line.lstrip("#").strip()
        slug = re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")
        slugs.add(slug)
    return slugs


NAMED = ["Contracts/assumptions.md", "README.md"]
FILES = glob.glob("docs/*.md") + NAMED
cache = {}
problems = []
total = 0

# A file named here that has vanished is not "nothing to check": it is a
# document this script believes it is guarding and is not.
for f in NAMED:
    if not os.path.exists(f):
        problems.append(f"{f} is checked by this script and no longer exists")

for f in FILES:
    if not os.path.exists(f):
        continue
    base = os.path.dirname(f)
    for match in re.finditer(r'\[[^\]]*\]\(([^)]+)\)', open(f).read()):
        target = match.group(1)
        if target.startswith(("http", "mailto")):
            continue
        total += 1
        path, _, anchor = target.partition("#")
        resolved = os.path.normpath(os.path.join(base, path)) if path else f
        if not os.path.exists(resolved):
            problems.append(f"{f} -> {target} (no such file)")
            continue
        # A #Lnn line reference points into source, not a heading.
        if not anchor or re.fullmatch(r"L\d+(-L\d+)?", anchor):
            continue
        if not resolved.endswith(".md"):
            continue
        if resolved not in cache:
            cache[resolved] = anchors_of(resolved)
        if anchor not in cache[resolved]:
            problems.append(f"{f} -> {target} (no such heading)")

print(f"    {total} links checked, anchors included", file=sys.stderr)
if total < EXPECTED_LINKS:
    problems.append(
        f"expected at least {EXPECTED_LINKS} relative links, found {total} — "
        f"the documents were not found, or the link syntax this reads has changed"
    )
for problem in problems:
    print(f"    broken: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
verdict "$STATUS" \
    "every relative link resolves" \
    "the documentation links somewhere that is not there"

# ─────────────────────────────────────────────────────────────────────────────
head_ "Figures stated outside the code map"

# The code map was checked; README, 01-architecture and 06-working-here were not,
# and all three announced 242 domain tests when there were 416. A checker that
# looks in one place is a checker with one blind spot per other place.
STATUS=0
python3 - <<'FIGPY' || STATUS=$?
import glob, os, re, sys

def lines_of(p):
    with open(p) as h: return sum(1 for _ in h)
def cases(target):
    return sum(open(p).read().count("TestCase(") for p in glob.glob(f"Sources/{target}/**/*.swift", recursive=True))

sources = glob.glob("Sources/**/*.swift", recursive=True)
if not sources:
    print("    no Swift sources found — nothing to compare these figures against", file=sys.stderr)
    sys.exit(2)

domain, e2e = cases("LampBoardTests"), cases("LampBoardE2E")
longest = max(lines_of(p) for p in sources)
total = sum(lines_of(p) for p in sources)

CASES = r"(\d+) (?:cases|domain tests)"
E2E   = r"(\d+) end-to-end tests"
LONG  = r"longest today is (\d+)"
SWIFT = r"~([\d,]+) lines of Swift"

# How many times each document is known to state each figure. Written down so
# that a rewording turns this check red instead of quietly switching it off:
# every one of these sentences was, at some point, wrong.
EXPECTED = {
    "README.md":               {CASES: 1, E2E: 1, LONG: 0, SWIFT: 0},
    "docs/01-architecture.md": {CASES: 2, E2E: 0, LONG: 0, SWIFT: 0},
    "docs/06-working-here.md": {CASES: 2, E2E: 0, LONG: 1, SWIFT: 0},
    "docs/05-code-map.md":     {CASES: 4, E2E: 0, LONG: 0, SWIFT: 1},
    # The register of the gates, which this gate did not read. A third audit
    # found it stating 630 domain cases and 88 end-to-end while the suites ran
    # 674 and 95 — and this check passing, and printing that the counts agreed
    # everywhere they are stated. The document describing what is guarded was
    # the one thing not guarded.
    "docs/08-gates.md":        {CASES: 2, E2E: 0, LONG: 0, SWIFT: 0},
}

problems = []
for f, expectations in EXPECTED.items():
    if not os.path.exists(f):
        problems.append(f"{f} is checked for stale figures and no longer exists")
        continue
    text = open(f).read()
    for pattern, wanted in expectations.items():
        found = re.findall(pattern, text)
        if len(found) < wanted:
            problems.append(
                f"{f}: expected {wanted} statement(s) matching /{pattern}/, found {len(found)} — "
                f"a reworded sentence silently removes this check"
            )
    for n in set(re.findall(CASES, text)):
        if int(n) not in (domain, e2e):
            problems.append(f"{f} says {n} cases; the suites have {domain} and {e2e}")
    for n in set(re.findall(E2E, text)):
        if int(n) != e2e: problems.append(f"{f} says {n} end-to-end tests, there are {e2e}")
    for n in re.findall(LONG, text):
        if int(n) != longest: problems.append(f"{f} says the longest file is {n} lines, it is {longest}")
    for n in re.findall(SWIFT, text):
        n = int(n.replace(",", ""))
        if abs(n - total) > 300: problems.append(f"{f} says ~{n:,} lines of Swift, the total is {total:,}")

print(f"    {domain} domain cases, {e2e} end-to-end, longest {longest} lines, {total:,} total", file=sys.stderr)
for p in problems: print(f"    {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
FIGPY
verdict "$STATUS" \
    "test counts and the longest-file figure agree everywhere they are stated" \
    "a document outside the code map states a stale figure" \
    "the figures outside the code map could not be compared to anything"

head_ "The status table says how the project stands now"

# WORKLOG.md was outside every check above, because it reads like a diary and
# nobody thought to include one. Inside it sits a table titled "How the project
# stands now", and it announced 242 domain tests, 66 end-to-end and a longest
# file of 407 lines while the truth was 497, 82 and 786 — plus a build declared
# free of warnings that had twenty-eight. Found by a semantic audit, not by this
# script, which is exactly what a blind spot is.
#
# Scoped to that one table on purpose. The rest of the file is history, and the
# figures in an entry from August are *correct* precisely because they are old:
# a rule demanding they be current would fire on every past entry, and a noisy
# gate stops being read.
STATUS=0
python3 - <<'STATUSPY' || STATUS=$?
import glob, os, re, sys

def lines_of(path):
    with open(path) as handle: return sum(1 for _ in handle)

def cases(target):
    return sum(open(p).read().count("TestCase(")
               for p in glob.glob(f"Sources/{target}/**/*.swift", recursive=True))

if not os.path.exists("WORKLOG.md"):
    print("    WORKLOG.md is gone — the status table cannot be read", file=sys.stderr)
    sys.exit(2)

text = open("WORKLOG.md").read()
start = text.find("## How the project stands now")
if start < 0:
    print("    WORKLOG.md has no status table any more", file=sys.stderr)
    sys.exit(1)
# Only as far as the next heading: everything after it is the diary.
end = text.find("\n## ", start + 1)
table = text[start:end if end > 0 else len(text)]

domain, e2e = cases("LampBoardTests"), cases("LampBoardE2E")
longest = max(lines_of(p) for p in glob.glob("Sources/**/*.swift", recursive=True))

problems = []
for claimed, actual, label in [
    (re.search(r"Domain tests \| \*\*(\d+)\*\*", table), domain, "domain tests"),
    (re.search(r"End-to-end tests \| \*\*(\d+)\*\*", table), e2e, "end-to-end tests"),
    (re.search(r"Longest file \| (\d+) lines", table), longest, "longest file"),
]:
    if claimed is None:
        problems.append(f"the table no longer states the {label}")
    elif int(claimed.group(1)) != actual:
        problems.append(f"the table says {claimed.group(1)} {label}, the repository has {actual}")

for problem in problems: print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
STATUSPY
verdict "$STATUS" \
    "the status table agrees with the repository" \
    "the status table describes a project that has moved" \
    "WORKLOG.md could not be read"

head_ "No personal paths or private addresses in tracked files"

# THE ONE THAT WAS GREEN BECAUSE IT WAS BROKEN.
#
# This was a shell pipeline: `git ls-files | xargs grep -nIE '/Users/(?!dev|…)'`,
# with `2>/dev/null` on the end and `|| true` after it. `/usr/bin/grep -E` has no
# lookahead — it answers "repetition-operator operand invalid" and exits 2 — so
# every run threw the error away, produced no matches, and printed a tick. The
# guard that keeps a real name out of a public repository had never read a file,
# and there was a real name in `Contracts/golden/hooks.jsonl` the whole time.
#
# Rewritten in Python, where the matching is done in this process and an error is
# an error. And it now proves itself first: the patterns are run against strings
# that are known to match and known not to, and a pattern that fails its own
# example fails the check. A guard that cannot demonstrate it still bites is
# indistinguishable from no guard at all.
STATUS=0
python3 - <<'LEAKPY' || STATUS=$?
import re, subprocess, sys

# Fixture homes, used deliberately throughout the tests and the documentation.
FIXTURES = {"dev", "you", "sam", "me"}

# A home directory belonging to somebody real.
HOME = re.compile(r"/(?:Users|home)/([A-Za-z0-9][A-Za-z0-9._-]*)")
# The range a VPN mesh hands out: a real box, never an example.
VPN = re.compile(r"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d+\.\d+\b")
# user@address, unless the address is one of the ranges reserved for docs
# (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 — RFC 5737).
SSH = re.compile(r"\b[a-z][a-z0-9._-]*@(\d+\.\d+\.\d+\.\d+)\b")
DOCUMENTATION_NETS = ("192.0.2.", "198.51.100.", "203.0.113.")

# ── The guard proves itself before it is believed ────────────────────────────
def self_test():
    broken = []
    def must(condition, what):
        if not condition: broken.append(what)

    def group(pattern, text, index=0):
        """The matched text, or None. Never raises: a self-test that dies before
        it can report is a self-test that leaves you with a stack trace instead
        of the one sentence you needed."""
        found = pattern.search(text)
        return None if found is None else found.group(index)

    must(group(HOME, "/Users/" + "somebody/x") is not None, "the home pattern no longer matches a real name under /Users")
    must(group(HOME, "/home/" + "somebody/x") is not None, "the home pattern no longer matches a real name under /home")
    must(group(HOME, "/Users/dev/x", 1) == "dev", "the home pattern no longer reports the user name")
    must(group(VPN, "100." + "101.5.7") is not None, "the VPN pattern no longer matches the mesh range")
    must(group(VPN, "100.5.5.7") is None, "the VPN pattern matches an address outside the range")
    must(group(SSH, "node@" + "10.0.0.4") is not None, "the ssh pattern no longer matches user@address")
    must((group(SSH, "dev@192.0.2.10", 1) or "").startswith(DOCUMENTATION_NETS),
         "the documentation ranges are no longer recognised")
    return broken

broken = self_test()
if broken:
    print("    THE GUARD ITSELF IS BROKEN — it would pass anything:", file=sys.stderr)
    for b in broken: print(f"      · {b}", file=sys.stderr)
    sys.exit(1)

listing = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True)
if listing.returncode != 0:
    print("    git could not list the tracked files — nothing was examined", file=sys.stderr)
    sys.exit(2)
files = [f for f in listing.stdout.split("\0") if f]
if not files:
    print("    git lists no tracked files — nothing was examined", file=sys.stderr)
    sys.exit(2)

hits, read = [], 0
# No file is exempt, this one included. The examples in the self-test above are
# assembled from pieces for that reason: an exemption is a hole with a good
# excuse, and the guard it protects is the one whose failure nobody can see.
for path in files:
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        continue  # binary or unreadable: nothing legible to leak
    read += 1
    for number, line in enumerate(text.splitlines(), 1):
        for match in HOME.finditer(line):
            if match.group(1) not in FIXTURES:
                hits.append(f"{path}:{number}  {match.group(0)}")
        for match in VPN.finditer(line):
            hits.append(f"{path}:{number}  {match.group(0)}")
        for match in SSH.finditer(line):
            if not match.group(1).startswith(DOCUMENTATION_NETS):
                hits.append(f"{path}:{number}  {match.group(0)}")

print(f"    {read} of {len(files)} tracked files read, {len(hits)} matches", file=sys.stderr)
for hit in hits[:12]:
    print(f"    {hit}", file=sys.stderr)
if len(hits) > 12:
    print(f"    … and {len(hits) - 12} more", file=sys.stderr)
sys.exit(1 if hits else 0)
LEAKPY
verdict "$STATUS" \
    "no real home directory or private VPN address in the tree" \
    "a tracked file carries what looks like a real path or address" \
    "the tracked files could not be listed — nothing was examined"

head_ "Nothing in the repository is written in Italian"

# The project is written and thought about in Italian, and shipped in English.
# For a long time that held because somebody remembered; the rule is inflexible
# now, so it gets a gate rather than a paragraph.
#
# Detected by function words rather than by a language model, because the answer
# has to be the same on every machine and explainable in one line: these are
# words that carry no meaning in English and appear in no identifier. A comment,
# a document, a commit-message file — anything tracked.
#
# It found three occurrences when it was written, all the same quoted sentence
# kept as evidence for a decision. They were translated rather than exempted: a
# rule that ships with an exception has stopped being inflexible on its first
# day.
ITALIAN=0
python3 - <<'ITAPY' || ITALIAN=$?
import os, re, subprocess, sys

# The list lives in a file of its own, and that file is the only thing skipped
# here. A gate cannot hold the words it forbids and still check itself, so the
# exemption is made as small as it can be: everything in `italian-words.txt` is
# the list, and there is nowhere in it for a sentence to hide.
LIST = "Scripts/italian-words.txt"
try:
    words = [
        line.strip() for line in open(LIST, encoding="utf-8")
        if line.strip() and not line.startswith("#")
    ]
except OSError:
    print(f"    {LIST} could not be read - nothing was examined", file=sys.stderr)
    sys.exit(2)
if not words:
    print(f"    {LIST} is empty, so this check would pass on anything", file=sys.stderr)
    sys.exit(2)

pattern = re.compile(r"\b(" + "|".join(re.escape(w) for w in words) + r")\b", re.IGNORECASE)

listing = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True)
if listing.returncode != 0:
    print("    git could not list the tracked files - nothing was examined", file=sys.stderr)
    sys.exit(2)
files = [f for f in listing.stdout.split("\0") if f and f != LIST]

hits = []
for path in files:
    try:
        text = open(path, errors="replace").read()
    except OSError:
        continue
    for number, line in enumerate(text.splitlines(), 1):
        for word in pattern.findall(line):
            hits.append(f"{path}:{number} reads as Italian ({word.lower()}): {line.strip()[:70]}")

print(f"    {len(files)} tracked files read against {len(words)} words, {len(hits)} lines",
      file=sys.stderr)
for hit in hits[:10]:
    print(f"    {hit}", file=sys.stderr)
sys.exit(1 if hits else 0)
ITAPY
verdict "$ITALIAN" \
    "every tracked file is written in English" \
    "a tracked file is written in Italian" \
    "the tracked files could not be listed - nothing was examined"

head_ "The contract knows which events we register"

# The one that got away. Everything was committed, 416 tests and 11 checks were
# green, and two documents still said eight registered events after PostToolUse
# made nine. Nothing looked, because the contract check verifies the inventory
# against Claude Code's binary — whether an event EXISTS — and never against what
# this app actually asks for.
STATUS=0
python3 - <<'EVPY' || STATUS=$?
import json, re, sys

spec = json.load(open("Contracts/required-fields.json"))["hookEventInventory"]
source = open("Sources/LampBoardCore/Setup/HookConfigMerger.swift").read()
match = re.search(r"defaultEvents = \[(.*?)\n    \]", source, re.S)
if match is None:
    print("    could not find defaultEvents in HookConfigMerger.swift", file=sys.stderr)
    sys.exit(1)

code = set(re.findall(r'"([A-Za-z]+)"', match.group(1)))
declared = set(spec["registered"])
problems = []
if not code:
    problems.append("defaultEvents was found and is empty — this check would pass on anything")
if not declared:
    problems.append("the spec's registered list is empty — this check would pass on anything")
for missing in sorted(code - declared):
    problems.append(f"{missing} is registered by the code and absent from the spec")
for extra in sorted(declared - code):
    problems.append(f"{extra} is in the spec's registered list and not in the code")

# And it must not be in two classes at once: the moment an event is registered it
# stops being "decoded but not registered", and that sentence is somewhere in prose.
for both in sorted(code & set(spec["decodedButNotRegistered"]["events"])):
    problems.append(f"{both} is both registered and listed as not registered")

print(f"    {len(code)} events registered by the code", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
EVPY
verdict "$STATUS" \
    "the spec's registered list matches HookConfigMerger" \
    "the contract and the code disagree about what is registered"

# Prose is not machine-checkable, but a stale COUNT in a heading is.
STATUS=0
python3 - <<'COUNTPY' || STATUS=$?
import json, os, re, sys

count = len(json.load(open("Contracts/required-fields.json"))["hookEventInventory"]["registered"])
WORDS = "zero one two three four five six seven eight nine ten eleven twelve".split()
if count >= len(WORDS):
    print(f"    {count} registered events, and this check only spells up to {len(WORDS) - 1}", file=sys.stderr)
    sys.exit(2)
name = WORDS[count]

# Scoped to the documents that describe the CURRENT state. `docs/07-traps.md` is
# deliberately excluded: it is a record of what was true when each defect was
# found, and "the eight events registered at the time" is correct prose there.
# Rewriting history to satisfy a checker would be a worse failure than the drift
# this catches.
FILES = ["docs/02-claude-code.md", "docs/05-code-map.md", "README.md", "Contracts/assumptions.md"]
STATEMENT = re.compile(r"the (two|three|four|five|six|seven|eight|nine|ten) events (lampboard )?registers?", re.I)

problems, stating = [], 0
for f in FILES:
    if not os.path.exists(f):
        problems.append(f"{f} is checked for the registered-event count and no longer exists")
        continue
    text = open(f).read()
    found = STATEMENT.findall(text)
    if not found:
        continue
    stating += 1
    for spelled, _ in found:
        if spelled.lower() != name:
            problems.append(f'{f} says "the {spelled} events", there are {count} ("the {name} events")')

# At least one document is supposed to state this. Zero means the sentence was
# reworded and this check quietly stopped guarding anything.
if stating == 0:
    problems.append(
        f"no document states how many events are registered — the sentence this "
        f"reads was reworded, and the check went blind rather than green"
    )

print(f"    {count} registered events, stated in {stating} of {len(FILES)} documents", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
COUNTPY
verdict "$STATUS" \
    "no document announces a different number of registered events" \
    "a document still announces the old count of registered events" \
    "the registered-event count could not be spelled out"

head_ "Test suites are registered"

# A suite that exists but was never added to the runner is a file nobody executes,
# which is where three of this project's defects were found.
STATUS=0
python3 - <<'SUITEPY' || STATUS=$?
import glob, os, re, sys

EXPECTED_SUITES = 50   # today: 59. A collapse means the parsing broke, not that
                       # fifty suites were deleted.

paths = glob.glob("Sources/LampBoardTests/*.swift")
if not paths:
    print("    no test sources found — nothing was examined", file=sys.stderr)
    sys.exit(2)

defined = set()
for path in paths:
    defined |= set(re.findall(r'^enum (\w+Suite) \{', open(path).read(), re.M))
registered = set(re.findall(r'(\w+Suite)\.suite', open("Sources/LampBoardTests/main.swift").read()))

problems = []
if len(defined) < EXPECTED_SUITES:
    problems.append(
        f"expected at least {EXPECTED_SUITES} suites, found {len(defined)} — "
        f"the declaration this reads has changed shape and the check went blind"
    )
for orphan in sorted(defined - registered):
    problems.append(f"{orphan} is defined but never registered in main.swift")

print(f"    {len(defined)} suites defined, {len(registered)} registered", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
SUITEPY
verdict "$STATUS" \
    "every suite defined is run" \
    "a suite exists that the runner never calls" \
    "the test sources could not be read"

head_ "Every file is on the map"

# The gap this closes was found by hand, once, and by being asked "is everything
# documented?" — which is not a question anybody asks twice.
#
# The other checks here verify what the documents SAY: figures, links, counts. A
# file that exists and is written about nowhere says nothing, so nothing catches
# it. Three of them had accumulated: two runtime files from the update flow, and
# the script that settles the context denominator.
#
# Scoped to the two shipped targets and to the scripts. The tests are deliberately
# left out: the code map samples the suites it considers worth naming, and a rule
# demanding all sixty would either bloat the map or teach people to add a row
# without a thought — both worse than the drift.
STATUS=0
python3 - <<'MAPPY' || STATUS=$?
import os, sys

MAP = "docs/05-code-map.md"
if not os.path.exists(MAP):
    print("    the code map is gone", file=sys.stderr)
    sys.exit(1)

mapped = open(MAP).read()
missing, examined = [], 0

for target in ("Sources/LampBoardCore", "Sources/LampBoardApp"):
    for root, _, files in os.walk(target):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            examined += 1
            # By file name or by the type it holds: the map names some files and
            # describes others by their type, and both are being on the map.
            if name not in mapped and name[:-6] not in mapped:
                missing.append(f"{os.path.join(root, name)} is in the tree and not on the map")

for name in sorted(os.listdir("Scripts")):
    if not name.endswith((".sh", ".py")):
        continue
    examined += 1
    if f"Scripts/{name}" not in mapped:
        missing.append(f"Scripts/{name} is not in the map's script table")

# Vendored code ships too (D129): every folder under Vendor/ has its row, which
# says what it is and points at the VENDORED.md that records where it came from.
if os.path.isdir("Vendor"):
    for name in sorted(os.listdir("Vendor")):
        if os.path.isdir(os.path.join("Vendor", name)):
            examined += 1
            if f"Vendor/{name}" not in mapped:
                missing.append(f"Vendor/{name} is vendored and not on the map")

# A collapse means the walk broke, not that the repository emptied.
if examined < 80:
    print(f"    only {examined} files examined — this check went blind", file=sys.stderr)
    sys.exit(1)

print(f"    {examined} files and scripts, {len(missing)} unaccounted for", file=sys.stderr)
for problem in missing:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if missing else 0)
MAPPY
verdict "$STATUS" \
    "every shipped file and every script is described somewhere in the code map" \
    "something in the tree is written about nowhere" \
    "the tree could not be walked"

head_ "The mutation count in the documents is the one bite.sh runs"

# The register of the gates became readable when its case counts were checked
# like every other figure. This number walked out through the one door left
# open: it is written in words. Three documents said `bite.sh` commits
# twenty-two violations while it was committing twenty-five, and the figure
# check went past them every time, because it looks for digits.
#
# The count is derived from the file rather than declared anywhere. A constant
# here would be one more number to keep, and the thing being guarded is exactly
# the failure of keeping numbers in step by hand.
#
# The WORKLOG is deliberately not read. Its entries are dated and say what was
# true when they were written; a chronicle rewritten to match today has stopped
# being a chronicle.
STATUS=0
python3 - <<'MUTPY' || STATUS=$?
import os, re, sys

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = {2: "twenty", 3: "thirty", 4: "forty", 5: "fifty",
        6: "sixty", 7: "seventy", 8: "eighty", 9: "ninety"}

def spell(n):
    if n < 20:
        return ONES[n]
    tens, ones = divmod(n, 10)
    return TENS[tens] if ones == 0 else f"{TENS[tens]}-{ONES[ones]}"

VALUE = {spell(n): n for n in range(1, 100)}

if not os.path.exists("Scripts/bite.sh"):
    print("    Scripts/bite.sh is gone — there is no count to compare against", file=sys.stderr)
    sys.exit(3)

bite = open("Scripts/bite.sh").read()
count = sum(len(re.findall(rf"^{name} ", bite, re.M)) for name in ("attack", "attack_swift", "attack_mod"))

problems = []
# Zero means the calls were renamed and this check would otherwise compare every
# document against nothing, and pass.
if count == 0:
    problems.append(
        "no `attack` calls found in bite.sh — the shape this reads has changed "
        "and the check went blind rather than green"
    )

FILES = ["docs/08-gates.md", "docs/06-working-here.md", "docs/05-code-map.md"]
STATEMENT = re.compile(r"commits ([a-z]+(?:-[a-z]+)?) violations", re.I)
CATCHES = re.compile(r"demands ([a-z]+(?:-[a-z]+)?) catches", re.I)

stating = 0
for f in FILES:
    if not os.path.exists(f):
        problems.append(f"{f} states the mutation count and no longer exists")
        continue
    text = open(f).read()
    said = STATEMENT.findall(text) + CATCHES.findall(text)
    if not said:
        continue
    stating += 1
    for spelled in said:
        value = VALUE.get(spelled.lower())
        if value is None:
            problems.append(f"{f} says “{spelled}”, which is not a number this can read")
        elif value != count:
            problems.append(f"{f} says {spelled} mutations, bite.sh commits {count}")

if stating == 0 and count:
    problems.append(
        "no document states how many mutations bite.sh commits — the sentence "
        "this reads was reworded, and the check went blind rather than green"
    )

print(f"    {count} mutations, stated in {stating} of {len(FILES)} documents", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
MUTPY
verdict "$STATUS" \
    "the documents state the number of mutations bite.sh runs" \
    "a document states a mutation count that bite.sh no longer runs" \
    "the mutation count could not be read"

head_ "Every gate here can be shown to bite"

# The rule that keeps the rest of this file honest: each section above claims to
# catch something, and `Scripts/bite.sh` breaks the repository on purpose to
# prove it does. A check added without a bite is a check nobody has ever seen
# fail, which is the same starting point as the broken grep above.
STATUS=0
python3 - <<'BITEPY' || STATUS=$?
import os, re, sys

if not os.path.exists("Scripts/bite.sh"):
    print("    Scripts/bite.sh is gone — no gate here can be shown to work", file=sys.stderr)
    sys.exit(1)

checker = open("Scripts/check-docs.sh").read()
bite = open("Scripts/bite.sh").read()

# The section titles this script prints, and the ones bite.sh claims to attack.
sections = set(re.findall(r'^head_ "([^"]+)"', checker, re.M))
attacked = set(re.findall(r'^\s*gate "([^"]+)"', bite, re.M))

problems = []
for unproven in sorted(sections - attacked):
    problems.append(f'"{unproven}" has no mutation in bite.sh — nobody has seen it fail')
for orphan in sorted(attacked - sections):
    problems.append(f'bite.sh attacks "{orphan}", which check-docs.sh no longer has')

print(f"    {len(sections)} gates, {len(attacked)} with a mutation that proves them", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
BITEPY
verdict "$STATUS" \
    "every gate has a mutation in bite.sh that turns it red" \
    "a gate here has never been proven to catch anything"

printf '\n%s\n' "────────────────────────────────────────────────────────"
if [ "$FAILURES" -eq 0 ] && [ "$SKIPS" -eq 0 ]; then
    printf '\033[32m✓\033[0m %d checks, all passing.\n' "$CHECKS"
elif [ "$FAILURES" -eq 0 ]; then
    printf '\033[33m⚠\033[0m %d of %d checks could not look at anything.\n\n' "$SKIPS" "$CHECKS"
    printf '  Nothing above is false, but nothing above was verified either.\n'
    printf '  A green with a skip in it is not a green.\n'
    exit 3
else
    printf '\033[31m✗\033[0m %d of %d checks failed' "$FAILURES" "$CHECKS"
    [ "$SKIPS" -gt 0 ] && printf ', %d could not look' "$SKIPS"
    printf '.\n\n'
    printf '  The documentation is describing a repository that has moved.\n'
    printf '  Each line above names the claim and what is true instead.\n'
    exit 1
fi
