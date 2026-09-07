# 08 · The gates, and what proves them

Every automated check in this repository is listed here, with the thing it
claims, the thing that proves it still works, and where it runs.

The list exists because of two afternoons.

**The first.** `Scripts/check-docs.sh` had a guard against committing a real
home directory to this public repository. It was a shell pipeline built on
`grep -nIE '/Users/(?!dev|you|sam|me)…'`, with `2>/dev/null` on the end and
`|| true` after it. `/usr/bin/grep -E` has no lookahead: it answers
`repetition-operator operand invalid` and exits 2. Every run threw the error
away, matched nothing, and printed a green tick. The guard had never read a
single file, and `Contracts/golden/hooks.jsonl` had carried a real name the
whole time. Nothing about that was visible from the outside — a working guard
and a broken one print exactly the same thing.

**The second.** Adding one `if true { return }` to `expect` in
`Sources/TestKit/Assertions.swift` made every domain test report success
while verifying nothing at all. No warning, no clue, a full green.

Both failures are the same shape: **absence mistaken for permission**. A search
that finds nothing, a guard that cannot run, a test that cannot fail — each
produces silence, and silence gets read as "all clear". So every check here now
has to answer two questions, not one: *is the claim true*, and *could I have
noticed if it were not*.

## The three outcomes

A checker that only knows "pass" and "fail" has to pretend it looked when it
could not. All three scripts print, and exit, in three ways:

| | Meaning | Exit |
|---|---|---|
| ✓ | it looked, and the claim holds | 0 |
| ⚠ | it could not observe the thing it judges | 3 |
| ✗ | the claim is false | 1 |

A green with a skip in it is not a green, which is why ⚠ does not exit 0.

## Tiers

Not everything that can be checked belongs in a blocking gate.

| Tier | Observes | May block |
|---|---|---|
| `filesystem` | files in this checkout | yes |
| `git-ref` | this repository's own history | yes |
| `external` | another product's binary, the network, a machine | **no** |

The rule is not about importance — the external checks are the ones guarding the
assumptions this whole project balances on. It is about what a red light *means*.
A gate that reddens because somebody else shipped a release, or because a build
machine has no Claude Code installed, teaches people that red is noise. Once
that lesson is learned it applies to every red, including the true ones.

`smoke-clicks.sh` is external for a sharper version of the same reason: it needs
a screen, an unlocked session, and other people's applications actually running.
On a locked Mac it can prove nothing at all — measured, the night the window
server refused to bring anything forward — and a check whose answer depends on
whether somebody walked away from the keyboard cannot be a condition for
merging.

## The registry

Measured on an M-series Mac, 29 August 2026.

| Gate | Claims | Tier | Proven by | Runs in | Time |
|---|---|---|---|---|---|
| Domain suite (717 cases) | the pure logic behaves | filesystem | `bite.sh --swift` breaks a comparison and demands exit 1 | CI, `test.sh` | 1.9 s |
| The instrument (19 proofs) | the assertions can fail | filesystem | `bite.sh --swift`, three mutations of TestKit | every suite run, first | in the above |
| End-to-end suite (98 cases) | the real binary, over HTTP, against a fake home | filesystem | the suite launches the shipped binary; a broken build cannot pass it | CI, `test.sh` | 42 s |
| Figures in the code map | every stated line count, file count and case count | filesystem | `bite.sh` drifts a figure, then rewords the table away | CI, `test.sh` | 0.5 s (all nine) |
| Links between documents | every relative link and anchor resolves | filesystem | `bite.sh` breaks a link, then deletes a guarded document | CI, `test.sh` | ” |
| Figures outside the code map | README and docs state the same numbers | filesystem | `bite.sh` drifts one, then rewords the sentence away | CI, `test.sh` | ” |
| The status table | WORKLOG's "how the project stands now" is now | filesystem | `bite.sh` drifts a figure, then renames the table | CI, `test.sh` | ” |
| No personal paths | no real home, VPN address or `user@host` in tracked files | filesystem | `bite.sh` plants a leak, plants an address, **and blinds the guard** | CI, `test.sh` | ” |
| Nothing is written in Italian | every tracked file is English: documents, comments, test names, script output | filesystem | `bite.sh` plants a sentence, **and empties the word list** | CI, `test.sh` | ” |
| The registered events | the contract and `HookConfigMerger` agree; prose states the right count | filesystem | `bite.sh` removes an event, ages the prose, rewords it away | CI, `test.sh` | ” |
| Test suites are registered | no suite exists that the runner never calls | filesystem | `bite.sh` unregisters one | CI, `test.sh` | ” |
| Every file is on the map | nothing shipped, and no script, is written about nowhere | filesystem | `bite.sh` erases a file's row, then a script's | CI, `test.sh` | ” |
| The stated mutation count | the number of mutations the documents claim is the number `bite.sh` runs | filesystem | `bite.sh` drifts the count, then rewords every sentence stating it away | CI, `test.sh` | ” |
| Every gate bites | each gate above has a mutation that turns it red | filesystem | `bite.sh` adds a gate with no bite | CI, `test.sh` | ” |
| The tree is as it was found | the checks restore what they damage | filesystem | `git status` after everything | CI | instant |
| Who answers a Codex approval | a `turn_context` still names `approvals_reviewer`; without it every Codex permission request blinks amber, including the automatic ones | **external** | a rollout with the field removed is reported against | with the contract | in the above |
| Claude Code contract | hook events, payload shapes, `@internal` rewake options, the extension's files | **external** | the live probe (`--live`) runs real sessions | a person's machine, before a release | 29 s |
| Model context windows | every window in the table is the one the binary carries | **external** | a window edited in the contract is reported against the binary | with the contract | in the above |
| Where a session gets compacted | no reading ever exceeded its model's window | **external** | set the table to `0.92 × window` and it answers `108.6%`, twice, and exits 1 | with the contract | 24 s |
| A click lands where the row promises | the panel recognises where each session lives, and `--live` proves the window that came forward | **external** | the run names the build and its signature, and lists every surface it could not exercise | a person's machine, before a release | 4 s dry, ~2 s a row live |

`bite.sh` commits twenty-seven violations and demands twenty-seven catches. It takes 26
seconds.

## The rule

**No gate without a bite.** A check nobody has ever seen fail has not been
distinguished from a broken one — that is not a metaphor here, it is what
happened.

The link is mechanical, and it runs in both directions: `check-docs.sh` reads
its own section titles and the `gate "…"` lines in `bite.sh`, and reports a gate
with no mutation *and* a mutation for a gate that no longer exists. Adding a
check without proving it works is itself a failing check.

Three things have to hold for a bite to count:

1. **the mutation changed something.** A find-and-replace whose target has been
   renamed applies cleanly to nothing and proves nothing, so `bite.sh`
   fingerprints the files first and fails if they come back identical;
2. **the gate exited non-zero**;
3. **it said why, in the words that attack expects.** "Something went red" is
   not a proof — the gate could have tripped over something unrelated.

And a mutation must not name today's numbers. A bite anchored to `497 domain
tests` breaks the next time that figure legitimately changes, and a bite that
needs maintaining is a bite that gets deleted; they find the current value and
change it instead.

## What is deliberately not mechanized

Prose. A script can tell that a sentence claims eight events when nine are
registered; it cannot tell that a paragraph describes a design abandoned in
June. That is the semantic audit — a person, or an agent reading with fresh
eyes — and it is what found the stale status table that eight green checks had
walked past. See `Scripts/check-contract.sh --live` for the equivalent on the
Claude Code side: the static checks can see a field that vanished, never one
that changed meaning.

A gate that tried to judge prose would be wrong often, and a gate that is wrong
often is a gate that gets ignored — including on the day it is right.
