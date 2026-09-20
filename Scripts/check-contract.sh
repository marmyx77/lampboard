#!/bin/bash
#
# Checks that the assumptions lampboard makes about Claude Code still hold.
#
# WHY THIS EXISTS
# This project balances on things nobody promised: hook event names and payload
# shapes, the files the VS Code extension leaves on disk, an extension's URI
# handler. None of it is documented, and none of it is stable by contract.
#
# The dangerous failure is not "they moved the furniture" — that one errors out
# and gets noticed. It is the silent one: if `SubagentStop` stops firing, nothing
# breaks, no exception is raised, and the column simply stays yellow forever while
# you believe an agent is still working.
#
# WHAT IT DOES NOT DO
# It does not repair anything. A script can notice that `session_id` became
# `sessionId`; it cannot decide what that means, and a wrong automatic fix hides
# the breakage instead of reporting it. The report IS the repair here — it names
# the assumption, where the code depends on it, and what changed. Hand that to a
# person or an agent and the fix takes minutes.
#
# USAGE
#   ./Scripts/check-contract.sh            static checks only — seconds, free
#   ./Scripts/check-contract.sh --live     also runs a real probe session
#   ./Scripts/check-contract.sh --record   re-records the golden baseline
#
# The live probe spends a few tokens: it runs two tiny `claude -p` sessions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS="$ROOT/Contracts"
SPEC="$CONTRACTS/required-fields.json"
GOLDEN="$CONTRACTS/golden/hooks.jsonl"

MODE="static"
case "${1:-}" in
    --live)   MODE="live" ;;
    --record) MODE="record" ;;
    "")       ;;
    *) echo "unknown option: $1"; exit 2 ;;
esac

# Every check increments one of these. A run that ends with CHECKS at zero is a
# run that verified nothing, and it must fail rather than print a reassuring
# summary — the project has already shipped a test script that reported success
# after executing zero tests.
CHECKS=0
FAILURES=0
SKIPS=0

ok()   { CHECKS=$((CHECKS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
# Everything in this file is measured against another product's binary. When
# that binary is not here — a fresh machine, a build server — the honest answer
# is neither "passed" nor "failed" but "could not look", and it has to be said
# out loud: a checker that reports a failure for a missing tool teaches people
# to ignore its red, and one that reports success teaches them to trust a green
# that means nothing.
skip() { CHECKS=$((CHECKS+1)); SKIPS=$((SKIPS+1)); printf '  \033[33m⚠\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -f "$SPEC" ] || { echo "missing spec: $SPEC"; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────
head_ "Claude Code"

# `command -v` first: under `set -euo pipefail` a missing binary would kill the
# script with exit 127 right here, before the "claude not found" branch below
# ever ran. Found by a reviewer reading the script as a stranger would.
INSTALLED="$( (command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | awk '{print $1}') || true )"
EXPECTED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verifiedAgainst"])' "$SPEC")"

if [ -z "$INSTALLED" ]; then
    skip "claude is not on PATH — nothing here could be observed"
elif [ "$INSTALLED" = "$EXPECTED" ]; then
    ok "version $INSTALLED — the version the contract was verified against"
else
    # Not a failure on its own: a new version is normal. It is the reason to run
    # the live probe, which is what actually knows whether anything moved.
    ok "version $INSTALLED (contract recorded against $EXPECTED)"
    note "different version → run with --live before trusting the column"
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Hook registration"

SETTINGS="$HOME/.claude/settings.json"
SCRIPT_PATH="$HOME/.lampboard/hook.sh"

if [ ! -f "$SETTINGS" ]; then
    bad "no ~/.claude/settings.json"
else
    MISSING="$(python3 - "$SETTINGS" "$SCRIPT_PATH" "$SPEC" <<'PY'
import json, sys
from urllib.parse import urlsplit
settings, script, spec = sys.argv[1], sys.argv[2], sys.argv[3]
wanted = set(json.load(open(spec))["events"])
hooks = json.load(open(settings)).get("hooks", {})

# Both forms an installation takes, the same way `HookConfigMerger.isOurs` sees
# them: a command running our script, or an `http` hook posting at our loopback
# signal path. Recognising the script alone was right until 0.4.0 moved most
# events to the native form — after which this check went red on every machine
# running the current release and told people to reinstall, which would have
# changed nothing.
def ours(entry):
    if entry.get("command") == script:
        return True
    url = urlsplit(entry.get("url", ""))
    return (url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost")
            and url.path == "/signal")

registered = {
    event for event, groups in hooks.items()
    if isinstance(groups, list) and any(
        ours(entry)
        for group in groups if isinstance(group, dict)
        for entry in group.get("hooks", []) if isinstance(entry, dict)
    )
}
print(" ".join(sorted(wanted - registered)))
PY
)"
    if [ -z "$MISSING" ]; then
        ok "every event the contract needs is registered"
    else
        bad "events not registered: $MISSING"
        note "fix: lampboard install-hooks"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Files on disk"

python3 - "$SPEC" <<'PY' && ok "lock and session files carry the fields we read" || bad "see above"
import json, os, sys, glob
spec = json.load(open(sys.argv[1]))
home = os.path.expanduser("~")
problems = []

def check(pattern, fields, label):
    files = glob.glob(pattern)
    if not files:
        problems.append(f"no {label} found at {pattern}")
        return
    sample = max(files, key=os.path.getmtime)
    try:
        data = json.load(open(sample))
    except Exception as exc:
        problems.append(f"{label} unreadable: {exc}")
        return
    missing = [f for f in fields if f not in data]
    if missing:
        problems.append(f"{label} {os.path.basename(sample)} lacks: {', '.join(missing)}")

check(f"{home}/.claude/ide/*.lock", spec["lockFileFields"], "IDE lock")
check(f"{home}/.claude/sessions/*.json", spec["sessionFileFields"], "session file")

for p in problems:
    print(f"    {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

# ─────────────────────────────────────────────────────────────────────────────
head_ "Message delivery (rewake)"

# The chat window's send path depends on hook options Claude Code marks @internal.
# When they are renamed nothing errors — the message simply never arrives — so the
# only defence is asserting the names still exist in the shipped binary.
# Overridable so the rules that read it can be shown to bite: the thing this
# section checks is somebody else's binary, which no mutation can edit. Pointing
# it at a small file carrying a fake registry is the only way to watch these
# rules go red on purpose. Empty or missing, the checks say *could not look* and
# never *pass*.
CLAUDE_BIN="${CLAUDE_BIN:-$(readlink -f "$(command -v claude 2>/dev/null)" 2>/dev/null || true)}"
if [ -z "$CLAUDE_BIN" ] || [ ! -f "$CLAUDE_BIN" ]; then
    skip "claude binary not found — the message delivery contract was not examined"
else
    MISSING_OPTS=""
    for opt in $(python3 -c '
import json,sys
spec = json.load(open(sys.argv[1]))["rewake"]
print(" ".join(spec["hookOptions"] + spec["deliverySignals"]))
' "$SPEC"); do
        grep -a -q "$opt" "$CLAUDE_BIN" || MISSING_OPTS="$MISSING_OPTS $opt"
    done
    if [ -z "$MISSING_OPTS" ]; then
        ok "the asyncRewake options and the task-notification path are still there"
        note "@internal — no deprecation is owed to us; this check is the warning"
    else
        bad "message delivery is broken — absent from the binary:$MISSING_OPTS"
        note "the chat window will accept messages and silently never deliver them"
        note "see Contracts/assumptions.md -> rewake.mechanism"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Hook event inventory"

# The contract used to say "the eight events", which reads as "these are the
# events". There are thirty-one. Nothing would have reported a thirty-second
# appearing, or one we register being renamed out from under us.
if [ -z "${CLAUDE_BIN:-}" ] || [ ! -f "${CLAUDE_BIN:-}" ]; then
    skip "claude binary not found - the hook event inventory was not examined"
else
    python3 - "$SPEC" "$CLAUDE_BIN" <<'INVPY' && ok "the event list is the one recorded, and every event we register exists" || bad "the hook event inventory moved - see above"
import json, re, subprocess, sys

spec = json.load(open(sys.argv[1]))["hookEventInventory"]
blob = subprocess.run(
    ["strings", "-n", "12", sys.argv[2]], capture_output=True, text=True
).stdout
problems, notes = [], []

# The master list is the longest quoted run that starts where the enum starts.
found = None
for match in re.finditer(r'"PreToolUse","PostToolUse"(?:,"[A-Za-z]+")+', blob):
    names = re.findall(r'"([A-Za-z]+)"', match.group(0))
    if found is None or len(names) > len(found):
        found = names

if found is None:
    problems.append(
        "the hook event enum is no longer recognisable in the binary; every "
        "classification in the spec is now unverified"
    )
else:
    recorded = set(spec["all"])
    actual = set(found)
    for gone in sorted(recorded - actual):
        if gone in spec["registered"]:
            problems.append(
                f"{gone} is registered by this app and no longer exists in Claude "
                "Code - that traffic light transition is dead and silent"
            )
        else:
            notes.append(f"{gone} is gone; the spec still classifies it")
    fresh = sorted(actual - recorded)
    if fresh:
        notes.append(
            "new hook events, unclassified: " + ", ".join(fresh)
        )
        notes.append(
            "classify them in Contracts/required-fields.json -> hookEventInventory"
        )

# Every event in exactly one class, so the inventory cannot rot into a list
# that merely looks complete.
classified = set()
for key in ("decodedButNotRegistered", "decisionHooks", "teammateBoard",
            "notAboutTurnState"):
    classified |= set(spec[key]["events"])
classified |= set(spec["registered"])
for orphan in sorted(set(spec["all"]) - classified):
    problems.append(f"{orphan} is in the inventory but in no class")

for n in notes:
    print(f"    {n}", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
INVPY
    note "see Contracts/assumptions.md -> hook.events"
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Model context windows"

# The denominator of every saturation figure the panel shows. It is not in the
# transcript — a transcript says "claude-opus-5" and nothing about the window,
# and a session started with `--model sonnet`, no suffix, resolves to a 1M
# window. The number lives in Claude Code's own model registry, so this reads it
# back and reports anything that moved.
#
# A window that changed in a release and went unnoticed would not break the
# panel: it would make it divide by the wrong number, confidently, for everyone.
if [ -z "${CLAUDE_BIN:-}" ] || [ ! -f "${CLAUDE_BIN:-}" ]; then
    skip "claude binary not found - the model context windows were not examined"
else
    python3 - "$SPEC" "$CLAUDE_BIN" <<'CTXPY' && ok "every recorded context window is the one the binary carries" || bad "a model context window moved - see above"
import json, re, sys

recorded = json.load(open(sys.argv[1]))["modelContextWindows"]["windows"]
data = open(sys.argv[2], "rb").read().decode("utf-8", "ignore")

found = {}
for match in re.finditer(r'id:"(claude-[a-z0-9.-]{1,40})",', data):
    name = match.group(1)
    if name in found:
        continue
    # The window sits inside the same record; 1400 characters is past the
    # provider_ids block and short of the next model.
    window = re.search(r"window:\s*([0-9_e+.]+)", data[match.end(): match.end() + 1400])
    if window:
        found[name] = int(float(window.group(1).replace("_", "")))

problems = []
if not found:
    print("    no model registry found in the binary - this check read nothing", file=sys.stderr)
    sys.exit(2)

for name, window in sorted(recorded.items()):
    actual = found.get(name)
    if actual is None:
        problems.append(f"{name} is recorded here and no longer in the binary")
    elif actual != window:
        problems.append(f"{name} says {window:,}, the binary says {actual:,}")

# The same rule `ContextReading.parentOf` applies: a trailing one- or two-digit
# group on an id with more than two parts is a point release, and it borrows its
# parent's window. Kept in step with the Swift by hand, which is the cost of a
# checker that is not the thing it checks.
def parent_of(name):
    parts = name.split("-")
    if len(parts) > 2 and parts[-1].isdigit() and len(parts[-1]) <= 2:
        return "-".join(parts[:-1])
    return None


# A model the binary knows and this table does not. Two different situations
# wearing the same shape, and calling both a failure was wrong: a point release
# inherits its parent's window and gets a correct figure without being written
# down anywhere, which is the whole point of the inheritance added in 0.2.6.
#
# What matters for those is not whether they are listed, it is whether the number
# they inherit is the number the binary carries. A point release that quietly
# doubled its window would otherwise be divided by its parent's, confidently and
# for everybody — the exact failure this section exists to catch, one generation
# further down.
inherited = []
for name, window in sorted(found.items()):
    if name in recorded:
        continue
    parent = parent_of(name)
    if parent is not None and parent in recorded:
        if recorded[parent] != window:
            problems.append(
                f"{name} carries {window:,} and inherits {recorded[parent]:,} from {parent}"
                " - the point release moved the window")
        else:
            inherited.append(f"{name} inherits {window:,} from {parent}")
        continue
    problems.append(f"{name} ({window:,}) is in the binary and not in the table - sessions on it show no figure")

print(f"    {len(found)} models in the binary, {len(recorded)} recorded,"
      f" {len(inherited)} inheriting", file=sys.stderr)
for line in inherited:
    print(f"    {line}", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
CTXPY
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Models the transcripts actually carry"

# THE CHECK ABOVE HAS A BLIND SPOT, AND IT COST A DAY.
#
# It holds the table against the binary's registry, so it can only see a model
# both of them have heard of. On 2026-09-02 the transcripts were writing
# `claude-fable-5-1` while the table said `claude-fable-5` and Claude Code
# 2.1.251's registry said `claude-fable-5` too: two sources agreeing with each
# other about a model neither of them was being asked about. Every session on it
# drew a ring with no arc, which reads as "nothing measured" rather than "model
# unknown", and the check above stayed green throughout.
#
# So the third source is the ground truth for whether a ring will draw: the model
# ids a real transcript contains. It reads the user's own, because that is where
# the evidence is; it prints ids and never a path, a folder or a word anybody
# wrote.
if [ ! -d "$HOME/.claude/projects" ]; then
    skip "no transcripts on this machine - the models in use were not examined"
else
    python3 - "$SPEC" <<'SEENPY' && ok "every model a transcript carries resolves to a window" || bad "a model in use has no window - see above"
import json, re, sys, pathlib, itertools

recorded = json.load(open(sys.argv[1]))["modelContextWindows"]["windows"]


def stripped(model):
    parts = model.split("-")
    if parts and len(parts[-1]) == 8 and parts[-1].isdigit():
        return "-".join(parts[:-1])
    return model


def resolve(model):
    """Mirrors ContextWindows.window(for:). Returns (window, inherited-from)."""
    key = stripped(model)
    if key in recorded:
        return recorded[key], None
    parts = key.split("-")
    if len(parts) > 2 and len(parts[-1]) <= 2 and parts[-1].isdigit():
        parent = "-".join(parts[:-1])
        if parent in recorded:
            return recorded[parent], parent
    return None, None


root = pathlib.Path.home() / ".claude" / "projects"
files = sorted(root.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)[:80]
seen = set()
for path in files:
    try:
        with path.open("rb") as fh:
            fh.seek(max(0, path.stat().st_size - 400_000))
            blob = fh.read().decode("utf-8", "replace")
    except OSError:
        continue
    seen.update(re.findall(r'"model":"(claude-[a-z0-9.-]+)"', blob))

if not seen:
    print("    no model id found in any recent transcript - this check read nothing",
          file=sys.stderr)
    sys.exit(0)

problems, inherited = [], []
for model in sorted(seen):
    window, parent = resolve(model)
    if window is None:
        problems.append(f"{model} is in a transcript and resolves to no window"
                        " - every session on it shows a ring with no arc")
    elif parent:
        inherited.append(f"{model} borrows its {window:,} from {parent}"
                         " - confirm the point release kept the same window")

print(f"    {len(seen)} model id(s) in the last {len(files)} transcripts", file=sys.stderr)
for line in inherited:
    print(f"    inherited: {line}", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
SEENPY
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Where a session actually gets compacted"

# The other half of the denominator, and the half that nearly went in wrong.
#
# Claude Code's indicator counts down to a threshold BELOW the window -
# `window - min(maxOutputTokens, 20000) - 13000`, plainly readable in the binary.
# Three hand-readings of that indicator agreed with a denominator of 0.92 x
# window to within a point, and that number was one commit away from the code.
# It was wrong: the threshold is compared against Claude Code's own token
# estimate, not against the sum this project reads out of `message.usage`, and on
# the same compaction the two have been seen 0.4% apart and sixty-fold apart.
#
# So the transcripts get asked instead. Every `compact_boundary` with
# `trigger: "auto"` is a session that hit the ceiling; the last reply before it
# is our reading at that moment. A reading above 100% of the recorded window
# would mean the denominator is too small — that is what this fails on.
COMPACTION_REPORT="$(Scripts/measure-compaction.py 2>&1)" && COMPACTION_STATUS=0 || COMPACTION_STATUS=$?

case "$COMPACTION_STATUS" in
    0) ok "every reading sits inside its model's window"
       printf '%s\n' "$COMPACTION_REPORT" ;;
    # Exit 2 is "there was nothing to look at": no transcripts on this machine, a
    # fresh account, a build server. Not a pass and not a failure.
    2) skip "no auto-compaction has ever happened here - the denominator was not exercised"
       printf '%s\n' "$COMPACTION_REPORT" ;;
    *) bad "a session was read above its own window - the denominator in the table is too small"
       printf '%s\n' "$COMPACTION_REPORT" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
head_ "Background work (the reason a working session is not green)"

# The traffic light trusts Claude Code to have already filtered this list down to
# work the session is waiting on. That filter is the assumption, not the field, and
# it lives in the binary where nobody owes us a deprecation.
if [ -z "${CLAUDE_BIN:-}" ] || [ ! -f "${CLAUDE_BIN:-}" ]; then
    skip "claude binary not found - the background-work contract was not examined"
else
    python3 - "$SPEC" "$CLAUDE_BIN" <<'BGPY' && ok "the in-flight list is still filtered the way the column assumes" || bad "the background-work contract moved - see above"
import json, re, subprocess, sys

spec = json.load(open(sys.argv[1]))["backgroundTasks"]
blob = subprocess.run(
    ["strings", "-n", "12", sys.argv[2]], capture_output=True, text=True
).stdout
problems, notes = [], []

if spec["wireField"] not in blob:
    problems.append(
        f'the `{spec["wireField"]}` field is gone from the binary - every turn will '
        "look clean and green-during-work comes back in silence"
    )

for marker in spec["filterMarkers"]:
    if marker not in blob:
        problems.append(
            f"`{marker}` is gone: the filter that drops non-backgrounded work may "
            "no longer run, and unrelated tasks would hold rows yellow"
        )

if not re.search(spec["filterPattern"], blob):
    problems.append(
        "the running/pending filter is no longer recognisable. If it loosened, "
        "finished tasks now arrive and those rows stay yellow for ever; if it "
        "tightened, pending work is dropped and the row goes green in front of it"
    )

# Our two excluded types are Claude Code's own exclusion, read in its active-tasks
# view. If that view changes, the exclusion has to be re-examined either way.
if not re.search(spec["activeViewFilterPattern"], blob):
    problems.append(
        "Claude Code's active-tasks view no longer excludes remote_agent and dream "
        "the way it did; our notWorkTypes exclusion is unanchored and must be "
        "re-derived from the binary"
    )

# A status vocabulary that grew is safe by construction - the decoder counts
# anything it does not recognise as work - but it is worth saying out loud.
#
# Anchored on `task_updated` rather than on the words themselves: the binary holds
# half a dozen unrelated enums that also start with "pending" or "running", and one
# of them is the SQL keyword list.
# Every occurrence, not the first: the anchor appears in several places and only
# one of them is followed by the enum.
enum = None
for anchor in re.finditer(re.escape(spec["statusEnumAnchor"]), blob):
    window = blob[anchor.start():anchor.start() + 400]
    enum = re.search(r'\[("[a-z_]+",?){3,}\]', window)
    if enum:
        break
if enum:
    found = set(re.findall(r'"([a-z_]+)"', enum.group(0)))
    fresh = found - set(spec["knownStatuses"])
    if fresh:
        notes.append(
            "new task statuses, counted as work until classified: "
            + ", ".join(sorted(fresh))
        )
    for gone in set(spec["finishedStatuses"]) - found:
        problems.append(
            f"`{gone}` is no longer a task status; the decoder still denies it, "
            "which is now dead code hiding whatever replaced it"
        )
else:
    notes.append(
        f'could not locate the status enum near `{spec["statusEnumAnchor"]}` '
        "- the deny-list is unverified"
    )

for n in notes:
    print(f"    {n}", file=sys.stderr)
for problem in problems:
    print(f"    {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
BGPY
    note "see Contracts/assumptions.md -> hook.background_tasks"
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "Session transcripts"

# This one costs nothing and proves a lot: the transcripts are already on disk,
# by the thousand, written by every version of Claude Code that ever ran here.
# Sampling the most recent ones checks the format against reality rather than
# against a fixture we wrote ourselves.
python3 - "$SPEC" <<'PY' && ok "transcripts carry the fields the chat window reads" || bad "the transcript contract moved — see above"
import json, os, sys, glob

spec = json.load(open(sys.argv[1]))["transcript"]
home = os.path.expanduser("~")
files = glob.glob(f"{home}/.claude/projects/*/*.jsonl")
problems, notes = [], []

if not files:
    print("    no transcript found under ~/.claude/projects/", file=sys.stderr)
    sys.exit(1)

files.sort(key=os.path.getmtime, reverse=True)
sample = files[: spec["_sampleSize"]]

origin = spec["humanOrigin"]
known_assistant = set(spec["assistantBlocks"])
known_user = set(spec["userBlocks"])

humans = 0
titles = 0
seen_assistant = set()
seen_user = set()
missing_fields = set()

for path in sample:
    for line in open(path, errors="ignore"):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue

        kind = record.get("type")
        if kind == spec["titleRecord"]["type"]:
            if spec["titleRecord"]["field"] in record:
                titles += 1
            continue
        if kind not in ("user", "assistant"):
            continue

        missing_fields |= {f for f in spec["recordFields"] if f not in record}

        if kind == "user" and (record.get(origin["field"]) or {}).get(origin["key"]) == origin["value"]:
            humans += 1

        content = (record.get("message") or {}).get("content")
        target = seen_assistant if kind == "assistant" else seen_user
        if isinstance(content, list):
            target |= {b.get("type") for b in content if isinstance(b, dict)}

if missing_fields:
    problems.append(f"records lack fields we read: {', '.join(sorted(missing_fields))}")
if humans == 0:
    problems.append(
        f"no record with {origin['field']}.{origin['key']} == '{origin['value']}' in "
        f"{len(sample)} transcripts — the human-message discriminator is gone"
    )
if titles == 0:
    notes.append(f"no '{spec['titleRecord']['type']}' record found — chat windows fall back to the folder name")

for label, seen, known in (("assistant", seen_assistant, known_assistant), ("user", seen_user, known_user)):
    new = {b for b in seen if b and b not in known}
    if new:
        notes.append(f"new {label} block types: {', '.join(sorted(new))} — rendered as a placeholder until handled")

print(f"    {len(sample)} transcripts sampled, {humans} human messages found", file=sys.stderr)
for n in notes:
    print(f"    \033[33m→\033[0m {n}", file=sys.stderr)
for p in problems:
    print(f"    {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

# ─────────────────────────────────────────────────────────────────────────────
head_ "VS Code extension"

# VS Code and Cursor keep their extensions in different folders; a machine with
# neither is not a broken contract, it is one this check cannot see. Say so.
EXT="$(ls -d "$HOME"/.vscode/extensions/anthropic.claude-code-* "$HOME"/.cursor/extensions/anthropic.claude-code-* 2>/dev/null | tail -1 || true)"
if [ -z "$EXT" ] || [ ! -f "$EXT/extension.js" ]; then
    note "skipped — no Claude Code extension bundle under ~/.vscode or ~/.cursor; the deep-link contract is unverified here"
else
    python3 - "$SPEC" "$EXT/extension.js" <<'PY' && ok "the /open URI handler still reads session and prompt" || bad "the deep link contract moved"
import json, sys
spec = json.load(open(sys.argv[1]))["extensionPatterns"]
source = open(sys.argv[2], encoding="utf-8", errors="replace").read()
missing = [
    f"{name}: {pattern}"
    for name, pattern in spec.items()
    if not name.startswith("_") and pattern not in source
]
for m in missing:
    print(f"    absent from extension.js — {m}", file=sys.stderr)
sys.exit(1 if missing else 0)
PY
    note "$(basename "$EXT")"

    # Opportunities are checked the other way round: their disappearance is the
    # interesting event, and it never fails the run. Today the extension refuses
    # to apply a prompt to an already-open session; the day it stops refusing,
    # decision N7 is worth reopening.
    python3 - "$SPEC" "$EXT/extension.js" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1])).get("extensionOpportunities", {})
source = open(sys.argv[2], encoding="utf-8", errors="replace").read()
for name, pattern in spec.items():
    if name.startswith("_"):
        continue
    if pattern not in source:
        print(f"    \033[33m→\033[0m {name} is GONE — this may have become possible, see N7")
PY
fi

# ─────────────────────────────────────────────────────────────────────────────
run_probe() {
    # Records a real session's hooks into $1.
    #
    # The environment is scrubbed on purpose. CLAUDE_CODE_ENTRYPOINT is inherited
    # by child processes, so a probe launched from inside a Claude Code session
    # records the PARENT's entrypoint and quietly proves nothing. That mistake
    # produced a recording claiming `claude -p` reports `claude-vscode`.
    local out="$1" prompt="$2" tools="${3:-}"
    local work; work="$(mktemp -d)"

    cat > "$work/capture.sh" <<'CAP'
#!/bin/bash
BODY=$(cat)
printf '%s\t%s\n' "${CLAUDE_CODE_ENTRYPOINT:-<unset>}" "$BODY" >> "$CAPTURE_FILE"
exit 0
CAP
    chmod +x "$work/capture.sh"

    python3 - "$work" <<'PY'
import json, sys
work = sys.argv[1]
events = ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","Notification",
          "Stop","StopFailure","SessionEnd","SubagentStart","SubagentStop"]
hooks = {e: [{"hooks":[{"type":"command","command":f"{work}/capture.sh","timeout":5}]}]
         for e in events}
json.dump({"hooks": hooks}, open(f"{work}/settings.json","w"))
PY

    : > "$out"
    (
        cd "$work"
        CAPTURE_FILE="$out" env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE \
            claude -p "$prompt" --settings "$work/settings.json" \
            ${tools:+--allowedTools "$tools"} >/dev/null 2>&1 </dev/null
    ) || true
    rm -rf "$work"
}

if [ "$MODE" = "live" ] || [ "$MODE" = "record" ]; then
    head_ "Live probe"
    echo "  running two probe sessions, this takes about a minute…"

    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    run_probe "$TMP/plain.jsonl" "Reply with exactly the word: pong"
    run_probe "$TMP/agent.jsonl" \
        "Use the Task tool to launch one general-purpose agent whose entire job is to reply with the word: ok. Then reply: done." \
        "Task"
    cat "$TMP/plain.jsonl" "$TMP/agent.jsonl" > "$TMP/recording.jsonl"

    LINES="$(wc -l < "$TMP/recording.jsonl" | tr -d ' ')"
    if [ "$LINES" = "0" ]; then
        bad "the probe captured nothing — no conclusion can be drawn from this run"
        note "check that `claude` is authenticated and can run non-interactively"
    else
        ok "$LINES hook invocations captured"

        if [ "$MODE" = "record" ]; then
            mkdir -p "$(dirname "$GOLDEN")"
            # Scrubbed on the way in, not on the way out. What a probe records is
            # a real session on a real machine: the first recording carried the
            # operator's home directory into a public repository and stayed there
            # for weeks, because the guard meant to catch it was itself broken.
            # A recorder that writes the truth and trusts somebody to notice is
            # the same design that failed.
            python3 - "$TMP/recording.jsonl" "$GOLDEN" <<'SCRUB'
import re, sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source).read()
text = re.sub(r"/(Users|home)/[A-Za-z0-9][A-Za-z0-9._-]*", r"/\1/dev", text)
open(destination, "w").write(text)
SCRUB
            ok "golden baseline written to Contracts/golden/hooks.jsonl (home directory scrubbed)"
        fi

        python3 - "$SPEC" "$TMP/recording.jsonl" <<'PY' && ok "every event carries the fields we read" || bad "the payload contract moved — see above"
import json, sys
spec = json.load(open(sys.argv[1]))
required = spec["events"]
seen, problems = {}, []

for line in open(sys.argv[2]):
    entrypoint, body = line.rstrip("\n").split("\t", 1)
    payload = json.loads(body)
    event = payload.get("hook_event_name")
    seen.setdefault(event, []).append((entrypoint, payload))

for event, fields in required.items():
    if event not in seen:
        problems.append(f"{event}: never fired during the probe")
        continue
    for _, payload in seen[event]:
        missing = [f for f in fields if f not in payload]
        if missing:
            problems.append(f"{event}: missing {', '.join(missing)}")
            break

# The entrypoint is not in the payload — it only exists in the environment, which
# is why the hook script carries it in a header. Verify the value we record as
# non-interactive is the one a headless session really reports.
entrypoints = {e for values in seen.values() for e, _ in values}
excluded = set(spec["nonInteractiveEntrypoints"])
unlisted = entrypoints - excluded
if unlisted:
    problems.append(
        f"headless probe reported entrypoint {sorted(unlisted)}, "
        f"which is NOT in nonInteractiveEntrypoints — those sessions would get a row"
    )

for p in problems:
    print(f"    {p}", file=sys.stderr)
print(f"    events seen: {', '.join(sorted(seen))}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
    fi
else
    head_ "Live probe"
    note "skipped — run with --live to check the payload shapes against a real session"
    note "the static checks above cannot see a field that changed meaning"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Codex writes a rollout per session, and its own documentation says the format
# is not an interface. That warning is the reason this section exists: since the
# scanner reads the folder and the session id out of that file, a rename there no
# longer costs a percentage on a ring, it costs the row.
#
# Read from a real rollout on this machine rather than from a fixture, because a
# fixture only ever proves that the fixture still matches the parser.
head_ "Codex rollout shape"

CODEX_SESSIONS="${CODEX_HOME:-$HOME/.codex}/sessions"
# The directory is checked before `find` is asked about it, and the search is
# allowed to come back empty. Under `set -euo pipefail` a `find` on a path that
# does not exist ends the whole script: on a machine without Codex this gate died
# with exit 1 **before** printing the skip it was written to print, which is the
# one failure a gate must never have. A check that cannot say "I saw nothing" is
# not a check.
if [ -d "$CODEX_SESSIONS" ]; then
    ROLLOUT="$(find "$CODEX_SESSIONS" -name '*.jsonl' -type f 2>/dev/null | sort | tail -1 || true)"
else
    ROLLOUT=""
fi

if [ -z "$ROLLOUT" ]; then
    skip "no rollout on this machine, so nothing about Codex was verified"
    note "install Codex and run one session, then run this again"
else
    note "$(basename "$ROLLOUT")"
    if REPORT="$(python3 - "$ROLLOUT" <<'PY'
import json, sys

path = sys.argv[1]
records = []
with open(path, "r", encoding="utf-8", errors="ignore") as handle:
    for line in handle:
        try:
            records.append(json.loads(line))
        except Exception:
            pass

if not records:
    print("the file holds no readable record at all")
    sys.exit(1)

missing = []

# What the scanner needs to make a row exist at all.
first = records[0]
if first.get("type") != "session_meta":
    missing.append("the first record is `%s`, not `session_meta`" % first.get("type"))
else:
    payload = first.get("payload") or {}
    if not (payload.get("session_id") or payload.get("id")):
        missing.append("`session_meta.payload.session_id` (and `id`)")
    if not payload.get("cwd"):
        missing.append("`session_meta.payload.cwd` — the row would have no folder")

# What the ring needs. Absent is not a failure on its own: a session that has not
# answered yet has no token count, and the ring is drawn dashed for exactly that.
counts = [
    r for r in records
    if r.get("type") == "event_msg" and (r.get("payload") or {}).get("type") == "token_count"
]
if counts:
    info = (counts[-1].get("payload") or {}).get("info") or {}
    if "model_context_window" not in info:
        missing.append("`token_count.info.model_context_window` — the ring loses its denominator")
    if "last_token_usage" not in info:
        missing.append("`token_count.info.last_token_usage` — the ring loses its numerator")

# What tells activity from a file merely being written.
if not any(r.get("timestamp") for r in records):
    missing.append("`timestamp` on every record — the row could not say when")

# What tells a request somebody has to answer from one Codex answers itself.
# Without it every Codex permission request turns the row amber, including the
# ones nobody is waiting for: measured at 6.0 s, 6.4 s and 31.0 s in one audit.
# A rollout with no `turn_context` at all is not a failure — the record is
# written when the settings of a turn are established, and a session may not have
# reached one — but a `turn_context` that no longer carries the field is.
contexts = [r for r in records if r.get("type") == "turn_context"]
if contexts:
    payload = contexts[-1].get("payload") or {}
    if "approvals_reviewer" not in payload:
        missing.append(
            "`turn_context.payload.approvals_reviewer` — every Codex permission "
            "request would blink amber, including the automatic ones"
        )

version = ((records[0].get("payload") or {}).get("cli_version")) or "unknown"
if missing:
    print("recorded by Codex %s" % version)
    for item in missing:
        print(item)
    sys.exit(1)
print("recorded by Codex %s" % version)
PY
    )"; then
        ok "every field the scanner and the ring depend on is present"
        note "$REPORT"
    else
        bad "the rollout format has moved"
        printf '%s\n' "$REPORT" | while IFS= read -r line; do note "$line"; done
        note "Codex documents this format as unstable; the scanner fails closed,"
        note "so the symptom is a row that never appears rather than a wrong one."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────"

if [ "$CHECKS" = "0" ]; then
    echo "✗ no check ran. This run proves nothing."
    exit 1
fi

if [ "$FAILURES" = "0" ] && [ "$SKIPS" = "0" ]; then
    echo "✓ $CHECKS checks, all passing."
    [ "$MODE" = "static" ] && echo "  (static only — the semantic drift lives behind --live)"
    exit 0
fi

if [ "$FAILURES" = "0" ]; then
    echo "⚠ $SKIPS of $CHECKS checks could not look at anything."
    echo
    echo "  Nothing above is false, but nothing above was verified either."
    echo "  Install Claude Code and run this again before trusting the column."
    exit 3
fi

echo "✗ $FAILURES of $CHECKS checks failed${SKIPS:+, $SKIPS could not look}."
echo
echo "  Each failure above names an assumption. Contracts/assumptions.md says"
echo "  where the code depends on it and what breaks when it goes away."
exit 1
