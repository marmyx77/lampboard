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
| Domain suite (1565 cases) | the pure logic behaves | filesystem | `bite.sh --swift` breaks a comparison and demands exit 1 | CI, `test.sh` | 1.9 s |
| The instrument (19 proofs) | the assertions can fail | filesystem | `bite.sh --swift`, three mutations of TestKit | every suite run, first | in the above |
| End-to-end suite (193 cases) | the real binary, over HTTP, against a fake home | filesystem | the suite launches the shipped binary; a broken build cannot pass it | CI, `test.sh` | 42 s |
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
| The Core builds for iOS | the Core, and NodeLink after it, compile for the iOS simulator, warnings as errors (D173, D175) | filesystem | `bite.sh --ios` imports AppKit into the Core | `test.sh` (Xcode with the iOS SDK) | 16 s the Core; NodeLink and its ssh stack a few minutes more |
| The Core builds and tests on Linux | the Core and the domain suite build on Linux, warnings as errors, and every case passes there; a write into a closed pipe does not end the process (D173) | filesystem | `bite.sh --linux` imports Darwin into the Core with no condition | a machine with docker, `Scripts/test-linux.sh`: **not** the test Mac | 25 s warm, 2 min cold |
| One protocol, every source | every `v1` source passes the conformance battery over a byte stream, held to a contract written by hand: hello and the state's age, a stream with no hole and no double across a reconnection, the low-power actions and nothing else (D174) | filesystem | `bite.sh --swift` renames a row's field in what the source writes and demands the battery name it | CI, `test.sh`, `Scripts/test-linux.sh` | in the domain suite |
| NodeLink over ssh | the `v1` conformance battery passes against the reference node behind a real OpenSSH, through NodeLink; a changed host key is refused before anything is opened; a read key asking for anything else gets `v1` and its command never runs; an unknown key is refused; a silent machine costs the deadline; the link resumes over ssh (D175). On a second node with the Linux machine's versions (OpenSSH 9.6p1, tmux 3.4): the terminal carries 10 MiB byte for byte and 1 MiB written whole, the read key's PTY is refused, a command's end is a normal one; through tmux a key reaches the pane and `window-change` resizes; with three clients the phone takes the size and the background rule gives it back to the Mac; the lights read over ssh make rows, follow changes and write nothing (D176) | filesystem | `bite.sh --nodelink` drops the read key's forced command, lets any host key in, renames a row's field, loses a byte of every terminal piece, lets the read key's line open a PTY, takes the detach out of the background rule, and makes the look at the lights write a file | a machine with docker, `Scripts/test-nodelink.sh`: **not** the test Mac | ~1.5 min warm, a few cold |
| The Mac as a source for the phone | the ssh server inside the app (W5, D180), reached in the same process by a phone made of NodeLink: the `v1` conformance battery against the Mac's source in memory and over a real ssh; a key the Mac never paired, and a changed host key, get nothing; the read key gets `v1` and nothing else; with «Terminal and actions from iPhone & iPad» off the action key gets `v1` only (Q17); a command, a shell or an unnamed action is refused with it on; the pairing code works once, inside its two minutes, not after three wrong ones, and only after the person's yes; a forgotten device is refused at its next connection, even one removed by hand; sixty connections of random bytes before authentication leave the server up; through the PTY bridge on a tmux of its own ❯ arrives intact with no `LANG`, `window-change` resizes, no client is left behind, the background rule detaches the phone's client (E14), 10 MiB cross the raw channel byte for byte, a background session open in the Hub is shared and never attached twice (counted); the named actions run as a node's do, Bypass refused until the Mac allows it; the panel's Move and a phone's take the same lock; a remote row's badge is its machine's initial. On the Mac, `MobileE2ESuite` does the same against the app itself | filesystem | `bite.sh --macsource` lets the read key through, ignores the switch, lets a pairing code work twice, makes the server die on bytes it cannot read, lets a forgotten device in from memory, drops tmux's `-u`, drops the detach from the background rule, lets a second attach through, ignores the Move's lock, marks a remote row `R` again, and renames a row's field | `test.sh`, and any machine with docker: `Scripts/test-mac-source.sh` | ~30 s warm |
| lampd on a fake node | `lampd`, built static as installed, behind a real OpenSSH with the Linux machine's versions (D178): its own suite; the conformance battery against `lampd v1-stdio`; one rule for the files — on three frames of recorded session files `lampd` and the phone's look give every session the same lamp; the read key `lampd devices add` wrote gets `v1` and no terminal, another network's phone and a revoked one stay out, the house's own lines are untouched; with the service stopped the read key still gets the lights, `mode: files`; the recorded hook flows reduce to the golden files the Mac's end-to-end suite is held to; the Core of the app one version behind reads it; the phone's actions as the app takes them (D179): a tagged tmux session and its row, Resume of a held conversation refused, End refusing a reused pid and a tmux session that does not hold the conversation, of two Moves at once one refused by the lock, `@name` arriving once, never a second `claude attach`, Browse and files held to the project, SFTP attachments that never overwrite, `lampd projects`, a low-power command through the read key; the node's tmux running with the options of `deploy/tmux/lampboard.conf` as installed (Q10, E14: `focus-events`, `extended-keys`, `allow-passthrough`), and `doctor` saying so | filesystem | `bite.sh --lampd` gives `lampd` a rule of its own for the files, makes `v1-stdio` exit 69 without the service, lets the read key's line open a PTY, drops a phone's `from=`, leaves a revoked phone's lines, drops the house's comments, replays an event twice, inverts the downgrade rule for an answer, raises `minClient`, copies an attachment over a file already there, writes a message into the box twice, lets End close whatever tmux session it is named, closes a tmux session other panes still use, and drops `focus-events` from the repository's tmux options; `bite.sh --swift` lets End signal a reused pid, a second Move miss the first one's lock, a Resume take a held conversation, and a second `claude attach` start beside the first | a machine with docker, `Scripts/test-lampd.sh`: **not** the test Mac | ~1.5 min warm, ~5 cold |
| lampd holding the hooks' port in tee (W5) | `lampd` holding the node's hooks' port, on the fake node and in its suite (D181): bound on `127.0.0.1` only; every route the Mac's `SignalServer` serves and the mod calls has one owner in `lampd`'s table, read from the code (`Scripts/check-lampd-routes.sh`); a hook carrying the token written before the switch is heard and changes the row's colour, a token that is not the hooks' is refused; each hook and report passed on to the Mac's end of the tunnel byte for byte, named with `X-LampBoard-Event`; with nobody there the hook is still heard and nothing waits; `/new`, `/chat`, an unknown route and a web page refused, none reaching the Mac; green, red and amber with the question from the hooks, a row no hook spoke for on the file's rule; a question the Mac holds makes the row amber with its text and the push leaves while it is held, the Mac's answer handed back untouched, an unsigned `ask` with no Mac; the Mac at the desk keeps the phone quiet for the node's amber, away or asleep it rings, a `here` gone stale or without its link is away; `lampd mac-link` beats and sends the choices, keeps the Mac's lines across a stopped service; the migration merged with the node's tie; a yellow the hooks cannot end rests on the file's minute of idle (D177), the idle compaction's flow reduced as the Mac reduces it and passed on unchanged; `lampd release` gives the port back | filesystem | `bite.sh --tee` drops a route's row, mints a token, passes `/new` on, binds every interface, passes events on unnamed, leaves a held question out of the row, forgets the Mac at the desk, keeps a `here` for ever, takes the files' idle away, and takes `LAMPD_HOOK_PORT` in a real home | a machine with docker, `Scripts/test-lampd.sh` | within `test-lampd.sh` |
| Honest pushes (W4) | a source notifies transitions only: ten amber rows at start ring nothing, amber rings four seconds into its spell and once, a question answered within four seconds never rings, the device last used rings and the others get a quiet copy two minutes later; a 410 from APNs is the one answer that drops a device; a push whose bytes read as what the envelope hides is never sent (§6.2: «Push oneste», «Il relay non legge») | filesystem | `bite.sh --swift` empties the announced memory, announces amber at once, rings every device at once, reads a 410 as a plain refusal, lets a readable envelope through; `bite.sh --lampd` keeps a gone token and updates the Live Activity at every look | CI, `test.sh`, `Scripts/test-linux.sh`, `Scripts/test-lampd.sh` | in the domain suite |
| The Mac's parity through the sweeps | the recorded flows played into the real app give `lampd`'s golden lamps after every event, each session with a process, and the last lamps hold through two sweeps beside a living neighbour | filesystem | `bite.sh --parity` plays the sessions with no process | `test.sh`, `Scripts/test-parity-e2e.sh` (a Mac) | ~40 s |
| lampd's watchdog | under `systemd --user`, with the settings of `deploy/lampd/lampd.service`, a loop stopped on purpose is killed and restarted within `WatchdogSec` while the age in `hello` climbs, and a stop with a phone attached tells it `bye` and is quick (D178, E10) | filesystem | `bite.sh --lampd` sends the heartbeat from a thread of its own | a Linux machine with `systemd --user`, `Scripts/test-lampd-watchdog.sh` | ~45 s |
| The contract on a node | lampd's contract timer runs the check from its installed copy on a machine without binutils: Claude Code is never run for its version, nothing crashes on a missing tool or a path relative to the checkout, nothing is red for ever because the machine is not a Mac (E5) | filesystem | `bite.sh --lampd` puts back each of the four defects: a note in backticks, a relative path, `strings` unasked, the editor's lock required | a machine with docker, `Scripts/test-contract-node.sh` | ~5 s |
| Every package is pinned | each package the dependency graph reaches has a pin in the committed `Package.resolved`, at the version the graph uses, and the build moved none (D175) | filesystem | `bite.sh --pins` removes BigInt's pin | `test.sh` | a few seconds |
| The Mac app links only its own | the app reaches no product of another package, as the manifest reads on a Mac, but the ssh server's four (swift-nio-ssh, swift-nio, swift-crypto) through `LampBoardMacSource` alone: Citadel, the client, is NodeLink's (D175, D180) | filesystem | `bite.sh --links` makes the app name NodeLink, then makes the Mac's server name Citadel | `test.sh` | 2 s |
| The tree is as it was found | the checks restore what they damage | filesystem | `git status` after everything | CI | instant |
| Who answers a Codex approval | a `turn_context` still names `approvals_reviewer`; without it every Codex permission request blinks amber, including the automatic ones | **external** | a rollout with the field removed is reported against | with the contract | in the above |
| Claude Code contract | hook events, payload shapes, `@internal` rewake options, the extension's files | **external** | the live probe (`--live`) runs real sessions | a person's machine, before a release | 29 s |
| Model context windows | every window in the table is the one the binary carries | **external** | a window edited in the contract is reported against the binary | with the contract | in the above |
| Where a session gets compacted | no reading ever exceeded its model's window | **external** | set the table to `0.92 × window` and it answers `108.6%`, twice, and exits 1 | with the contract | 24 s |
| A click lands where the row promises | the panel recognises where each session lives, and `--live` proves the window that came forward | **external** | the run names the build and its signature, and lists every surface it could not exercise | a person's machine, before a release | 4 s dry, ~2 s a row live |

`bite.sh` commits one hundred and five violations and demands one hundred and five catches. It takes 26
seconds.

## The two platform gates

The Core is built in three places (D173), and the Mac gate alone sees one of
them. The other two have scripts of their own, because each needs something a
machine may not have:

- `Scripts/test-ios.sh` needs Xcode with the iOS SDK. The test Mac has it, so it
  is part of `test.sh` and of every gate run there.
- `Scripts/test-linux.sh` needs a container engine, which the test Mac does not
  have. It runs where docker does — the Linux machine the agents work from — on
  a copy of the working tree, in the `swift` image pinned by digest, without a
  network once swift-crypto is fetched. It runs `Command`'s suite first on its
  own with `SIGPIPE` at its default, because the full run ignores the signal for
  the fixtures' sake and would otherwise hide a Core that stopped ignoring it
  itself: measured, the process dies with 141.

NodeLink over ssh is a third script of the same kind (D175). `Scripts/test-nodelink.sh`
needs docker too: it builds NodeLink and the reference node in the pinned image,
starts a node in a second container — OpenSSH, an account, a host key made for
the run, the read key forced to the reference node's `stdio`, the action key
with `restrict,pty` — on a network of its own with no port published, and runs
the conformance battery and the key bites through NodeLink against it. A second
node is the Linux machine as it is — Ubuntu 24.04 pinned by digest, so OpenSSH
9.6p1, tmux 3.4 and Python 3.12 — for the terminal, the size rule of Q7 with
three tmux clients, and the lights read over ssh (D176): the toolchain's image
carries newer ones, and the rule was measured on 3.4. What the
Mac app links, on the other hand, is read on the Mac, where the manifest says
what the app gets: `Scripts/check-app-links.sh` is part of `test.sh`, and is
the one that says ⚠ on Linux.

All of them answer with the three outcomes, and ⚠ is exit 3: "I could not look here".
`bite.sh` treats that as a bite not attempted, and says so, the way it treats
the mod where there is no `claude`. So on the test Mac the Linux bite is skipped
and announced; `Scripts/bite.sh --linux` is how it is proved, on a machine with
docker. A change to the Core is not done until that has run, and a change to
NodeLink not until `Scripts/test-nodelink.sh` and `Scripts/bite.sh --nodelink`
have.

`lampd` (D178) has three scripts of the same kind. `Scripts/test-lampd.sh` builds
the static binary with `Scripts/lampd-build.sh`, puts it on a node with the Linux
machine's versions as `Scripts/lampd-install.sh` would, lets `lampd devices add`
write the phone's lines into an `authorized_keys` that already holds the house's
own, plays Claude Code's session files frame by frame (`Tests/NodeFixture/`), and
asks it, through NodeLink, everything the phone will. `Scripts/test-lampd-watchdog.sh`
runs the binary under this machine's `systemd --user` in a transient unit with the
repository unit's settings and a home of its own. `Scripts/test-contract-node.sh`
runs the contract check as the timer does. A change to `lampd` is not done until
the three and `Scripts/bite.sh --lampd` have run.

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
