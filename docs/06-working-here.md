# Working here

## What you need

Xcode's **Command Line Tools** (`xcode-select --install`). Full Xcode is not
required, and that isn't a convenience: it is the constraint that led to
`TestKit`, because without Xcode there is neither XCTest nor the complete
swift-testing.

macOS 14 or later. Swift 6, language mode 5.

## The loop

```bash
swift build                    # compile
./Scripts/test.sh              # both suites, then the documentation checks
./Scripts/build-app.sh         # bundle into dist/
./Scripts/release.sh           # only to hand it to somebody else
pkill -x lampboard; sleep 1; open dist/LampBoard.app
```

**The last line is not optional.** A new bundle does not replace the running
process, and a build that is an hour old is indistinguishable from a revoked
permission. It has already cost one wasted diagnosis.

## The two suites

```bash
swift run LampBoardTests              # 717 cases, instantaneous
swift run LampBoardE2E                # 98 cases, about a minute
swift run LampBoardTests "Subagents"  # filter by suite or by case
```

**`LampBoardTests`** verifies pure functions. It touches no network and, apart from the mailbox permission cases, which work
in a temporary root they delete, no filesystem.

Both suites print `Instrument proved: 19 checks, the assertions bite.` before
anything else. That line is the reason the count under it means something: one
early `return` added to `expect` once made all 717 cases report success while
verifying nothing at all, and nothing in the project would have said so. The
instrument is now calibrated before it is read, and a blunt one ends the run
with exit 70 rather than the 1 of an ordinary failure.

**`LampBoardE2E`** launches the production binary against a fake home
(`LAMPBOARD_HOME`) and talks to it over HTTP. It goes as far as running
`hook.sh` with the payload on stdin: in between sit bash, `curl`, the socket, the
HTTP parser, the decoder and the reducer.

It touches neither `~/.claude` nor the preferences, asks for no system
permissions, and deletes everything at the end — pass or fail. It uses port 9899,
never the real panel's 9877.

> **Why two.** In this project the worst defects have never been inside a
> function: they were in the seams. Title matching stayed broken for a whole day
> **with ten green tests**. See [07 traps](07-traps.md).

## Checking the documentation, and the checks

```bash
./Scripts/check-docs.sh    # ten gates, half a second
./Scripts/bite.sh          # breaks the repository on purpose, 26 seconds
./Scripts/test.sh          # build, both suites, then both of the above
```

`check-docs.sh` verifies the figures this documentation states — line counts,
file counts, test counts, the longest file — plus its links, its status table,
and that no real home directory or private address is committed. It prints three
things, not two: ✓ it looked and the claim holds, ✗ the claim is false, and ⚠ it
could not observe what it judges. **A green with a ⚠ in it is not a green**, and
it exits 3 to say so.

`bite.sh` is the one that judges the others. It commits twenty-seven violations — a
drifted figure, a broken link, a planted home directory, a suite nobody runs, an
assertion that has stopped asserting — and fails if any gate does not notice.
Every mutation is undone afterwards, including on Ctrl-C.

**This is not belt and braces.** One of those gates had never examined a single
file: it was built on a `grep` pattern this Mac's `grep` rejects, with the error
redirected away, and it printed a green tick for weeks over a real name sitting
in a tracked file. A check nobody has watched fail has not been distinguished
from a broken one.

Adding a gate without adding its mutation is itself a failing check — the two
lists are compared in both directions. [08 gates](08-gates.md) has the registry:
what each one claims, which tier it belongs to, and what proves it.

## Checking the contract with Claude Code

```bash
./Scripts/measure-compaction.py      # where a session really gets compacted, ~25 s
./Scripts/check-contract.sh          # static — seconds, free
./Scripts/check-contract.sh --live   # also records a real session, ~1 minute
./Scripts/check-contract.sh --record # re-record the golden baseline
```

This project leans on things nobody promised: hook event names and payload shapes,
the files the extension leaves on disk, a URI handler. `Contracts/assumptions.md`
names every one of them and says where the code depends on it; the script checks
what can be checked mechanically.

**Run `--live` after every Claude Code update.** The static tier catches "they
moved the furniture". Only the live tier catches the dangerous case: an event that
stops firing breaks nothing, raises nothing, and simply leaves the column frozen
on a state that is no longer true.

It **reports, it does not repair**. A script can notice that `session_id` became
`sessionId`; it cannot decide what that means, and a wrong automatic fix hides the
breakage. The report is the repair: it names the record, `assumptions.md` says
where the code leans and what the symptom looks like.

The first live run paid for the whole thing: it found `sdk-cli` missing from
`nonInteractiveEntrypoints` — the list had been written from documentation instead
of from an observation.

## Diagnosing

```bash
lampboard status                     # configuration, sessions, permissions
lampboard selftest                   # the whole chain, says which link broke
lampboard sessions                   # the column as the running app sees it
lampboard focus <project> --dry-run  # recognition without moving any windows
```

`sessions` and `next` talk to the **running instance**: the terminal process
knows nothing about the column's state, and asking it is the only way to get a
true answer instead of a plausible reconstruction.

### The log

```bash
pkill -x lampboard
LAMPBOARD_DEBUG=1 open dist/LampBoard.app
tail -f ~/.lampboard/debug.log
```

At startup it records the signature and the Accessibility permission **as the app
itself sees them** — which is the only way to really know, see below. On every
click it records which title it chose and, if it fell back, why.

### The endpoint

```bash
curl -H "X-LampBoard-Token: $(cat ~/.lampboard/token)" \
     http://127.0.0.1:9877/sessions | python3 -m json.tool
```

---

# The rules the project gives itself

These aren't general principles. Each one comes from a concrete mistake made
here, and each has a cost worth paying.

### The terminal seats

A click on a terminal row cannot be proven by a test: it needs a GUI and an
Automation permission. The check that was run for every host, and is worth
re-running after touching `TerminalFocuser` or a script: start a `claude` inside
the host in a folder no editor has open — from a shell **without** a Claude Code
session's environment (`env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION … claude`,
or a nested `claude` writes no session file and gets no row); turn terminal
sessions on; from another application run `lampboard open <slot>`; expect the
host in front with that tab selected, and in the log `seat of …: <host> …` then
`seat: … raised`. `open -a Terminal some.command` opens a Terminal tab running
a script with no permission at all, which is how the tmux check attached a
client. Launch the panel through LaunchServices (`open dist/LampBoard.app
--env LAMPBOARD_DEBUG=1`), never from a shell — see 07-traps, *The
permission that belonged to VS Code*.

## 1. Verify with the medium the app actually uses

Title matching stayed broken for a day with ten green tests, because it had been
verified with `osascript` while the app uses `NSAppleScript`: two transports that
serialize lists differently.

The same deception has a second form, discovered later: **launching the binary
from a terminal doesn't tell you whether the app has the permissions**, because
macOS attributes them to the responsible process — Terminal.

**In practice:**
- the socket is checked with `lsof` against the live process, not by re-reading the code
- the permissions are read by making **the app** write them down, in its log
- the hook script is tested by **running it**, not by simulating it

## 2. A regression test has to fail on the defect

Once you've written a test for a bug, **put the bug back** and watch the test go
red. A test that passes anyway isn't a test, it's decoration.

The startup crash outside the bundle was closed that way: red with `code 6`
(SIGABRT), green with the fix.

## 3. Restart the app after every build

See above. It has already cost one wasted diagnosis.

## 4. No checks that touch permissions, login items or notifications without saying so

Agents once registered a login item they then failed to remove, and made two
authorization prompts appear in the middle of the work.

The features that ask for permissions start **off**, and the request appears when
the user flips the switch — that is, when there is somebody there to read it.

## 5. One release at a time, and tested

Three consecutive fixes for three different symptoms of the same never-diagnosed
cause have already cost a day.

## 6. Every command that might wait on a dialog must be run with a deadline

`codesign` doesn't fail when the key's authorization is missing: it **hangs**. A
script that never returns is the worst diagnosis of all — it says less than one
that fails.

macOS has no `timeout` out of the box: it's done by hand with a background
process and a `kill -0` loop.

## 7. A script has to verify that it worked

`create-signing-identity.sh` used to print "✓ identity created" right after the
import. When the import failed, the error scrolled past, the build fell back to
ad-hoc **silently**, and the user found out days later from a click that didn't
work.

Now it signs a probe file and compares the `Authority` before declaring success.

## 8. Run what you ship

Of the nine defects found in two days, **three were in the one file that was
never executed** — the signing script. Everything else went through a build or a
test.

If you ship something you haven't watched work, that's the piece that will break.

---

# Contributing

## Where new code goes

**If it decides something, it goes in `LampBoardCore`.** The practical rule: if
a function contains an `if` answering a domain question — "does this session
deserve a traffic light?", "which window matches?" — it is in the wrong place if
it lives in the app.

Every time a decision slipped into the shell, it became invisible to the tests.

## Style

- **immutability**: produce new values, don't modify existing ones
- **small files**: 200–400 lines typical, 800 the limit; the longest today is 795
- **no magic values**: everything goes through `AppConfig`
- **comments explain the why**, not the what

On the tone of the comments: where they look verbose, they usually recount a
defect that cost dearly. If you shorten one, make sure the lesson survives
somewhere else.

## Adding a traffic light state

1. `SessionStatus`: the case, and the four properties (`urgencyRank`,
`shouldBlink`, `clearsOnFocus`, `blocksDowngrade`); then `SessionState.status`,
the switch that decides what an active subagent paints over it
2. `StatusPalette`: color, opacity, glow, label
3. `StateReducer.status(for:)`: which event it comes from
4. `TrafficLightRow.timeLabel`: what the right-hand slot shows
5. tests in `StateReducerSuite`, and **e2e** if the JSON contract changes
6. README: the state table

## Adding a hook event

1. `HookEventKind`: the case with the exact name — **verify it in the binary**
2. `HookPayloadDecoder`: the additional fields
3. `StateReducer`: the effect
4. `HookConfigMerger.defaultEvents`: **only if the cost justifies it** — and the same name in `Contracts/required-fields.json` → `hookEventInventory.registered` (removed from `decodedButNotRegistered`), or `check-docs.sh` fails
5. `HookPayloads` in E2E: the real shape, not an invented one
6. warn that an `install-hooks` is needed and that open sessions won't see it

```bash
# verify that an event really exists
strings -a ~/.local/share/claude/versions/2.1.247 | grep -c '"EventName"'   # or the version check-contract.sh reports
```

## Adding an editor

1. `IDEKind.all`: declared name, bundle, **process** name — read, not guessed
2. check that the title follows VS Code's grammar, or `WindowTitleMatcher` won't
   recognize it
3. tests in `IDEKindSuite`
4. **if you can't test it at runtime, say so** in the comment and in the
   documentation

```bash
defaults read /Applications/Name.app/Contents/Info.plist CFBundleIdentifier
defaults read /Applications/Name.app/Contents/Info.plist CFBundleExecutable
```

## Before saying it's finished

- [ ] `swift build` with no errors **and no warnings**
- [ ] both suites green
- [ ] if you fixed a defect: the test goes red when you put the defect back
- [ ] bundle rebuilt **and the app restarted**
- [ ] if you touched windows or permissions: verified from the app's log, not from the terminal
- [ ] documentation updated — [04 decisions](04-decisions.md) if you chose something non-obvious
