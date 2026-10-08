# Work log

Chronicle of the autonomous execution of the [plan](PLAN.md), 29 July 2026.
Every entry says **what** changed, **why**, and **how it was verified**.

## Rules I gave myself for working alone

The user was unreachable, so I worked under tighter constraints than usual. Three
things I did not do, and not out of forgetfulness:

1. **No password or keychain prompts.** `create-signing-identity.sh` is left to be
   run: it asks for the keychain password, and a dialog left open for hours is not
   something to do to somebody who isn't there.
2. **No system authorizations requested behind anyone's back.** Notifications and
   the presence file are **off by default**: you turn them on from the menu, and
   that is where the system prompt appears — when there is somebody to read it.
3. **No login item registered.** With an ad-hoc signature it would leave orphaned
   records behind, and that has already happened once in this story.

**I changed one rule halfway through, and it's worth saying why.** I had decided
not to touch `~/.claude/settings.json`. Then I verified that without registering
`SubagentStart` and `SubagentStop` the subagent counter **never receives
anything**: the most important feature of the day would have stayed inert waiting
for a command nobody knew about. The plan itself called it necessary ("Requires:
re-installing the hooks").

I ran `install-hooks`. The operation is additive — two extra events pointing at
the same already-registered script — it creates a dated backup, and it is undone
with `uninstall-hooks`. Verified afterwards by comparing the file with the earlier
copy: no key lost, no key modified outside `hooks`, no third-party hook touched.
Backup at `~/.claude/settings.json.lampboard-backup-20260729-195635`.

All the automated test runs go through a fake home regardless.

---

## Phase 0 — Foundations

### F0.1 · Path isolation — `LAMPBOARD_HOME`

`AppConfig` derived every path from `homeDirectoryForCurrentUser`. Convenient, but
it makes an honest end-to-end test impossible: either you touch the user's real
`~/.claude`, or you bypass the production code and verify something other than
what actually runs.

Now every path descends from `AppConfig.homeDirectory`, which honors the
`LAMPBOARD_HOME` variable.

A detail worth remembering: **rewriting `$HOME` would not have been enough**.
`homeDirectoryForCurrentUser` reads from `getpwuid`, not from the environment, and
relying on it would have created the illusion of an isolation that isn't there.

The preferences are isolated too: with the variable set, `Preferences` uses a
separate `UserDefaults` domain, otherwise a test that switched a notification on
would leave it on afterwards.

**Files**: `AppConfig.swift`, `Preferences.swift`

### F0.2 · `--headless` mode

The app starts with the server and the realignment but no panel. It serves the
e2e tests, which have to run *this* binary without depending on a graphical
session.

**Files**: `AppDelegate.swift`, `CommandLineInterface.swift`, `main.swift`

### F0.3 · Security defect: the server was listening on every interface

It wasn't in the plan. I found it looking at `lsof` before adding an endpoint that
exposes the project names:

```
clawd-lig 32486 dev 4u IPv6 ... TCP *:9877 (LISTEN)
```

`*:9877` means the socket was reachable **by anyone on the same network**. The
code relied on `NWParameters.acceptLocalOnly`, which looks like it says "this
machine only" and actually says "this network link only" — that is, the Wi-Fi the
Mac is attached to.

Anyone who got there could inject signals and drive the panel's state. With the
read endpoint it would also have become a listing of the open projects.

**Correction**: `parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), …)`,
which really does constrain the bind.

**Verification**: an e2e case queries `lsof` against the live process and fails if
an address appears that doesn't start with `127.0.0.1`. It verifies the fact, not
the intention — which is exactly the distinction the defect had slipped through.

**Files**: `SignalServer.swift`, `TransportSuite.swift`

### F0.4 · `GET /sessions` with a token — *plan 5.1*

Brought forward from phase 5 because without a way to observe the state from
outside there are no e2e tests.

- `SessionSnapshot` / `SessionsResponse`: a contract type separate from
  `SessionState`, so an internal refactor doesn't break its consumers
- ISO 8601 dates — a numeric timestamp forces every reader to guess the unit, and
  whoever guesses wrong doesn't find out
- a 24-byte token in `~/.lampboard/token`, mode `0600`
- **constant-time** token comparison: an `==` bails out at the first differing
  byte and the time it takes says how many leading characters were right
- if the file's permissions turn out wider than `0600` the token is
  **regenerated**, not repaired: a secret that has been readable is burned

`POST /signal`, by contrast, stays **without** a token, and that is a choice: the
hook script runs as the user and could read it, but a hook that fails
authentication would block a Claude Code turn because of a decorative widget. The
risk is asymmetric.

**Files**: `SessionsPayload.swift`, `AccessToken.swift`, `TokenStore.swift`,
`SignalServer.swift`, `SnapshotBox.swift`

A design note: the server reads the state from a lock-protected `SnapshotBox`
instead of crossing the boundary with `DispatchQueue.main.sync`. That would have
worked right up until somebody, on the main queue, waited for something that goes
through the server's queue — that is, until somebody introduced the deadlock.

### F0.5 · End-to-end harness

`swift run LampBoardE2E` launches **the real binary** against a fake home and
talks to it over HTTP, the way the hooks do.

It exists for a precise reason: window title matching stayed broken for an entire
day **with ten green tests**, because it had been verified with `osascript` while
the app uses `NSAppleScript` — two transports that serialize lists differently.
The defect lived in the seam between the tested function and the real world.

The hook payloads are not invented: the shapes were taken from binary 2.1.220 with
`strings`. `SubagentStop` carries `agent_id`, `agent_type` and
`last_assistant_message`; `SubagentStart` only the first two.

**Files**: `Sources/LampBoardE2E/`

---

## Phase 1 — Coverage

### 1.1 · Integrated-terminal sessions

`AppConfig.vsCodeEntrypoints = ["claude-vscode"]` discarded every session started
with `claude` from the terminal **inside** VS Code: same window, same project,
same click that would have brought it forward, and no traffic light.

The fix was not to widen the list. Future entrypoints are unknown, and an
allow-list punctures itself with every Claude Code release — silently, because a
missing row doesn't complain.

The criterion was **inverted**: what counts is *where* the session runs, not how
it was started. If the `cwd` sits inside a folder an IDE has open, the session is
in that window. A **deny**-list remains (`nonInteractiveEntrypoints`) for what
nobody is watching: when it's wrong it shows one row too many — a mistake you can
see — instead of hiding one.

For sessions read from the filesystem the best criterion is the `kind` field,
which Claude Code writes itself; the entrypoint stays as a fallback.

**Files**: `HookSignal.deservesTrafficLight`, `LiveSession.deservesTrafficLight`,
`AppConfig`, `StateReducer`

### 1.2 · Subagent counter

Verified before implementing, with `strings` on binary 2.1.220: `SubagentStart`
and `SubagentStop` **exist** (8 and 17 occurrences).

The plan said "`Stop`/`SessionEnd` reset the counter". **Implementing it revealed
that this is wrong**, and the discovery changed the project.

With background agents the real sequence is:

```
SubagentStart ×N  →  Stop (the parent turn returns control)
                  →  … the agents work for tens of minutes …
                  →  SubagentStop ×N
```

Resetting on `Stop` restores green **exactly during** the work: the very lie this
feature existed to remove.

The model adopted: **the displayed state is derived**.

```swift
public var status: SessionStatus {
    guard activeSubagents > 0 else { return baseStatus }
    return baseStatus == .awaiting ? .awaiting : .working
}
```

`baseStatus` is what the hooks say for the main turn; `status` is what the traffic
light shows. It follows on its own that when the last agent finishes, the green
set aside **resurfaces without anyone having to remember it**. Waiting for a
permission wins regardless: it blocks everything.

The counter resets at the **user's prompt**, not at the end of the turn: it is a
certain boundary and it doubles as a safety net if a `SubagentStop` gets lost
along the way — otherwise the row would stay yellow until the 12-hour pruning.

A subtlety that cost some thinking: the rule protecting green from late signals
now compares `baseStatus`, not the displayed state. A session with green waiting
and agents in flight *appears* yellow, and using the appearance would have made
legitimate precisely the downgrade that rule prevents.

**Files**: `SessionState`, `HookSignal.subagentDelta`, `HookEventKind`,
`StateReducer.applySubagent`, `HookConfigMerger.defaultEvents`

**Requires re-running `install-hooks`** to register the two new events.

---

## Phase 0.2 — Per-row context menu

It unblocked five later proposals, and indeed all five lean on it.

The known friction — a menu on the row shadows the panel's one — was resolved by
**not duplicating** the global entries. The row menu has eight entries, the
panel's twelve: adding them up would make twenty, and a twenty-item menu cannot be
read. The general menu stays reachable from the panel's margins.

**Files**: `TrafficLightRow.swift` (`RowActions`, `RowFlags`), `PanelRootView.swift`

---

## Phase 2 — Scale

All the logic lives in `ColumnLayout`, a pure function: same state and same
options, same rows. Grouping, filtering, pinning and the summary are a single
computation, verifiable without drawing anything — eighteen test cases.

### 2.1 · One row per project — on by default

The measured numbers: 22 distinct sessions across 12 windows. One row per session
drew 22 targets for 12 raisable windows.

The risk the plan flagged — the loss of granularity — was addressed where it
arises: `sessionIdsToClear` returns **only the sessions that were in the most
urgent state**. Opening a project to answer a permission must not erase the ready
answer of another session in the same project.

Verified on real data: 10 sessions → 5 rows, and the panel measured 134 px, that
is, exactly five rows. Two independent measurements that agree.

### 2.2 · "Only what's waiting" filter

The risk flagged was movement: a panel that changes height on every transition. I
didn't remove it — the height follows the rows, and that is what keeps the widget
small — but I removed the lie that came with it: the filter **says how many
sessions it is keeping out** (`and 7 more with nothing new`). A column with two
rows must not suggest there are only two sessions.

Pinned projects survive the filter: pinning them means wanting to see them always,
and a filter that hides them drains pinning of its meaning.

### 2.3 · Pin to top, hide

The hidden summary row **lights up** when one of them asks for attention — with
the same dot, blinking included. The plan called it mandatory and it was right:
without it, "hide" becomes "forget", which is the harm the panel exists to prevent.

Pinned rows carry a discreet vertical rule: without a mark, "pin to top" just
moves a row, and among ten rows there's no telling why that one is sitting there.

---

## Phase 3 — Attention

All three features are **off by default**, and none asks for a system permission
until you turn it on. With the user away it was the only possible choice, but it
is also the right one in steady state: an authorization prompt should be shown to
somebody who has just asked for it.

### 3.1 · Notify only for `awaiting`

Never for `ready`. A ready answer can wait until you look at it; a permission
can't — until you answer, that work is stopped.

A set of already-announced sessions prevents duplicates: the column updates
continuously, and without a memory every recomputation would resend the same
notification. Anything that becomes unblocked is a candidate again, so a new block
tomorrow is a new alert.

Clicking the notification takes you **to that session**: the `sessionId` travels
in `userInfo`. An alert that says "something is waiting" and then leaves you to
find out which has saved nobody anything.

**Not verified at runtime**: delivery requires the bundle and the authorization,
which I didn't request. The code protects itself — outside a bundle
`UNUserNotificationCenter` terminates the process, so there is a check on
`Bundle.main.bundleIdentifier` before every use.

### 3.2 · The gate

`occlusionState` comes out wrong at app startup, so on its own it would suppress
legitimate alerts. It is combined with keyboard inactivity
(`CGEventSource.secondsSinceLastEventType`, which requires no permissions and
doesn't read *what* was pressed, only *when*). When in doubt the notification
fires: a gate that is too closed is worse than no notification.

> **Later note (30 July).** Tested live, the presence condition suppressed
> everything: the panel is floating, so it is always visible, and if you're at the
> Mac you're active. The gate was reduced to the explicit silences only.

### 3.4 · Muting

Per project or for an hour. It silences the **alerts**, never the color: a muted
row stays visibly so in the tooltip, otherwise it would become a deletion you
forget you performed.

### 3.5 · Presence file

`CLAUDE_CLIENT_PRESENCE_FILE` verified present in binary 2.1.220.

Off by default because it **inverts a built-in behavior**: if the detection gets
it wrong, the result is not one notification too many but a notification lost, and
lost notifications go unnoticed. When the app closes the file is deleted — leaving
it would say "I'm at the Mac" forever.

### 3.3 · Summary on return — **not done**

The plan excluded it until 3.1 proved noisy. With 3.1 off by default, that
evidence doesn't exist yet.

---

## Phase 4 — Row actions

**4.1 alt+click** peeks without consuming the green, and `markedUnread` remedies
one click too many. The menu entry exists because a modifier nobody discovers is
dead code.

**4.2 silence the blink** stops the movement, not the signal: the amber stays.

**4.3 new conversation** uses the same deep link without the `session` parameter.
The risk flagged — making it easy to multiply sessions — is still real, but with
2.1's grouping an extra session is no longer an extra row.

**4.4 permissions from the row**: **not done**, as planned. The
`PermissionRequest` hook blocks the turn until it answers: if the panel isn't
running, every request hangs.

---

## Phase 5 — Integration

**5.1** brought forward to phase 0 (see above).

**5.2 `next`** talks to the running instance over `POST /next`, authenticated. It
is a route that **raises windows**, not one that colors dots, and the separation
matters: it deserves authentication even where the other has none.

**5.3 the ⌃⌥⌘L shortcut** with `RegisterEventHotKey`. The failure **is not
swallowed**: if the combination is taken, the switch goes back off and an alert
appears. A shortcut that doesn't fire is worse than no shortcut, because you stop
looking at the column in exchange for nothing.

> **Later note (30 July).** Tested live: the API returns `noErr` and never
> delivers the event, and the app cannot notice. The feature was **removed** —
> see [04 decisions · N6](docs/04-decisions.md#n6--a-global-shortcut-inside-the-app).

**5.4 launch at login** implemented but it **refuses to register with an ad-hoc
signature**, and the menu entry stays disabled. This is not theoretical caution:
in this project a login item registered by a process that then failed to remove it
has already happened. `CodeSignature.isAdHoc` reads `codesign -dv` once at
startup; when in doubt it assumes ad-hoc, which is the harmless failure of the two.

---

## Phase 1.3 — Other IDEs: done, with a stated limit

The plan excluded it "until there is a way to test it", with the prerequisite
"having Cursor installed". Verified: Cursor **is** installed and has the Claude
Code extension (`anthropic.claude-code-1.0.33`). The prerequisite is satisfied.

Implemented `IDEKind` with a **deliberately short** table: only the editors whose
declared name, bundle identifier and process name are known, and whose window
title follows VS Code's format. Cursor is a fork, so locks and titles are
identical; only the three names differ. The bundle identifier
(`com.todesktop.230313mzl4w4u92`) was **read** from the `Info.plist`, not guessed.

Recognition of "Visual Studio Code - Insiders" was added too, which the equality
comparison discarded.

**Stated limit**: no Cursor lock existed at the time of the work (all 12 said
"Visual Studio Code"), so the activation path on Cursor is **not verified at
runtime**. Recognition and routing are under unit test; the last mile is not.

---

## Defects found while I worked

None of the three was in the plan. Two were found by the end-to-end suite.

**1. The server was listening on every interface.** See F0.3. Reachable by anyone
on the same network.

**2. Two installations in the same second failed.** The `settings.json` backup
name carries the date down to the second, and `copyItem` refuses to overwrite: the
error bubbled up and failed the installation, with a message about the backup while
the problem looked like something else. You meet it by installing, uninstalling
and reinstalling in three clicks. Now there's a counter.

**3. The columns of `lampboard sessions` were jammed together.**
`String(format:)` honors a width on C's placeholders but **ignores** it on `%@`.
Explicit padding.

**4. "New conversation here" opened two tabs.** Found by re-reading the code, not
by a test. The path raised the window passing the `sessionId` — so it opened the
existing session's tab — and immediately afterwards opened a new one. No test
could have seen it: the deep link runs as a separate process and nobody observes
its effect. Activation now takes a parameter to **not** open the tab, used only
from here.

It's worth noting that the first three were found by automated verification and
the fourth wasn't. A defect living outside the process — in an `open` that fires
and doesn't return — stays invisible to any suite, and the only tool against that
category is re-reading the path in full.

---

## What the review found, afterwards

I had the new code re-read by an independent reviewer. It found six things; five
were real. I report them because two are defects **I introduced today** and that
my own tests didn't see.

### A startup crash, introduced today

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'bundleProxyForCurrentProcess is nil'
8  LampBoardApp  AppDelegate.startNotifier(for:)
```

`UNUserNotificationCenter.current()` outside a `.app` bundle **does not return
nil**: it raises an exception and terminates the process. I had put the guard
inside `SessionNotifier`, where it was needed, and forgotten it on the line
assigning the delegate. Result: `swift run LampBoardApp` during development died
before drawing the panel.

**Why no test saw it**: the entire end-to-end suite runs `--headless`, and
`--headless` skips `startInterface()`. I had built a test run that never went
through the branch with the interface on.

Now there is a case that starts the bare binary **without** `--headless` and
checks it is still alive after two and a half seconds. I tested it in reverse, by
putting the defect back: it goes red with `code 6` (SIGABRT) and green with the
fix. A regression test that doesn't fail on the bug is worth nothing.

### An error that vanished

`shouldKeep` protects green from trailing signals that arrived out of order, but
the protection was hooked to `blocksDowngrade`, which is false for `failed`. A
late `PostToolUse` — the tail of the turn that had just been cut short — downgraded
a failed session to "working" **and erased the cause of the error**.

The reason `failed` wasn't in `blocksDowngrade` was a good one: if the turn really
does resume, yellow is the correct information. But a trailing signal is not a
resumption. The protection now tells the two cases apart, with two tests pinning
both down.

Note: the tool events aren't registered by default, so the defect only hit anyone
using `--with-tool-events`.

### The token promised more than it delivers

The comment said the token protects against "any local process, including the
Claude Code sessions themselves". **False**: a `0600` file stops the other users
on the machine, not a process running as your own user — and that one can open the
file. No on-disk secret can prevent it.

There is no technical fix: I corrected the promise. The token remains useful — it
covers the multi-user case and raises the barrier from "a GET is enough" to "you
have to know where the token lives" — but presenting it as a defense against the
code running inside the sessions is a false reassurance, and a false reassurance is
worse than no defense because people stop thinking about it.

### Concurrency: two things true and one to scale back

**The server's queue was serial**, so a `/next` waiting on the main actor also
delayed reading the hooks' `POST /signal` — up to two seconds on a Claude Code
turn, which is precisely what all the rest of the project avoids. It is now
concurrent: connections share no mutable state, so it introduces no races.

**The expired continuation ran anyway.** A `DispatchQueue.main.async` cannot be
called back: after the timeout the client received "not now", and then the main
queue, once free, really did raise the window. It is now a `DispatchWorkItem` that
gets cancelled, and a work item cancelled before it starts never starts.

**The point to scale back**: the reviewer observes that the timeout doesn't protect
the main actor — if `focus` gets stuck on an AppleScript, the interface freezes
anyway. That is true, and I wrote it into the comment in place of the sentence
saying "the worst case is a request that answers not now". But it is not a risk I
introduced: a click on a row does exactly the same thing on the same thread.
`/next` doesn't add the risk, it adds a way to trigger it from outside.

---

## The live proof

At the end I made the **real** app walk the complete chain, using the hook script
installed at `~/.lampboard/hook.sh` — the same one Claude Code runs — with a
test session backed by a live process:

```
prompt submitted:     working  ×0
two agents started:   working  ×2
parent turn closed:   working  ×2   ← the point: Stop doesn't clear the yellow
one agent closed:     working  ×1
last agent:           ready    ×0   ← the green resurfaces on its own
```

Then I removed the session file: the row disappeared at the next realignment and
the column went back to its ten real sessions, with no leftovers.

The **first** attempt at this proof was badly done: I had used a session with no
process, and the realignment took it away every five seconds, making the counter
look broken. It wasn't a defect in the code but in the test — worth writing down,
because it is the kind of false positive that leads to "fixing" something that
works.

## Eight hours of continuous operation

The panel stayed on all night, and that produced a verification you can't do
during the day.

```
PID    ELAPSED   %CPU    RSS
10103  07:41:50   0.0   25 MB
```

No memory leak, no runaway timer, `/health` still answers and the socket is still
bound to `127.0.0.1`.

But the best data point is a different one. Over the course of the night the
Claude Code sessions died one after another, and the realignment carried them away
by itself: the column went from **10 sessions across 5 projects** to **3 across
3**, and the panel resized accordingly — from 134 px to 86 px. Both heights come
out exact against the formula (`3 × 22 + 2 × 2 + 16 = 86`), and I imposed neither
of them: I measured them with the window server eight hours apart.

It is the proof that the hooks and the filesystem really are talking to each
other. The hooks never say what disappeared; without the second source, this
morning there would have been ten clickable rows leading nowhere.

## The last check, which arrived at unlock

The first check had waited the full eight hours and given up: the screen had never
been unlocked (29,281 seconds of idle time recorded). I put it back to waiting, and
at **07:09:39** it fired.

```
VS Code windows seen (9):
  → [1] Build floating Mac traff… — lampboard — Claude Minimal
    [2] Q3-Proposal.pptx — acme-portal
    [3] Read documentation and s… — docs-site — Claude Minimal
    …
```

Two things, both important.

**Title recognition works through the real transport.** Nine titles read by
`NSAppleScript`, and the arrow on the right window. It is exactly the chain that
stayed broken for an entire day with ten green tests, because it had been verified
with `osascript` — a transport that serializes lists differently. Now it is
verified with what the app actually uses.

**And it confirms last night's diagnosis.** The empty list I had got with the
screen locked was not a regression: it was macOS restricting accessibility access.
Had I not checked the lock state before concluding, I would have spent the night
"fixing" something that worked — which is exactly how this story has already lost
a day.

**And then the last step too.** With the stable signature in place and the two
permissions re-granted, the real raise:

```
✓ window raised with AppleScript — this is the correct behavior
```

Nine titles read, the right window chosen, `AXRaise` performed. Nothing is left
unverified in the click chain — the same one that in this project stayed broken
for a whole day with ten green tests.

## The signing script was broken (30 July)

On the first attempt to run it:

```
security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
```

The message sends you hunting for a wrong password. **The problem was the
algorithm.** OpenSSL 3 — 3.6.3 here — by default encrypts the PKCS#12 with AES-256
and computes the MAC with SHA-256, and macOS's Security framework PKCS#12 parser
can't digest them. A second stumble was layered on top: with an empty password,
"no password" and "a zero-length password" are two different things in the MAC
computation, and the two tools choose differently.

Fixed with `-legacy` (back to 3DES/SHA-1) and a random non-empty password that
lives for a few seconds inside the temporary folder. `-legacy` doesn't exist in
LibreSSL, which is the system openssl: the script retries without it, because
there the defaults are already the right ones.

Verified on temporary keychains, added to the search list and then removed by
restoring the exact configuration — no password prompt for the user and no
leftovers:

| | |
|---|---|
| p12 with OpenSSL 3's defaults | `MAC verification failed` — the defect |
| p12 with `-legacy` and a real password | `1 identity imported` |
| signing **without** marking trust | succeeded, correct `Authority=…` |
| ACL with `-T /usr/bin/codesign` | signed in under 20 s, **no dialog** |

The third outcome has a useful consequence: `add-trusted-cert` is not necessary
for signing, so the fact that the script tolerates its failure is right and not a
shortcut.

**But the real correction is a different one.** The previous version printed
"✓ identity created" right after the import: when the import failed, the error
scrolled past, the next build fell back to the ad-hoc signature **silently**, and
the user found out days later from a click that didn't work — the symptom hardest
to trace back to its cause. It is the same shape of error that had already produced
an alert shown after a success, months of wasted diagnosis on permissions, and a
`focus` that didn't tell "window absent" apart from "accessibility blind".

Now the script **signs a probe file and checks the Authority** before declaring
success. If it didn't work, it says so and exits 1.

### Then three more came out of the same script

**A typographic character that breaks bash.** `“$NAME”` — the guillemet
immediately after the variable name. In UTF-8 `”` is `0xC2 0xBB`, and bash 5.3
under `C.UTF-8` swallows the `0xC2` byte into the name, looking for a variable
`NAME\xC2` that doesn't exist. With `set -u` the script dies:

```
line 141: NAME�: unbound variable
```

Reproduced in isolation to be sure, and fixed with braces: `“${NAME}”`. All six
occurrences across the two scripts were fixed, not just the two that had exploded
— the search is `\$[A-Za-z_]\w*(?=[^\x00-\x7F])`, that is, "a variable followed by
a non-ASCII byte".

Remarkable how it manifested in `build-app.sh`: the faulty line was in the "sign
with a stable identity" branch, which until that moment had never been executed.
The defect had been there for hours, invisible, and it woke up exactly when the
certificate appeared.

**`codesign` doesn't fail: it hangs.** With the identity imported but the private
key not yet authorized, macOS opens an "allow access?" dialog. In a
non-interactive script that dialog reaches nobody and the command hangs forever —
that is, my verification, born so as not to lie, would have stayed mute for even
longer.

Two corrections. The first:
`security set-key-partition-list -S apple-tool:,apple:,codesign:` puts codesign on
the authorized list, and it is the step every signing setup on macOS ends up
discovering the same way — through a command that never returns. The second: both
the verification and the build now sign **with a deadline** of twenty seconds,
done by hand because macOS has no `timeout` out of the box. If it expires, they
say there is a dialog on screen; `build-app.sh` falls back to ad-hoc instead of
getting stuck.

**The repair advice didn't repair.** The script exited immediately with "nothing to
do" if the certificate already existed. But the real situation was exactly that:
identity present, authorization missing. "Run the script again" was a dead end. It
is now idempotent: if the identity is there it skips creation and goes to the
checks.

Four defects in a hundred-and-fifty-line file that isn't even the product. Worth
saying because there is a single cause: that script had never been run. Everything
else in the day went through a build or a test; it didn't, and it is the one piece
of work I shipped without watching it work.

## What is left for the user to do

1. **Stable signature: done** (30 July, after fixing five defects in the script —
   see above). Verified where it counts: two builds in a row produce the same
   designated requirement,
   `identifier "com.lampboard.app" and certificate leaf = H"4dff4499…"`,
   hooked to the certificate and not to the binary's hash. From here on the
   authorizations survive rebuilds, and launch at login is unlocked in the menu.
2. **The click: verified in full**, recognition and raise. The side-effect-free
   diagnosis remains `lampboard focus <project> --dry-run`.
3. **Claude Code sessions that are already open** don't have the two new hooks:
   they pick them up on their next start. Until then the subagent counter stays at
   zero for those sessions, and that is normal.
4. If something doesn't add up, the way back is: `uninstall-hooks` for the hooks,
   the dated backup in `~/.claude/` for the configuration, and the per-phase
   archives I left in the session's temporary folder.

## 30 August — the app that could not be entered, entered

The panel could see Claude Code in an editor, in a terminal and over a tunnel,
and Codex in three places. The one surface it declared closed was the desktop
app, and the README said so as a limit rather than a gap.

That line was **half wrong**, and the half that was wrong is the half that
matters. Claude Desktop runs a session in one of two places. A **cloud** session
runs on Anthropic's servers: nothing of it is on this Mac, its hooks are a
documented open bug (anthropics/claude-code#40495, three root causes, open since
March), and no probe tried — descriptor, socket, network route, session file —
found anything at all. A **local** session runs *here*, as a child of the
application, and writes exactly the files every terminal session writes, in a
directory nobody had thought to look in.

So the surface was not entered through a hook. It was entered the way the
terminal sessions already were, by reading what a running session leaves behind.

### The bug that made it look finished when it was not

The first version asked the question every other row asks: which session file
names a process that is still alive? It found the conversation, painted it
yellow while the model worked, and then the row **disappeared** at the end of the
turn instead of going green.

A Claude Desktop agent process lives exactly one turn. The application starts it
to answer and removes its session file when it exits: measured here, a
conversation whose last word landed at 22:44:38 left an empty `.claude/sessions`
directory stamped 22:44. Built on that file, the row vanished at the one moment
this panel exists for.

Presence comes from the pair the application keeps for itself — the index beside
each conversation, and the transcript. The session file is still read and still
means something, but only what it can honestly mean: a turn running right now.

A second defect was hiding underneath, and it was silent. This colour is not
reported by a hook; it is re-read every five seconds. Adoption was the wrong verb
for that — `.adopt` refuses to overwrite a row that exists, by contract — so every
update after the first was a no-op, and the log printed a transition the state
never made, twelve times a minute. The action that replaced it carries the moment
its evidence is dated, and the two kinds are dated differently: a colour read off
the transcript is dated by the transcript, so a click is never undone by the next
sweep; a colour read off a live process is dated **now**, because it is not a
record of anything.

The end-to-end suite caught the second half of that rule by failing. Dated by the
transcript, a new turn could not take the row back: a model that has just been
asked a question has written nothing yet.

### What the second Codex audit was right about

Three findings marked P1, and all three were real.

**A hook could move a row out of the folder it was proved to be in.** My own
comment claimed the folder stays the one the row was admitted with; the code only
did that when the resolver found nothing. `POST /signal` carries no token, so
"only we send those" was an assumption rather than a limit. A row that was
**found** now keeps the folder it was found in, and a row that was announced still
follows the resolution, which is D25 rather than a defect.

**The same path on two machines was one row.** `Workspace` kept `host` in its
identity and every caller that needed a key threw it away and used the path. So a
folder here and a folder on a node became one row, in whichever state the more
urgent member happened to be, and hiding one hid both. A value being distinct is
worth nothing until something asks it for its name.

**A subagent's rollout became its parent's row.** Of 26 rollouts on this machine,
3 are a subagent's: they carry the **parent's** `session_id` and their own `id`,
and two of the three name the same parent. Read as sessions they were second
evidence for a row that already existed, and arriving first they became its
transcript — the wrong thread back to the window, the wrong clock, the wrong
context.

**And the sweep really was too slow.** The audit called it a worst case; the
steady state was already the problem. Instrumented: **150 milliseconds every five
seconds** on the actor that draws, of which 80 was the Codex probe spawning `lsof`
over eighteen live pids. It runs on an actor of its own now — which also means a
slow probe can no longer have a second started on top of it — and the same
instrument says the pass is **53 to 81 milliseconds** after the move. What is left
is dominated by reading the live session files, and that is the next one to take.

### Two traps worth writing down

**A test fixture with a fixed date expires.** Four end-to-end cases went red at
23:00 on code that had not changed: every Codex fixture said
`2026-08-30T09:00:00Z`, and the clock had passed `sessionStaleAfter` after it. The
row was adopted and pruned as stale inside the same sweep. A test whose result
depends on when it is run is not measuring the code.

**A key that goes through a normaliser comes back changed.** The first spelling of
the remote workspace key was `//host` and the path. `PathNormalizer` collapses
every run of slashes, so the key that went into the name table was never the key
that came back out, and a renamed remote row lost its name. The colon form
survives being normalised.

### What is not verified

The live click on a Claude Desktop row. The screen was locked when the work
finished, so the application could not be driven; what is proved is the whole
chain from the files to the row, end to end against the real binary, plus the row
standing green on the real conversation for 130 consecutive samples.

## 31 August — two ways to verify nothing

The desktop work was finished, green and pushed. The first thing said about it
the next morning was that nothing had changed.

**It had not, because the build was never installed.** There are two copies of
this app on a machine that has ever installed one: `dist/`, which the build
script writes and which everything was verified against, and
`/Applications/LampBoard.app`, which is what starts at login. At 06:12 the login
item started the copy from the previous evening, and that is the process that
took the port and answered every question after it. Two hours of measurement, all
of it about a binary nobody was running.

Underneath it a second failure, quieter and worse. The build script looked for a
signing certificate by a name written into the script; the project had been
renamed and the certificate had not, so every build since had fallen back to an
**ad-hoc** signature, announced in one line nobody was reading. Installing one of
those would have taken the Accessibility and Automation grants with it, because
those are attached to the identity. The script asks the keychain now, Developer
ID first, and compares the two copies out loud on every build.

**Then the panel flickered**, and the second defect took three attempts to see at
all. Polling the state five times a second for fourteen seconds: constant.
Sampling the window geometry once a second: constant. Both wrong, because the
rows were gone for about **eighty milliseconds** and both samplers blinked slower
than that.

What found it was making the code say what it did. One line — `lost 6 to prune` —
and it was over: the twelve-hour age rule runs at the end of every sweep and
exempts what is confirmed at that moment, and the Codex probe's answer now comes
from another actor a moment later. Six conversations open since yesterday were
pruned for being old and re-adopted eighty milliseconds afterwards, four times a
minute. Moving that probe off the drawing thread is what put the answer on the
wrong side of the prune.

The fix is what the rule already meant: an open rollout is a conversation loaded,
not a model working, so its last word can be days old while the process holding
it is alive, and that descriptor is a confirmation. The age rule is the bound for
rows nobody can confirm.

The end-to-end case for it passed against the unfixed code on the first attempt,
because it slept 200 milliseconds between looks — the same mistake as the two
samplers, in the place that is supposed to catch it. It looks as often as the
question can be asked now, and it fails when the exemption is removed.

## 31 August — three of the four, and a reassurance that was a lie

The three open findings, done in the order they cost least: the probe, the key,
then trust. It is the inverse of how visible they are, and deliberate — the first
two are small and closed and put last night's changes under guard, and the third
touches the menu and the first run.

**A rule nothing was watching.** "A probe that could not answer is not a session
that ended" lived as one line inside the store, and deleting it left the suite
green: producing an unavailable probe in a test would have meant making `lsof`
genuinely hang. `CodexEvidence` and `CodexScanResult` moved to the core with the
decision — `nil` for a probe that did not answer, an empty verdict for one that
answered and saw nothing — and those two are no longer spelled the same.

**A key proved by half.** Three rows, three names and hiding were covered; slot,
reordering and mute were not, and the slot is the sharp one. The click turned out
not to pass through the key at all: a remote row opens by reading its host, so a
key mistake cannot send you to the wrong machine by clicking. It can by pressing
a number, and that is now proved.

**And the thing this project said could not be known.** `lampboard status` used
to say the trust of Codex's hooks *cannot be read from here*. It can. Codex
records it in its own configuration, one entry per event, and the key carries our
file's path and the event name in snake_case. So a hook registered and never
approved — which will not run, silently, because Codex says nothing when it
declines — has a name now.

What cannot be read is the hash beside it. Eight plausible inputs were tried
against a real entry and none reproduces it, so a record means the approval
happened and not that it still holds. Two installs in a row were measured to
produce a byte-identical file, so reinstalling costs no trust; changing the events
or the script's path does, and renaming this project did exactly that.

The defect worth recording is the one the fixture found. With the states read but
the three branches written separately at two call sites, the installer told a
person with **no Codex configuration at all** that everything was already
trusted — because the list of events awaiting approval is empty in that case too.
A reassurance nobody can check is worse than a question. The verdict is one
function now, and the case that covers it bites.

## 31 August — the manual proof stops being manual

The last open item was a written record of the tests only a person can run: click
a row, watch the right window come forward. The plan was a script that walks
somebody through it. The right answer was better and the question that got there
was blunt — *can't you do it with computer use?*

Largely, yes, and without a mouse. Two commands already do what a click does
through the route the click takes: `open <n>` raises the project bound to a slot,
and `focus` reproduces the whole decision and reports which strategy answered. The
window server says who came forward. So the fragile part — clicking at a
coordinate and reading pixels — is not in it at all.

`Scripts/smoke-clicks.sh` has two modes. Recognition moves nothing and can run
whenever; `--live` raises windows for real, so it needs the Mac free, and it puts
back whatever was in front. It writes the build's version and signature beside
every result, so a stale record names a build that is no longer the one.

What it says it **could not** do is the part that makes it worth keeping. Surfaces
with no session running are named. So are the rows past the ninth, which the
panel's own click reaches and the command line cannot, because `open` addresses
slots. A record that only lists successes is a record that cannot go stale
visibly.

Two limits stay, and they are stated rather than worked around. On a locked Mac
it proves nothing — measured, the night the window server refused to bring
anything forward. And a terminal seat is checked more weakly than the others: the
application coming forward can be verified, the tab inside it only where the
terminal writes the project into its title.

### And a fact about Claude Desktop, plus a deduction that had to be withdrawn

The three conversations this panel showed green in the morning were **gone from
disk** by the afternoon, homes and indexes together. I wrote that the application
cleans up after itself on a schedule of its own, and it took one sentence from
the person at the keyboard to correct it: he had deleted them by hand.

The evidence for that was already in front of me. The three that went were the
three **most recent**; housekeeping by age would have taken the ones from April.
I had the number and read past it, which is the same mistake as reading past a
`find` that prints its usage instead of filtering.

The fact that survives is worth keeping and is smaller than the one I claimed:
**deleting a conversation in the application deletes its folder**, and the row
goes with it. That is the panel being right rather than forgetful, and knowing
which of the two is happening is what stops the next person hunting for a bug.

## How the project stands now

| | |
|---|---|
| Domain tests | **1267**, instantaneous |
| End-to-end tests | **165**, about a minute |
| Build | clean, no warnings — CI builds with `-warnings-as-errors` |
| Unbounded process waits | **0** — every one carries a deadline |
| Documentation gates | **11**, each with a mutation that proves it fails |
| Mutations committed by `bite.sh` | **28**, all caught |
| Longest file | 792 lines, `StateStore.swift` (limit the project sets itself: 800) |
| Realignment pass, on the actor that draws | **~55 ms**, down from ~150 before the Codex probe moved off it; measured, not estimated |

## 27 August — sessions in a terminal

The day's question was whether the panel could show the `claude` sessions
started by hand in a terminal, and take you to their tab. Measured first: the
hooks already arrived and were dropped for want of an editor window; the hook's
`cwd` follows every `cd` Claude makes while the session file's does not; every
process chain from a `claude` up to its terminal, on this machine; what each
terminal's dictionary or CLI exposes (`sdef`, `--help`, then a real click).

A plan was written, then put through an adversarial review — three lenses and
a refuter per finding; nineteen findings confirmed, among them the anchoring on
the session file's folder, the row carrying its own origin, and `procStart`
being a UTC ctime string on macOS — and rewritten from it. Then six phases in a
day, each green and documented before the next: the deep link only for sessions
the extension hosts (A); the row, born only when a live session file names the
session (B, D25); the click by tty in Terminal.app and iTerm2 through the
process tree (C); through tmux and zellij (D — `lsof` does pair a zellij client
with its server, from the column the plan had first misread); Ghostty, WezTerm
and kitty (E). Every host was clicked live with a real `claude` inside it.

Three things found on the way and written into 07-traps: an app relaunched
from a Claude Code shell inherits VS Code's Automation denials; a `claude`
started from such a shell writes no session file; a `claude` that is Ghostty's
own command reports no working directory, so the matcher learned Claude's `✳`
mark. Deferred, and said so in D25: the reconcile that ignores an empty live
list, because the end-to-end harness leans on it.


## 28 August — the disk image, and what it costs

The question was whether the app could be handed to somebody as a `.dmg`. It
can, and the whole procedure turns out to be `xcrun`: the Command Line Tools
ship `notarytool` and `stapler`, so nothing here needs Xcode and no third-party
signer is required. Measured before writing anything, because the alternative
was a Rust re-implementation nobody would have needed.

`Scripts/release.sh` builds it, with three outcomes it refuses to confuse: the
local certificate produces an image macOS rejects; a Developer ID produces a
signed image macOS *still* rejects the first time; only notarization lifts that.
The script asks `spctl` — the same service that will decide on somebody else's
Mac — and prints its verdict before the file leaves, so the difference is read
rather than assumed. The version travels from the git tag, so an image cannot
carry a number no commit has.

Notarization forces the hardened runtime, which takes away precisely the two
things this app lives on: Apple Events, which raise the window you clicked, and
the microphone, which dictation holds down. Two entitlements give them back and
the script grants nothing else. Both secrets — the identity and the
notarization profile — are read from the environment: this repository is
public, and a Team ID is not ours to publish.

## 28 August — three claw marks

The app had no icon, so the disk image showed the generic one. The name carries
*claw* and the product is a traffic light, and the icon is the point where those
stop being two things: three marks that **are** the three states, not a claw
standing next to a semaphore.

Five candidates came out of a generator and the best of them died at 16 px,
which is the size that decides — the three slashes merged into a coloured smear.
So it is drawn by arithmetic instead: `Scripts/make-icon.py`, where the rule that
keeps it legible is a multiplication rather than an intention. The gap between
two marks is never smaller than a mark is wide, and a redraw cannot quietly lose
that. The tile follows the Big Sur grid — 824 of 1024, radius 185.4 — which is
why it sits the same size as its neighbours instead of visibly larger.

The sizes below 32 px are drawn, not shrunk: thicker strokes, no shadow, no
gloss, because at that scale the ornament lands between pixels and only mutes the
colour, and colour is the whole of what still reads. Two things the first render
taught, both now written into the script: a lighter copy of a mark laid over
itself is a bevel that eats the colour — red came out brown — so the light is
graded inside the mark's own silhouette; and a mark that reaches past the tile
looks like a rendering fault, so the group is clipped to the tile by construction.

## 28 August — the permission that was granted and wasn't

The disk image was the easy half. The install proved the hard half: on a fresh
machine macOS asked for nothing, the click activated the editor without choosing
a window, and the reason sat at the bottom of a context menu. An app that
degrades silently into a place nobody looks is indistinguishable from a broken
one, and the first person it defeated was the person who wrote it.

Two faults underneath. System Settings listed lampboard with the switch **on**
while `AXIsProcessTrusted()` said no, and the app was right: these
authorizations are keyed on the signature, so the same bundle identifier signed
three ways leaves three records — `tccutil reset` reported success four times.
And granting a permission notifies nobody, so the panel went on complaining
until it was relaunched, which nobody would think to do.

What changed follows from the ordering, not from better wording. The traffic
lights already work with no system permission at all, so nothing is asked until
the first click; when that click cannot finish, a line under the rows says so
where the eye already is; the button behind it explains what macOS calls the
permission, the one thing it is used for, what refusing costs and how to undo
it, before opening the pane. And when the permission arrives, the app finishes
the click it interrupted — a permission you granted that visibly changes nothing
reads as a permission that did not work.

The self-test was lying too, in the way that matters most: run with the panel up
it announced "the signal never reached the handler" on a working chain, because
`SignalServer.start()` returns before its listener has failed on a taken port
and the probe then reached the panel instead. It now asks before it binds, says
who holds the port, and states that the loop test was not run — silence there
reads as a pass, and a diagnosis is read by somebody who already suspects a
fault.

Measured, not assumed: the strip appears and the panel grows by exactly the
seventeen points it costs, in the wide layout and in the thirty-five-point one
where the triangle is the whole message; the sheet carries the four paragraphs
and the cure; and on the installed, notarized copy two different rows raise two
different windows. The wait itself is a value — granted, expired, or neither —
so the tie can be tested: granted at the last second still wins, because a click
is not less owed for being answered late.

## 28 August — what an open endpoint is not allowed to do

A security pass before publishing, run as measurements rather than opinions —
and twice a hypothesis was wrong and the measurement said so.

Two real defects. The diagnostic log was born 0644, holding workspace paths,
window titles and remote host names: the same information the token on
`GET /sessions` exists to protect, readable by every other account on the
machine. And `POST /signal`, which carries no token by design because a hook
that fails authentication would block a Claude Code turn, accepted any absolute
`transcript_path`, stored it, and later opened and rendered it. A forged signal
naming `/etc/passwd` produced a row holding it within a second, and repeating
the signal kept that row alive indefinitely.

Both closed: the log is created 0600 like the token, and transcript paths are
accepted only under `~/.claude`, with `..` resolved before the comparison and a
trailing separator so `.claude-evil` cannot pass as a child of `.claude`.

The two refuted hypotheses are worth as much as the findings, because they stop
the same ground being dug twice. Header accumulation is already bounded at 512 KB
in the parser — proven by pushing 2.8 MB with no terminator and watching memory
*fall*. And a web page cannot reach the endpoint: tried from a real tab, Private
Network Access blocks it. That is why the transcript rule is defence in depth
rather than a closed hole — but the browser refusing on our behalf is not a
boundary we control.

Everything else came out sound and was left alone: loopback binding by
construction, every acting route behind a constant-time token check, no shell
anywhere, every AppleScript interpolation allow-listed or escaped, ssh with agent
and X11 off, and exactly two entitlements in the signed bundle with none of the
dangerous ones.

## 28 August — the update that waits to be told

An updater is the one component that downloads code and runs it, so everything
the security pass verified is worth nothing if it accepts the wrong bundle. Here
it is worse than usual: macOS grants Accessibility to a **signing identity**, so
a replacement signed with our certificate inherits the run of the machine without
asking anybody. A wrong update is not a broken app, it is a silent one with the
keyboard.

So it never installs by itself. *Check for updates…* asks and says one of three
things; a newer release gets a button and nothing happens until it is pressed.
Then four things are proved before the running copy is touched: Gatekeeper's own
assessment of the disk image, the app inside verifying against its own signature,
its Team ID equal to this copy's — compared against the running app rather than a
constant, because a constant could be edited by whoever edited the download — and
its bundle identifier.

Proved end to end rather than declared: a 0.0.9 signed with the real certificate
was installed, and it updated itself to the published 0.1.0 in eleven seconds,
came back, and kept its permissions — which is the whole argument for tying
updates to one identity, and the whole reason they must be asked for.

A hang found on the way, and it looked like patience: `notarytool submit --wait`
waits for ever, and one submission held for two and a half hours on "initiating
connection" without ever reaching Apple's queue. It now has a deadline. The thing
that made anybody look was the panel staying blue — the turn had ended and
background work had not — which is exactly what that state is for.

## 29 August — the audit that read the diary

The documentation gate had grown seven checks and a habit of being trusted, so
this file was put through a semantic audit against reality instead of against
more prose. The gate was green. This file was not.

The table titled **"How the project stands now"** claimed 242 domain tests
against 497, 66 end-to-end against 82, a longest file of 407 lines against 786,
and a build free of warnings that had twenty-eight. Four claims, four false, in
the one place in the repository that says *now*.

The cause is worth more than the findings: `check-docs.sh` never opened
`WORKLOG.md`. It verified the same figures in the README, the architecture and
the working notes, and left out the file that reads like a diary — because it is
one, except for the table of status sitting inside it. A checker that looks in
one place has one blind spot per other place, which this project had already
written down once and then repeated.

Now checked, and narrowly: only that table, because the rest is history and the
figures in an August entry are *correct* precisely for being old. A rule
demanding they be current would fire on every past entry, and a gate that cries
wolf stops being read. Proved to bite on three known violations, including
renaming the heading to slip out from under it.

The warnings turned out to be a lesson of their own. The first count said two,
measured with a warm build directory; a clean build said twenty-eight — four
distinct ones emitted seven times each. All four are gone: two redundant `try`s
on a failable initializer that never threw, and AVFoundation's pre-concurrency
API, which is what `@preconcurrency` is for. The two that started it were real
Swift 6 errors in waiting: `self` unwrapped inside the actor hop instead of
before it, so the closure captured a variable rather than a value.

Two findings left deliberately unmechanized. Four of the day's seven commits had
no entry here at all — no rule can know which commits deserve prose, so they were
written instead. And the `v0.1.0` tag points at a commit made thirty-one minutes
after the published disk image was built: the difference is `Scripts/release.sh`,
which never enters the app, so the artefact is the right one — but the order for
next time is tag, then build, then publish.

## 29 August — the checks, checked

The morning's question was the one left over from the audit: what stops any of
this from rotting again. The answer came from reading another project's engine
and five days of its notes, and then — this is the part that mattered — trying
its failures here instead of admiring them there. Two landed.

**The instrument.** One line, `if true { return }`, at the top of `expect`, and
the suite reported `497 tests passed`. Every number this project has ever stated
about itself passes through fifty lines that nothing checked. `TestKit/Instrument`
now calibrates them before either suite runs: nineteen proofs, each assertion
made to fail and made to pass, and a failing run demonstrated to reach a non-zero
exit code — none of it written in the vocabulary being tested. A blunt instrument
exits 70, not the 1 of an ordinary failure.

**The guard that had never looked.** Worse, because it was real and not
simulated. The check against committing a real home directory into this public
repository was `grep -nIE '/Users/(?!dev|…)'` with `2>/dev/null` and `|| true`.
`/usr/bin/grep -E` has no lookahead: it exits 2 with `repetition-operator operand
invalid`, every time, and both the message and the status were being discarded.
It had never read a file. `Contracts/golden/hooks.jsonl` had carried a real user
name in thirteen places since the day it was recorded. Scrubbed, and
`check-contract --record` now scrubs on the way in — trusting somebody to notice
on the way out is what failed.

Both are the same shape, and it has a name: **absence mistaken for permission**.
A search that finds nothing, a guard that cannot run, a test that cannot fail —
all three produce silence, and silence reads as "all clear".

So the rest of the day was spent making silence impossible.

Every search in `check-docs.sh` now declares how many matches it expects; finding
fewer is a finding, because a reworded sentence used to switch a check off
without switching anything red. There is a third outcome, ⚠, for a check that
could not observe what it judges, and a run containing one exits 3: a green with
a skip in it is not a green. The leak guard proves its own patterns against
examples before it believes them, and says `THE GUARD ITSELF IS BROKEN` when they
stop matching. `check-contract.sh` learned the same word: without Claude Code
installed it now reports ⚠ instead of a red that means nothing.

`Scripts/bite.sh` is the new load-bearing piece. It commits twenty violations —
a drifted figure, a broken link, a planted home directory, a suite nobody runs,
an assertion that has stopped asserting, a gate added with nothing to prove it —
and fails if any guard fails to notice. Three things have to hold for a bite to
count: the mutation actually changed something (a find-and-replace whose target
was renamed proves nothing, so the files are fingerprinted), the gate exited
non-zero, and it said why in the expected words. The two lists are compared in
both directions, so a gate without a bite and a bite without a gate are both
failing checks. Twenty-six seconds.

Then the thing that makes all of it stick: `.github/workflows/checks.yml`. Build
with warnings as errors, both suites, the documentation gates, the bites, and a
last step asserting the tree was left exactly as found. `check-contract.sh` stays
out of it deliberately — it measures another product's shipped binary, and a gate
that reddens because somebody else made a release teaches people that red is
noise.

Two smaller things. `Command.swift` in Core, because `UpdateInstaller` still had
a `waitUntilExit()` with no deadline: a hung `spctl` took the update with it and
nothing was ever going to appear on screen. It also fixes a second failure the
obvious code has — a pipe holds about 64 KB, so a tool that says more blocks
writing while the caller blocks waiting — and both are now tested with real
processes rather than argued about. And `docs/README.md` had an editing
instruction left inside the published prose, in the second paragraph, since
whenever.

Everything in this entry replaces a sentence that used to ask a person to
remember.

## 29 August — the same defect, in the place that is clicked

Having taken the unbounded wait out of the updater in the morning, the obvious
question was where else it lived. Five more: `lsof` and the three multiplexer
clients that find a terminal tab, `open` that brings an application forward, and
`codesign` read once at startup. All of them launched with `waitUntilExit()` and
no deadline, and all of them on the main actor — `PanelController` is
`@MainActor`, so the whole click runs on the thread that draws the panel.

Measured before deciding anything: `lsof` 0.059s, `ps` 0.065s, AppleScript to
System Events 0.672s, `open -b` 0.754s. A working click already costs between
0.7 and 1.5 seconds of main thread, which is the hitch you feel rather than a
fault you report. The fault is the tail: `lsof` stats every open descriptor, so
a network mount whose server has gone stops it indefinitely, and tmux, wezterm
and kitten each ask a server of their own over a socket. Either one froze the
panel until the app was killed, with the column still showing the last state it
had managed to draw.

Now bounded — five seconds for a probe, fifteen for `open`, which may have to
start an application. The behaviour in every case that already worked is
unchanged; `focus lampboard --dry-run` still picks the right window out of
eight, in 0.84s. What this does not do is make the click feel instant, and the
reason it stops here is written down as D27 rather than left as an intention.

`Command` learned to leave standard error out, because three of those callers
**parse** what they read and a warning arriving interleaved would be read as a
record.

Then the new guard bit its author. `Scripts/bite.sh` became tracked on its first
commit, and it carries the fake leaks it plants — so the leak check went red on
a home directory and a mesh address that were fixtures. The tempting fix was an
exemption for that file, which is what the check already had for itself. Both
are gone instead: the fixtures are assembled from pieces at runtime, and **no
file is exempt**. An exemption is a hole with a good excuse, and the guard it
protects is the one whose failure nobody can see.

Worth recording that the commit made an hour earlier would have failed its own
check. It was green when it was written, and turned red the moment `bite.sh`
stopped being untracked — which is a decent argument for the CI landing before
the next commit does.

## 29 August — an ear is not a hand

Two rows sat blue all morning with nothing running behind them. The API said
why: `waitingOn: ["monitor", "monitor"]`, registered at 06:38 and never closed.
One of them was this project's own session, blue because publishing a document
had armed a live subscription that listens for republishes — real background
work by the letter of the rule, and nothing anyone was waiting for.

The rule was too coarse by one category. `background_tasks` was being read as
two groups — Claude Code's housekeeping, which is ignored, and everything else,
which turns the row blue. But a monitor belongs to neither. It watches for a
condition and produces nothing until that condition happens, so the turn really
did end and the answer above it really is unread. Blue was saying "more is
coming" about something that may never come, and burying a green underneath it.

Three groups now, and the third does not get a colour: it gets a ring. The row
keeps the colour it would have had, and the dot carries a blue border in the
same shade the column already uses for `waiting` — as a fill it means
"registered, nothing needs you", as a ring it means the same without taking the
colour that carries the news. Drawn inside the dot with `strokeBorder`, so
eleven points stays eleven points and no row changes width because a monitor
appeared.

The ring outlives the answer being read, which is the part worth having thought
about: a green clears when you look at it, and an ear does not close because you
looked. So the row keeps what is registered behind it, and the ring survives into
idle. The tooltip names it either way — *"waiting on monitor ×2, shell"* under a
blue, *"still listening: monitor ×2"* under anything else.

One rule protects the whole thing: **anything unrecognised counts as work**. The
mistake is not symmetrical. Calling real work a listener paints green over a busy
session, which is the lie D22 exists to prevent; calling a listener work only
shows blue a while longer. The list of listeners is one entry long and closed.

## 29 August — the tunnel that outlived the app

A remote row had gone quiet, and the panel had been saying why once a minute for
two hours: *"port 31000 is taken there (127.0.0.1); retrying in 60 s"*. It was
pointing at the wrong machine. The port was held by this app's own
`ssh -N -R 127.0.0.1:31000:127.0.0.1:9877`, pid 64151, **PPID 1** — orphaned,
reparented to launchd, and still working: `curl` through it from the other
machine answered 200.

The cause is not the tunnel. `applicationWillTerminate` stops the polling, the
server, the presence file and the tunnels, and all of it is correct. None of it
runs when the process is killed with a signal: a Cocoa app takes SIGTERM's
default disposition and simply stops. And the way this project tells you to
restart, printed by its own build script, is `pkill -x lampboard`. So every
restart left a tunnel holding the port, the next instance was refused, and the
refusal was reported against a machine that had done nothing wrong.

SIGTERM and SIGINT now go through `NSApp.terminate`, so the cleanup that already
existed finally runs. Proven with the real command rather than argued: panel
1964 with child ssh 3279, `pkill -x lampboard`, and the child died with it —
zero orphans, and a `tunnel devmachine: off` in the log that had never appeared
before.

And when the port is taken anyway — a crash, a `kill -9`, a second panel — the
message now says whose fault it is. `TunnelRefusal` reads the local process
table and answers *"port 31000 is held by a tunnel this app left behind (pid
64151) — `kill 64151` and it will reconnect"*. It matches on the forward
specification rather than on the word `ssh`, so an `ssh -L` the user set up by
hand is not accused; and it kills nothing by itself, because a second running
panel is a legitimate owner of that port.

One correction worth recording, because it nearly shipped. The first version of
that diagnosis hung off ssh's stderr, which is where the message *seems* to come
from. It is not: the tunnel asks the remote machine what is bound **before**
spawning ssh, so in the ordinary case ssh is never started and its stderr never
exists. The fix was written, tested with eight passing cases, and would have
been correct and unreachable. What caught it was installing the build and
watching the old sentence appear anyway — the same lesson as the guard that had
never read a file, arriving by a different door.

## 29 August — how full is it, and how much of that do we know

The question was whether the panel could say how full each session's context is.
Eleven agents spent thirty-four minutes measuring it, and the answer corrected
the premise the question was asked under.

**The denominator is discoverable**, which three of the five research strands had
concluded it was not; all three were refuted by their own verifiers. The window
is a property of the model and it sits in Claude Code's registry — sixteen
models, six of them on a million. The transcript's model string is enough to look
it up, and the `[1m]` suffix is a red herring: a session started with
`--model sonnet`, no suffix, reported a window of a million. Claude Code's own
status line confirmed both halves of the arithmetic, numerator and denominator,
against a live payload.

**But the number is a floor, not a reading of now.** Only assistant records carry
a token count, so anything loaded since the last reply is invisible. Across 171
compaction boundaries the truth was a median of 1.00× the last reading and a
maximum of 17.67×: one session would have shown 56,555 while holding close to a
million. So there are three renderings and never two — `62%`, `≥62%`, `—` — and
the `≥` and the dash are the feature. The bare percentage is the version
everybody asks for and the one that would lie.

Four traps, each found in a real file and each one the obvious implementation
walks into. A `<synthetic>` record is a refusal carrying zeros — one of them says
*"Prompt is too long"* — so reading the last usage-bearing record prints **0%**
at the exact moment a session is full. Zero at the top level can hide the real
figure in `usage.iterations`. The model must come from the same record as the
tokens, because a session switches models mid-flight, twenty-eight times in one
file. And the order in a transcript is not chronological: a resumed session
replays its history, six thousand records stepping backwards, the worst by nine
days.

Built bottom-up, and nothing is on screen yet. The contract first, with a check
that re-reads the binary — proven to bite on a moved window, a vanished model and
an invented one. Then the pure rule in Core with twelve cases. Then the reader,
an `actor` rather than a class, because `await self.reader…` on a main-actor
property compiles and quietly performs the seek on the thread that draws the
panel — a defect I wrote, this afternoon, hours after spending the morning
removing exactly that.

Remote sessions do get a figure, which the research had ruled out. Their
transcript is not a file here — the decoder nils the path for any signal carrying
a host, correctly — but the probe already stands in that directory on the far
machine. It now returns a **miniature of the tail** in the same shape as the real
thing, a kilobyte or so, and the Mac reads it with exactly the code it reads a
local transcript with. One rule, one implementation, one set of tests, and no
judgement made on a machine we do not update. Measured on the node: 208,943 of
1,000,000, `exact`.

The numbers, from the real path, through HTTP, on the sessions open right now:
`≥85%`, `≥63%`, `≥63%`, `52%`, `≥11%`, and one `—` for a session compacted since
its last reply. The dash is doing exactly what it exists for.

## 29 August — the ring, the legend, and a denominator that was almost wrong

The figure from this morning had nowhere to be shown. It has one now: the cell
left of the name, which used to carry the row's keyboard slot, carries an
eleven-point ring — the arc is how much of the window is gone, the letter is the
model family, `O`, `S`, `H`, `F`, `M`, or `n` for one this build has no window
for. Monochrome, because six states already own the colour here and a ring that
went red near the end would be a seventh voice arriving exactly when the row's
own colour matters most. The slot moved into the tooltip, which also gained the
exact figure, the model with its version, and — on a renamed row — the folder
underneath, which until today appeared nowhere on screen.

**The denominator was the day's real work, and it was nearly wrong.** Claude Code
compacts before the window is full: its indicator counts down to
`window − min(maxOutputTokens, 20 000) − 13 000`, which is plainly readable in
the binary. Three sessions read by hand against that indicator agreed, to within
a point, with a denominator of `0.92 × window`. Three points, two models,
fillings from 68% to 92%. It reached the prototype and was one commit from the
code.

It was wrong twice over. The threshold is compared against Claude Code's **own**
token estimate, which is not the sum we read out of `message.usage`: on one
compaction the two were 0.4% apart, on another sixty-fold. And a fixed
subtraction is not a ratio — 0.92 fits a 1M window and would mean 0.835 on a 200k
one, which none of the three readings could have caught, all three being on 1M
models. The agreement was our own floor being 30–40k stale in all three cases,
pointing the same way each time, which is what a floor does.

What settled it was asking the files a question with one answer: at what value of
*our* number does a session actually get compacted? Every `compact_boundary`
carrying `trigger: "auto"` is a session that hit the ceiling. 18,622 transcripts,
236 of them: the highest reading before a compaction is 99.91% of a 1M window and
99.99% of a 200k one, and **not one ever exceeded its window**. Under `0.92`, ten
of them would print above 100%. `Scripts/measure-compaction.py` reproduces it in
twenty-four seconds, `check-contract.sh` fails on any reading past its own
window, and it was watched failing: opus-5 set to 920,000 in the contract answers
`108.6%`, twice, and exits 1.

**A legend, because the grammar outgrew inference.** Six colours, two of which
differ only in brightness, a ring that is not a state and now a second ring that
is not a light. A `?` in the footer and an entry in the menu open a window that
says what each one means — with a live count beside it, taken through
`PanelController.currentRendering`, so a census and a column cannot disagree. A
key is read once; a key that also answers *how many are waiting for me* is worth
opening twice.

And the compact strip is straight again: one dot in thirty-five points, aligned
leading, sat two points off the centre line, which on twelve rows reads as a
column that was built crooked.

Verified: 531 domain cases, 82 end-to-end, 9 documentation gates, 20 mutations
committed and 20 caught, 10 contract checks. The three new domain cases lock the
denominator itself — the highest reading ever seen before a compaction, 999,083,
must print 100% and not 109%.

## 29 August — the tooltips nobody had ever seen

Three things reported from use, and the first one is the kind of defect that
cannot be found any other way.

**Every tooltip in the panel was dead text.** `.help(…)` was on the row, the
gear, the filter note, the hidden-projects row and the issue strip. It compiles,
it says the right thing, and in this window it shows nothing: AppKit puts a
tooltip on screen through `NSToolTipManager`, which wants the window under the
pointer to be key and the application to be active — and this panel is a
`nonactivatingPanel` in an accessory app, both on purpose, because clicking a
light must not take the focus from the editor. So the row's entire second layer
had never been seen by anybody: the context figure and the tokens behind it, the
model with its version, the folder under a renamed row, the slot and its command,
which sessions of a group are in which state.

No test caught it and none could have. Every one of them checks the *string*,
which was right. It is the same gap as the blink that outlived its state: a
correct model proves nothing about the screen.

The panel now draws its own — one borderless window that ignores the mouse, never
becomes key, appears after 450 ms under the pointer and takes itself away on any
mouse-down, including the right-click that opens the row's menu, which
`.contextMenu` gives no notice of. The first version measured the text with
`NSHostingView.fittingSize`, which answers before the view has a width to wrap
against: the tooltip came out **358 by 3,332 points**, two thousand points off the
top of the screen. Seen, not guessed — the window list says what size a window
is. Now the width is decided first and the height follows from it.

**The ring was illegible, in that word.** It was eleven points across with a
two-point stroke and a six-point letter. Now sixteen, three, and eight and a half,
with the light beside it grown from eleven to thirteen and the row from
twenty-two to twenty-four. Then a second look at a real capture: the consumed arc
did not separate from the track behind it — on a vibrant surface the difference
between two translucent whites is smaller than it is on paper. Track 0.20, arc
0.92, floor 0.62, and it reads at a glance.

The ten points this cost the name were bought back: the light and the ring are
one pair now, four points apart instead of seven, because they are one session
asked two questions. Measured, on a plain row with a `14:56` timestamp: 110.87
before, 100.87 with the ring, 102.87 after the pair was tightened.

**A door out of the strip.** Switching to traffic-lights-only was a menu entry,
and switching back meant finding a menu inside a panel thirty-five points wide.
The footer now carries three glyphs expanded — legend, width, menu — and two in
the strip: widen, and the menu. Verified by flipping the preference and reading
the window list: 240 × 189 with three, 35 × 189 with two.

Verified: 531 domain cases, 82 end-to-end, 9 documentation gates, 20 mutations
caught, 10 contract checks; and, for the parts no suite can reach, the on-screen
window list and two captures — the tooltip at 357 × 140 where it belongs, and six
rings whose arcs say 33%, 11%, 63%, none, 85% and 63%.

## 29 August — a point of type, bought from the timestamp

The proposal came from use and it was the right trade: shorten the time label and
spend what it frees on the size of the type.

`yesterday` measured **49.83 points** at eleven, `2d ago` 35.33, against `1d`'s
13.04 at twelve — and that field shares one line of 240 points with the project's
name, with `layoutPriority(1)` on the timestamp, so every one of those points came
off the name of precisely the row that had been silent for a day. The vocabulary
is now `14:49` today, `1d` to `6d`, `22/07` from a week out; `42m` and `1h25` on
the live states, unchanged.

The name and the timestamp went from eleven points to twelve. The arithmetic, all
of it measured rather than estimated:

| label | name before (11 pt) | name now (12 pt) |
|---|---|---|
| `14:56` | 102.87 | 100.48 |
| `yesterday` → `1d` | 83.17 | **119.96** |
| `2d ago` → `2d` | 97.67 | **119.96** |
| `22/07` | 101.74 | 99.25 |

Two points lost on the rows that were already fine, thirty-seven gained on the
ones that were not. On screen: `Acme Governance` and `acme-os-platform` now
fit whole, where an hour ago they were `Acme…vernance` and `acme-…latform`.

This trade only existed because of the morning's other work. The row can afford to
say `1d` because the tooltip says "last activity yesterday at 22:30" — and until
today that sentence was written, tested, and never once shown on a screen.

Verified: 532 domain cases, 82 end-to-end, 9 documentation gates, 20 mutations
caught; and a capture of the panel, because a width argument settled by arithmetic
alone is how the last one went wrong.

## 29 August — the second layer, drawn; and a glyph that only exists under the pointer

Two requests, and both are cheaper than they look because of what was fixed this
morning.

**The tooltip is a card.** Not because it is prettier: because the old one was a
`private var` on a SwiftUI view that appended sentences to an array and joined
them with newlines. Untestable by construction — and it had never been displayed
at all. `RowSummary` in Core decides what appears, in what order and under which
word; `TooltipCard` draws it and decides nothing. Fifteen cases hold the rules.

Two of those cases exist because the first version printed something false.
`— 412,117 of 1,000,000` for a session compacted since its last reply: a dash
followed by a figure reads as a figure with a typo in front of it, when in fact
there is no figure — the reading describes a conversation that no longer exists.
It now says *compacted since — that reading is void*, and draws no bar. And the
help line must not promise a modifier that does nothing, which is why a row on
another machine is not offered a folder this Mac cannot open.

The status words moved from `StatusPalette` to `SessionStatus`: the colour is a
property of the interface, the word is a property of the state, and a summary
assembled in Core cannot reach into the app to ask what a state is called.

**The folder opens, it does not get pointed at.** The first version used
`activateFileViewerSelecting`, which reveals the folder *selected inside its
parent* — the ⌘⇧R gesture. Tried with a synthetic ⇧+click, it opened
`Development` with a folder highlighted in it, and the answer came back in one
line: you already know where the project is, you want to be **in** it.
`NSWorkspace.open` does that. It also moved into a file of its own, because
adding it took `PanelController` to 787 lines against a self-imposed limit of 800.

**The folder appears under the pointer.** 18 points, measured, is what a
permanent glyph would take off every name for ever — 100.87 back to 82.87, which
is exactly where the names were this morning when `acme-os-platform` read
`acme-…latform`. So it is drawn only while the pointer is on the row, with
⇧+click and a menu entry for whoever prefers not to hunt for it. The cost was
stated before it was built and it is real: under the pointer a long name
re-truncates while you look at it, softened by a 120 ms ease. On a row that lives
on another machine there is no glyph, no menu entry and no mention in the help
line: `/home/dev/.notes` exists, and it does not exist here.

**Iterating without the keychain.** The Developer ID key asks for the password on
every signature; the local signing identity does not. So the loop is: build,
`open dist/LampBoard.app`, look, repeat — no prompt, at the cost of the
Accessibility permission, which only matters for raising windows and not for
anything being designed. One signed install at the end, one password.

Verified: 547 domain cases, 82 end-to-end, 9 documentation gates, 20 mutations
caught. And on screen, because none of the above is visible to a suite: the card
at 318 × 180 with its bar, a renamed row showing `idle · in Exit`, a void reading
showing no figure, and the folder glyph arriving between the timestamp and the
handle. The leak guard also earned its keep — the first draft of this work put
a real remote home directory into a source comment, and it was caught before the
commit.

## 29 August — the strip under the rows becomes part of the grid

The three glyphs down there were nine points at 0.32 opacity. Reported from use
in five words: *too small, and really hard to see*. That is what a control
looks like when it is drawn as a watermark — and two of the three had been added
only hours earlier, so nobody had ever had to find them before.

Twelve points now, and in the timestamp's colour rather than a fainter one of
their own: they are part of the panel's text, not a toolbar bolted underneath it.
The strip grew from 19 points to 22 to hold them, and a button's box is the strip
minus the gap above it — asking for the full height inside a shorter space is
exactly how the gear came out low and cut the first time it was a SwiftUI `Menu`.

The arrangement is the part worth keeping. The width control sits on the **left**,
centred in the lights' own column — it is the control that decides whether the
lights are all there is. The legend and the menu sit on the **right**, in the drag
handles' column. Each glyph lands in the column of the thing it acts on, which is
why the strip now reads as the bottom of the grid instead of a bar underneath it.
Measured: the lights' centre is 20.5 points from the panel's edge and the handles'
is 219, and both glyphs are drawn there.

In the strip there is no left and no right, only a middle: two glyphs, centred,
and the legend stays out — three would touch at thirty-five points wide.

Verified on screen in both modes: nothing clipped, the panel 240 × 192 expanded
and 35 × 192 as a strip.

**And then it was looked at again, at five times life size.** Bigger and better
placed was not enough: a question mark in a circle, a bare gear and a pair of
loose diagonal arrows have the same point size and nothing else in common. The
arrows are two thin marks with no bounding shape whose ink hangs to one corner,
so beside two round outlines they read as smaller, lower and unrelated — which is
what "disordinato" was pointing at, and no amount of margin would have fixed it.

All three are `.circle` variants now: 15 × 15, one silhouette, one weight. The
menu's is `ellipsis.circle` and not `gearshape.circle`, for two reasons that
happen to agree — a gear inside a circle at twelve points comes out a grey blob
beside a crisp question mark (rendered both, looked at both), and the button opens
the panel's *menu*, not a settings pane, which is what `…` means everywhere else
on this system.

A hairline now marks where the rows end, and the band below it is exactly as tall
as a row, so the footer belongs to the column's rhythm instead of sitting under
it. Each glyph also got the rows' own hover treatment — the same rounded white
wash, overflowing its layout box so the highlight is a target while the glyph
keeps its column. Measured on the capture: eight points of clear space above the
ink and eight below.

## 29 August — "is everything documented?"

The answer was no, and the useful part is *which* class of thing had slipped.

**A false claim in the front door.** The README said the slot number "appears next
to the name". It had not since this morning — the ring took that cell — and the
figure gates could not see it, because it is not a figure. That is the same class
as the twenty-one figures that had quietly stopped being true, one layer up:
prose about the interface, checked by nobody. Corrected, and the ring, the
tooltip card, the folder glyph and the strip under the rows are now described
where a stranger would look for them.

**Three files nobody had written a line about.** `UpdateChecker` and
`UpdateInstaller`, from the update flow of two days ago, and
`measure-compaction.py`, the script that settles the context denominator. All
three existed, worked, were referenced from decisions or traps — and were absent
from the code map, which is where somebody goes to find out what a repository
contains. `FinderReveal` was on the map but filed under `UI/`, where it does not
live.

**So the audit became a gate.** *Every file is on the map*: every `.swift` under
the two shipped targets, by file name or by the type it holds, and every script
in `Scripts/`. Scoped there deliberately — the tests are left out, because the
map samples the suites worth naming and a rule demanding all sixty would either
bloat it or teach people to add a row without a thought. It found the three
misses, and `bite.sh` now erases a file's row and then a script's to prove it
still catches them.

The registry gate did its job in the same minute: the new check went in without a
mutation, and the run went red saying *"Every file is on the map" has no mutation
in bite.sh — nobody has seen it fail*.

Ten documentation gates now, twenty-two mutations, all caught.

## 30 August — the icon says the name

The icon was three lamps in a row on a dark tile, and only one thing wrong with
it had ever been said out loud: it is horizontal, and the product is a column.

Three more turned up on the way to fixing that one. Red, amber and green in a row
on a dark rounded tile **are the window controls** — close, minimise, zoom — so in
the Dock the eye was parsing the app as a piece of window chrome. It said *traffic
light*, which is one lamp with three states, where this is many lamps with six.
And it was painted in Apple's system colours while the panel is painted in its
own, so the icon's amber and the column's amber were quietly different colours.

Twelve directions were generated and eight thrown away. The ninth was mine and it
was wrong: the annunciator panel the name actually comes from, a field of lamps
with one lit. The arithmetic killed it before taste could argue. A three by three
field inside the tile gives each cell eight and a half pixels at 32 px and four at
16, and four pixels do not hold a housing, a lamp and an arc. It was drawn rather
than debated, and at 32 px it is a dark tile with one orange speck: an icon that
looks like it failed to load.

**Then the shape arrived from the other side of the table.** Four lamps tall and
three wide, in the shape of an L. The corner belongs to both strokes and is
counted once, so four by three is exactly six lamps — and the panel has exactly
six states. Nobody arranged that; it falls out of the letter. So the L carries the
whole vocabulary along the path the eye already takes, down the stem and out along
the foot, with urgency falling as it goes.

Two things the drawing insisted on. **A letter needs every stroke lit**: the
honest pose, one lamp asking and the rest at rest, breaks the L in half and leaves
a constellation. So the letter and the six states are not two options, they are
the same option, and this is the one drawing in the project that shows a pose the
panel never strikes. And **the foot must not end on the dim lamp**, or the letter
reads as fading out — so the two reds moved next to each other at the end, where
their difference in brightness states the grammar the panel already uses instead
of hiding it.

Three rules are `assert`s now instead of intentions: lamps never closer than a
fifth of a lamp, or the stem closes into a bar; the figure always inside the tile
with a margin, because a mark on the rounded edge reads as a rendering fault; and
never under two pixels a lamp at 16 px. The third one bit on the first run. The
small sizes draw their lamps larger to survive, and the lift that had been chosen
by eye put the foot into the edge — 1.14 refused, 1.10 accepted. A rule nobody has
watched fail is a rule nobody has.

## 20 September — what a competitor was worth, and five things only a measurement could say

The day started with a link to somebody else's project: a traffic light for Claude
Code sessions, Tauri and Rust, alive and carefully made. The question was whether
there was anything in it worth taking.

There was one thing, and it was not a feature. **Claude Code has a native `http`
hook type.** Every event this panel watches was costing a `bash` and a `curl` —
578 tool calls in thirteen hours on one session, and there are two dozen sessions
open here on an ordinary afternoon. The other project used the native form and had
built a loopback listener and a token to make it safe. We already had both, for
other reasons, and were not using them.

Everything else it offered was either something this project already had, or
something it had decided against on purpose.

### Five probes, and three of them changed the plan

The migration looked like a rewrite of one function. It took five measurements
before a line was written, and each one moved something.

**A failed hook costs the turn nothing.** Three runs against a dead port: 7.2, 7.4
and 8.4 seconds, against a baseline of 7.2, 8.5 and 7.9. The worry had been
latency. The real cost was a **voice**: with every event registered natively, a
session ending while the panel was off printed `SessionEnd hook failed: connect
ECONNREFUSED` on the person's screen, every single time. Only that one event
complains; `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop` failed in the
same runs and said nothing. So `SessionEnd` keeps its script, which pipes the
answer to `/dev/null` and exits 0 whatever happens.

**`SessionStart` cannot be an `http` hook at all.** Registered twice in one run,
once each way, pointing at two paths of the same listener: only the command form
ever arrived.

**The entrypoint survives the change.** The header the script interpolates in a
shell and the header Claude Code interpolates through `allowedEnvVars` produce the
same value in every case — `claude-vscode`, `cli`, `sdk-cli`, and a planted
sentinel. That one was nearly got wrong: the first measurement was contaminated,
because the variable was already in the environment of the session running the
test. Rerun with the two forms registered **on the same event** so they could only
agree or disagree, and they agreed.

**The terminals were never the risk.** A census of the fifteen hundred most recent
transcripts turns up three entrypoints — `sdk-cli`, `claude-vscode`, `cli` — and no
emulator has one of its own. The migration *reduces* the exposure: a native hook
opens no shell, so it cannot be broken by `$SHELL`, by `PATH`, by a missing `curl`
or by anybody's rc file.

**And the tunnel is not a footnote.** Nine tenths of the work watched by this panel
happens on the other machine, which had been treated as a secondary case in the
plan. The whole chain was proved end to end — a session there, through the reverse
tunnel, to the listener here — including with the tunnel down, where the hybrid
shape stays as silent as it does locally.

### The event nobody had probed

`Contracts/assumptions.md` listed `PostToolUseFailure` among the events "not about
turn state", and labelled that whole group a hypothesis: read in the binary, never
measured. The label did its job.

Probed, it turns out Claude Code emits `PostToolUse` **or** this one, never both. A
permitted `Bash` that exits non-zero produces only the second. And `PostToolUse` is
registered here for exactly one reason — it is the only event that can prove a
permission prompt was answered, and clear the amber. So: grant a permission, watch
the tool fail, and the row stayed amber. The same stuck amber that rule was written
to end, surviving in the one case nobody had tried.

`PostToolBatch` was measured in the same pass and is **deliberately not**
registered, which is a stronger statement than leaving it alone. It fires once per
block of tool calls in one message — five parallel `Read`s produced one, five
sequential ones produced five — so its saving exists only where there is
parallelism. Worse, it fires **even when every tool in the batch was blocked and
none ran**, so it cannot carry the proof this panel needs from that position: it
would clear an amber nobody had answered.

### An allowance, and the assumption underneath it

The panel gained a strip at the foot of the column: how much of the account's
allowance is gone. It is off unless you turn it on, because it is the only thing
here that leaves the Mac besides the update check.

Three things were measured before building it. The figures come from
`/api/oauth/usage`, signed with the token Claude Code keeps in the keychain — which
carries **no access-control list**, verified with an ad-hoc signed binary that read
it with no consent dialog. The access token lives eight hours and Claude Code
rotates it there, so this app reads and never renews: the refresh token beside it
could be spent, and spending it might sign the person out of the tool this panel
exists to watch. There is no function in the codebase that reads it.

And the free copy is a trap. Claude Code caches the same figures in
`~/.claude.json`, needing no credentials at all. On the machine this was written,
that cache said the five-hour window was at 0% and the week at 6% while the account
was really at 9% and 15%. Fifteen hours out of date, with nothing on its face to
say so.

**Then the assumption underneath the whole feature turned out to be wrong**, and it
was not found by a test. It was never written down anywhere, so there was nothing
to test: *a person has one Claude account*. This Mac is signed in as an
organization account on a Team plan; the machine most of the work happens on is a
personal account on a Max plan. Two allowances, of two different sizes. One
unlabelled bar in that situation is not incomplete, it is **wrong** — it reads as
your remaining room while the sessions spending the other account's allowance sit a
few points above it in the same column. So: one group per account, each named, the
nodes asked as well as this Mac, and the request made **on** the node so that only
three percentages cross the wire.

### Two corrections that a review of the figures could not make

The strip shipped in a state that was numerically correct and unusable: four lines
per account, eight for two accounts, in eight-and-a-half point type on a panel two
hundred and forty points wide. It buried the column it was meant to annotate —
three of seven projects went off the bottom — and the panel's height arithmetic did
not know the strip existed, so the room came out of the rows. It had passed a
review that checked the numbers instead of looking at the picture.

The second version showed "whichever limit is highest", which was arbitrary: a
weekly figure at 32% is not news, and it kept hiding the one number a person can
act on. The line now carries the **session window and its reset** — when the work
stops and when it starts again — with another limit taking the line only when it is
genuinely spent, above 90%, because a window resetting in forty minutes buys
nothing if the week is gone.

And the hover showed nothing at all, because it was written with `.help(…)` —
which `Tooltip.swift` says, in as many words, does nothing in a window that is
never key. It is now a card in the same grammar as a project's: aligned labels, the
figures, and a bar per limit in the lamps' own three hues.

### The row learns where it is

Last, the smallest piece and the one with the most surprises in it. A session's row
now says which repository and branch it is in, resolved by the hook script in the
user's own shell — because this app must never read under somebody's working
directory, where macOS gates Desktop, Documents, Downloads and network volumes as
four separate grants.

Two of the git incantations were taken from the other project, and both are worth
the theft: `symbolic-ref --short HEAD` rather than `rev-parse --abbrev-ref`, which
prints the literal word `HEAD` for a detached head *and* for a repository before its
first commit; and `--path-format=absolute` on the git-dir comparison, without which
**every subdirectory of a repository reads as a worktree**.

Three defects surfaced getting it to the row, and all three were silent. The
identity rode only `SessionStart`, which a brand new session throws away (D44), so
only *resumed* sessions would ever have shown a branch. The signal's copy
constructor rebuilds every field by hand and the new one fell through the gap —
reaching the server and never reaching a row, with nothing failing anywhere. And
the script broke on `\/`, JSON's optional escaping of a forward slash: legal,
unused by Claude Code, used by Foundation, so it was right on every real session
and wrong in the test that found it.

The fix for the first of those is the one worth remembering. `Stop` keeps its
script rather than posting natively, because a native hook can only send headers
that were already written into `settings.json` — and a branch nobody has looked up
yet cannot be one of them. One process per turn, which is a different order of cost
from one per tool call, and that distinction is the whole point of the migration.

### The token rides the script, and the launch finishes the migration

`POST /signal` had refused a wrong token since the morning and accepted an absent
one, with the plan to require it in the next release. That plan had a hole: the
script carried no token. `SessionStart`, `SessionEnd` and `Stop` run the script,
and `Stop` is what turns a row green — so the day the token became mandatory, every
row on every machine would have stayed amber, and the node would have gone dark.

Two changes close it. The script carries the header now, from the same value the
native hooks do. And every launch repairs an installation written without it:
after the token is settled and before the server answers, both halves are read and
rewritten if either lacks the current value (D48).

The first version of that repair took the afternoon, and not for the reason it
seemed. Under a deliberate mutation — the installer handing the script no token —
two unrelated end-to-end cases went red along with the one written to catch it,
and the obvious reading was that the new case had polluted the shared home. It had
not. A case in the installation suite starts the bare binary on port 9903 against
the same home; its launch ran the repair, judged the tokenless script stale, and
reinstalled **at its own port**. Every hook then posted to a process that had
already exited. Read back through the code instead of the test output, the repair
had three defects: it imposed the launching instance's port; it imposed a fresh
installation's flags, dropping `PreToolUse` and message delivery from anybody who
had them; and it ran before the token store, so on the launch that regenerates a
burned token it would have written the old one into every hook.

The rule now is that an instance repairs only the hooks **addressed to it**, and
keeps their shape. A new end-to-end case lays out a 0.4.0 installation in a home
of its own, starts an instance on another port and checks that not a byte moved,
then starts the addressed one and checks both halves carry the token with
`PreToolUse` and the listener still registered. Under the same mutation exactly
the two token cases fail, and the transcript cases stay green.

What remains before the token can be required is the node: its script is rewritten
only by reinstalling from the settings window, and a node on 0.4.0 keeps a
tokenless one until then.

### The node, and the name before this one

"This product is not used by me alone." The remote half of the repair, as first
left, was exactly that: a button to press on every node, which the author
remembers and nobody else is told about. The fleet now judges a node's hooks by
the same rule at every check — launch, a host added, a tunnel coming back — and
rewrites them when stale, through the scripts that already make a dated backup
and refuse to write over a file that changed.

Looking at the real node before wiring it showed the bigger gap. Its nine hooks
are `command` entries under `.clawd-light/hook.sh`, the project's previous name:
alive, posting through the tunnel with the old host header, no token — and read
as *not installed* by everything that knew only the current path. Every node set
up before the rename is in that state, and so is every Mac that upgraded across
it without reinstalling. The rule knows the previous name now, the migration
removes those registrations as it writes the current ones, and the event added
since, `PostToolUseFailure`, comes along.

Two things were verified without touching the node. A domain case rehearses the
whole repair through the real Python scripts against a home laid out like it —
inspect, judge, merge, apply, inspect again — and `lampboard remote check
devmachine`, which is read-only, now says *hooks installed; carry no token; the
panel rewrites them when it connects*. The write itself happens at the next
launch.

The domain case for the rule also caught a defect already committed that
afternoon: the message listener was detected with `isInstalled`, which claims
native hooks too, so the repair would have switched message delivery on for
everybody who had never asked. By command path now, with the case kept.

One fact for the record, from the changelog rather than a measurement: the `http`
hook type appeared in Claude Code 2.1.63, and the installer does not check the
version.

Released the same evening as **0.4.1**, and the notes say the one thing 0.4.0's
could not: there is nothing to do after updating. The hooks on this Mac and on
every node are brought up to date by the panel itself.

And **0.4.2** an hour later, carrying the version guard below. Two point
releases in an evening rather than a fix waiting in `main` for the next one: a
fix that is not shipped is a fix nobody has.

### The version nobody had asked about

Last, after the release: the installer now reads which Claude Code is installed
before writing an `http` hook, and below 2.1.63 — the release whose changelog
added the type — keeps every event on the script and says so, here and on every
node (D49). A version it cannot read is taken as current, in those words, on
`status`. Proved in a home of its own with a Claude Code laid out as its native
installer does, pointing at a version from before the type: `install-hooks` writes
ten script hooks and names both versions, and the first launch adds the token to
the script without going native.

## 21 September — sixty requests an hour, per office

The morning after two releases, a screenshot from a colleague: *Could not check
for updates. GitHub is rate-limiting anonymous requests: try again later.* On the
machine this was built on, the same button offered the update. Both true.

The check asked GitHub's REST API, and the API gives anonymous callers sixty
requests an hour **per public address** — its own headers say `limit: 60`. The
colleagues sit behind one office router, so they share those sixty with each
other and with every tool on that network that asks GitHub without a token:
Homebrew, editor extensions, other updaters. Nobody was asking too often. The
sentence named a limit and blamed the person reading it; the cause was where they
were sitting.

The address that never changes answers with a redirect, and the redirect names
the newest release: `…/releases/download/v0.4.2/LampBoard.dmg`. Reading it is one
`HEAD` with redirects not followed, no API, no quota. The target is refused unless
it sits under this project's download prefix, as the API's asset was, and a
version that cannot be read is no offer. The API stays as the fallback for a
network that swallows redirects, and is never consulted when the redirect was
read and refused (D50). Verified here before wiring it: the 302, its `Location`,
and no rate-limit header anywhere on it.

Released as 0.4.3 the same morning.

### A row named after the last `cd`

A remote row called "experiment" that the click could not raise, beside one
called "EventsApp" that raised fine. The session file on the node said the first
had started in `simlab`; its hooks said `simlab/experiment`, because a
hook's `cwd` follows every `cd` Claude makes, and the window over there was
titled `simlab [SSH: devmachine]`. Locally this never showed: the resolver
folds a `cwd` into the editor window that contains it, read from the lock files.
Remotely there was nothing to fold it into, and the row took the last hook's word.

The node writes the same lock files — the Remote-SSH extension runs there — so
the probe now reads them, judged alive there, and a remote row is resolved against
them with the very function the local one uses. Before the probe has answered the
session file's own folder stands in; a row that spoke first is moved when the
answer comes, colour and history untouched (D51). `remote check` prints the
windows the probe sees, which is the list a wrongly named row can be read against.

## 22 September — the dialog every few hours

"LampBoard wants to access the key 'Claude Code-credentials'", with a password
field, every few hours. For the allowance strip, which is the one thing that
reads a credential it did not create.

`security dump-keychain -a` said what was happening. The item's decrypt entry
trusts two programs: `/usr/bin/security`, because Claude Code writes the item
through it, and `~/Development/clawd-light/dist/LampBoard.app`, the build for
which *Always Allow* had once been pressed. *Always* is stored by path, so it
did nothing for the copy in `/Applications`; *Allow* covers the running process
only; and a person who updated four times in a day was asked four times. The
reader also carried a note claiming the item had no access list at all, measured
two days earlier — wrong, or measured through `security` without noticing.

The reader now runs `security find-generic-password` and parses what it prints.
The tool is trusted for as long as Claude Code keeps writing through it, whatever
this app is called or where it lives, and a read through it asks nobody anything
(D52). Nothing else changes: the token is borrowed and never renewed, only the
access token leaves the parser, and a 401 still means silence.

### A line missing from the strip, with nothing to read

The same afternoon, on the fixed build: the strip drew the node's line and not
this Mac's. The reading itself was proved four ways — the debug binary, the
released binary from a terminal, the released binary with the panel's own
environment and no terminal, the released binary under `launchd` — and a fresh
panel on a scratch home drew the local line at once. Whatever the running panel
had got into, it had left no trace: the strip names a reason only when there is
nothing at all to draw, and the reader logged nothing. Now every refresh logs how
many accounts were drawn and where, and a missing local line logs why. The state
itself was not caught; the next time it happens the log will say.

## 25 September — the application's other name

Sessions opened from the Claude application reached the column, and the click on
one did nothing. The row said `entrypoint: claude-desktop`, on a node: the
application had opened the session on the devmachine over ssh, and Claude Code
2.1.281 there wrote `claude-desktop` into the session file and into every hook.
The panel knew the application by one name only, `local-agent`, read off a local
session file when the surface was built. The comparison failed, the row went
down the editor path, and a remote row with no Remote-SSH window raises nothing.

Both spellings are the application now (`ClaudeDesktop.isEntrypoint`), in the
four places the name was compared: the click, the deep-link rule, the desktop
sweep, and "found rather than announced". A desktop row on a node raises the
application here, which is where the conversation is.

## 26 September — the account the application spends

The Claude application had started running Claude Code sessions on the node for
the work shared with colleagues, under a Team account. The strip showed no line for
it. The application signs Claude Code in as its own account and hands the token
over in the environment of the process — `ps` on the node showed
`CLAUDE_CODE_OAUTH_TOKEN` on every `~/.claude/remote/ccd-cli/2.1.281` — and nowhere
the strip looked: the node's credentials file held another account, the keychain
here a third place with neither.

The strip now reads those processes, on this Mac and on each node (D53), and asks
usage and identity for each account found. The node's script also stopped putting
tokens on curl's command line.

Verified: the token taken from the running session answered 200 on both
endpoints, with the Team account's address; `lampboard usage` built from this tree
draws the organization account read here and the Team account read on the node,
with the node's own account — the same as this Mac's — collapsed into the first
line. Ten domain cases, one of which runs the node's script with an empty home and
demands a well-formed answer with the hosted list in it.

## 29 September — 429, a hang, and a link

**The strip went empty and said 429.** The node was now signed in on its command
line as the same account the application's sessions used there, so each round
asked for it twice, on top of what Claude Code and the application ask on their
own. Each account is now asked once a round, until one of its tokens answers, and
a 429 keeps the last readings on screen and doubles the wait (D54). Measured while
fixing it: the limit is per token — the node's own token was refused while the
application's, same account, was answered.

**A node answer that arrived and was thrown away.** `lampboard usage` kept losing
the node's line after fifteen seconds. Instrumented: ssh had exited within a
second, both pipes at end-of-file, and the reader was still waiting in
`waitUntilExit()` on a global-queue thread. Replaced by a termination handler set
before launch, here and in `Command.run`; the command now returns in one to two
seconds. Debugging it cost this Mac's token a 429 of its own, which is exactly the
case the carried-over readings exist for.

**A row that raised nothing for five days.** A session in `voicedesk` shown as a
terminal row: its editor window had opened `livenotes`, a link to `voicedesk`,
and the kernel reports the resolved folder as the session's `cwd`. Windows are now
resolved on disk when read, and a session under either spelling is the window's
(D55). The same row also said "waiting on background work", and that part was
true: a shell loop waiting for a file that never came, started on 23 September.

Verified: 805 domain cases, among them a real symbolic link on disk resolved to its
window, and the node's script executed with its own account in the skip list.

## 30 September — the right figures under the wrong name

"The usage of the organization account is completely wrong." It was the personal
account's usage: this Mac's `~/.claude.json` named the organization account while
the keychain's token was the personal one, and the strip took the name from the
file and the figures from the token. The node's line, really the personal account,
showed the same numbers; and because the Mac told the node it already had the
organization account, the node skipped the application's tokens, the only ones
that were. Identity is now asked of each token and remembered by its hash (D56).

Verified with one real round: the personal account read here, the organization
account read on the node from the application's sessions, each with its own
figures. The node's script test now seeds the remembered identity and a
`~/.claude.json` naming somebody else, and demands the former.

Also found: Xcode was installed on this Mac and `xcode-select` now points at it
(Swift 6.4), which fails the build on warnings the Command Line Tools' compiler
(now 6.3.3) does not raise. This fix was built and gated with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`; moving to the new compiler is
its own piece of work.

## 30 September — a row called `vigilant-ramanujan-790712`

A conversation from the Claude application, on the node, in the `Ledger` repository:
the application had given it its own worktree, `.claude/worktrees/
vigilant-ramanujan-790712` on branch `claude/vigilant-ramanujan-790712`, still at
`main`'s commit. The row carried the generated name. Rows of the application's
worktrees now read `Ledger · vigilant-ramanujan` (D57); seven domain cases, among
them an editor's worktree row that must keep its folder's name.

## 4 October — LampMaster, the part that decides

The director has a name, LampMaster, and its first stage: the cards a transcript
is read into, the signals that need no model, the frame the hourly round is given
and the validator between the round and the panel (D58). Nothing runs a model
yet and nothing reads a disk: this is the part that decides, under 36 new domain
cases. The round itself was measured first, read-only, against real sessions —
and the measurement that mattered was the one before it: an unconfigured
`claude -p` spends 268,908 tokens to say "ok".

The gate now runs on a second Mac (`Scripts/run-remote.sh`), and the package
builds with Swift 6.4.

The round's own machinery followed: the command it runs and the envelope it reads,
the calendar that skips a round for nothing, and the ledger of what was shown and
what became of it (D59). The frame goes in on standard input, because an argument
is readable with `ps`; one real call with the exact arguments confirmed it, at
1,483 tokens. 16 more domain cases.

Then the round itself, in the running app: cards kept from the transcripts by byte
offset, the five-minute tick, the files under `~/.lampboard/lampmaster/`, and a
`/lampmaster` route behind the token (D60). LampMaster is off until switched on.
Seven end-to-end cases drive the real binary against a fake `claude` that writes
down what it was given: the frame arrives on standard input and never as an
argument, an invented quote is dropped, nothing new means no call. One of them
caught two rounds in the same second tying on their stamp, and the older one
winning; the ledger now goes by the order of the file.

LampMaster then reached the panel: one line under the column while it is on, its
cards in a window of their own, and a section in Settings with the sentence that
says what it sends and spends (D61). Its actions are the rows' own. Measured on the
test Mac against invented sessions: the round showed both suggestions of a fake
`claude`, and the panel grew by exactly the line, from 65 to 82 points.

A first real round in the app, on the test Mac with Opus and four invented
conversations, found both links hidden in them — a session stuck on a 404 and
another that had renamed the endpoint, a third about to ship the old path — and one
session done and saved: 13.6 s, 3,898 tokens, $0.047, nothing dropped by the
validator.

Then LampMaster became something a session can call (D62): the MCP protocol, three
lookups that run no model and never hand one session another's words, and the
question that does run one, with its sources screened and its limits. Measured
first with a throwaway server: Claude Code tells it the calling session's id, and
opens with a method of a newer protocol revision before `initialize`.

`lampboard mcp` then joined the two: the process Claude Code starts, forwarding each
call to the running panel with the token, as the hooks do. A security review found
the question's limits could be outrun — every question arriving during a
minute-long answer read the same history — and that titles and file names, chosen
by other sessions, reached the asking model untouched. Questions are now booked
before they run, two at most at once; names are flattened and clipped, and every
result opens with a notice that it is data, not instructions.

Last, the switch that puts `lampmaster` into Claude Code for every session (D63),
and the proof the plan asked for: on the test Mac a throwaway session, Haiku,
given the freshly built server, called `overlaps` and found the invented session
that had written `routes.ts`, then asked LampMaster who renamed the endpoint and
got the answer, in Italian, with its one real source — 11 seconds, $0.023 for the
caller and 1,904 tokens for the question. The run also showed every question
written twice to its ledger, booked and answered, because a booking read back had
lost its fractions of a second; it is matched by session, question and second now.

The tutorial began with its two foundations (D64): the script of invented sessions
the tour, the screenshots and the site will all be played from, checked to hold
nothing real, and the tour itself — steps that move only on their gesture, follow
the installed version, and resume where they were left.

Then the trial itself: `lampboard tour` starts a second panel on a temporary home,
which sets its stage — an editor lock per invented project, a stand-in process per
session — and plays the script into its own server. The end-to-end suite runs it
twenty times faster and finds every session in the state the reducer produces, and
nothing left behind on quit. A trial without `LAMPBOARD_HOME` is refused: it would
write invented sessions into the real `~/.claude`.

And the tour on screen, photographed on the test Mac: the trial panel opens with
the band — "TRIAL · invented sessions", step 1 of 4 — over the four invented
sessions in their scripted colours, LampMaster's line and a quota at 62%. Opening
the green row moved the band to step 2; opening the wrong row did not. The first
try found a trial that would not quit: opening a row reached for an editor that an
invented folder does not have, and the modal warning held off the quit. In a trial,
opening a row now only marks it seen, which is the gesture the step teaches.

The tour has its doors: *Take the tour…* in both menus, and an offer right after
the hooks are installed, the one moment somebody is certainly looking at LampBoard
for the first time.

That moment now opens *Getting started*: the setup, each item said before its
button — what the hooks write, what the Accessibility permission is for, what
LampMaster sends and spends — and the first steps with one's own sessions, ticked
from what the panel already knows. Photographed on the test Mac.

The README's picture now comes from the same script: `make-screenshots.sh` starts
the trial and photographs it, so demo data lives in one place. The script grew to six
sessions, one per state, the last a Codex one; the blue row needed a shell left
running, because the panel rightly does not count a monitor as work.


The companion mod's first piece is the part that decides what to believe (D65):
the reports it will post — the session's own context count, its cost, the
account's windows, its surface, why it ended — read and bounded on the way in, and
kept per session beside the column. The colours stay with the hooks. A figure the
session counted itself outranks the transcript's arithmetic, and nothing the
transcript reader finds later replaces it.

Then the mod itself, and its door in the panel. `mod/` holds the plugin and the
repository is its marketplace; it posts to `POST /mod`, whose token is required
from the first day, since no copy of the mod predates it. It finds the port in a
file the panel now writes beside the token: the hooks carry the port in their
script, the mod is the same file everywhere. Tried for real on the test Mac: a
throwaway Claude Code 2.1.289 session with the mod loaded from its folder, against
the panel on a fake home — `start`, then `measure` with 21,140 tokens of context,
then `end`, all received, in a five-second run that cost $0.0023. `claude plugin
validate --strict` reads the module and lists what it does: three hooks, the calls
`$.env.get`, `$.fs.read`, `$.http.fetch`, `$.session.id` and `$.session.model`, the
environment it reads, `HOME` and `LAMPBOARD_HOME`, and nothing it writes.

A security review of the route and the mod found one way to stop the panel: a
rate-limit figure of `1e300` is a finite number, and turning it into an integer
traps, so one report would have killed the app; figures are now clamped before
they are converted. It also found that a project's settings can set environment
variables for its sessions, so a cloned repository could point the mod at a home
and a port of its choosing. The mod now takes only an absolute home, no port
below 1024, and sends nothing until the port answers `/health` as LampBoard:
tried against an impostor on the test Mac, which saw three health checks and no
token. A model name is held to an allowlist, and the port file is written under
a fresh name opened exclusively.

And the way in. The app carries the mod's files and installs them from a folder of
its own, `~/.lampboard/mod-marketplace`, through Claude Code's `claude plugin`
commands (D66): `lampboard mod install`, `uninstall`, `status`, and
`uninstall-hooks` takes it out with the rest. Tried with the real `claude` on the
test Mac, in a fake home: installed, a throwaway session reported 20,844 tokens of
context through it, uninstalled clean, and the account's real
`~/.claude/settings.json` hashed the same before and after. That last check found
something worth fixing: under `LAMPBOARD_HOME` the app's `claude` inherited the real
`HOME`, and `claude` writes its settings from `HOME`; it is now handed the fake one,
for the MCP server's registration too.

The mod has its place in Settings: a switch, what the mod does said before it is
pressed, and a button that asks Claude Code what it reads in the version this app
carries — `claude plugin validate`, put into four sentences, an unknown call shown
as Claude Code spelled it so that a changed mod looks changed. Getting started
lists it among the optional items. A code review of the installer found what two
entry points at once would do — the launch refresh re-enabling a mod somebody had
just switched off — and what a refused step left behind: a declared marketplace
that made every later attempt fail. Installs now take turns under a lock the
command line shares, always start from a clean slate, and take out again whatever
a refused step left half in; an end-to-end case refuses one on purpose and checks
the next try works. Tried again with the real `claude` on the test Mac: installed,
20,844 tokens reported from a throwaway session, uninstalled, the folder gone, the
account's real settings unchanged.

The allowance strip learns from the mod (D67). A session counts its account's
session and week windows on every response, and the mod, now 1.1.0, passes them on
together with whether the session runs on Claude Code's default configuration — a
session with a `CLAUDE_CONFIG_DIR` of its own may be another account, and its
windows are left out rather than drawn under the wrong name. With the mod, the strip
needs no request and no switch; the request, when on, stays the reserve and the only
source of a model's own weekly cap. On the test Mac a throwaway session's measure
carried two windows, and the panel, switch off and no row, grew from 65 to 86 points
to draw the bar. An installed 1.0.0 is replaced at the next launch.

And what a session has cost, which only the session knows: with the mod, the
row's card says it, summed over the project's conversations, at list price — a
line that is simply absent without the mod rather than a zero, and never `$0.00`
for a session that has cost under a cent. It reaches the row the way the context
does, as a figure the reducer adds and no colour.

The mod's dependence on Claude Code is now in the contract like the hooks': a record
in `Contracts/assumptions.md`, the names and the exact hooks and calls in
`required-fields.json`, and a section of `check-contract.sh` that finds the names in
the binary and has `claude plugin validate --strict` list the mod's hooks and calls.
Its first run on the test Mac failed, rightly: mod 1.1.0 reaches `$.env.get` from two
functions, Claude Code writes that as "(via config, panel)", and splitting the list
on commas before dropping the parenthesis made one call into three — the same split
in the Settings card would have printed the fragments as calls the mod makes.

The local server now refuses what a web page could send (D68): any request with an
`Origin`, any `Host` that is not loopback. Against a page posting to `/signal`, which
still takes a signal without a token for old hooks, and against DNS rebinding. Tried
for real on the test Mac: a throwaway session's native hooks and the mod all went
through, none refused, and a POST carrying `Origin` got 403. Each guard was seen
failing its test with the guard taken out. And a session file whose pid now belongs
to another process is a dead session: `kill(pid, 0)` asked only whether the pid
existed, so a recycled pid kept a dead row alive for as long as the stranger ran.

Notifications now say what happened (5.6): the command or the question a session
waits on, why a turn died, and — for whoever switches it on — the first line of a
finished answer. A failed turn notifies now too, which *Getting started* had been
promising without the code doing it. Failed and finished are announced on the
transition only, so a column already red at launch is not a burst. And the menu
bar can carry `wanting · working` beside the lamp, off by default so nobody's menu
bar changes width on an update they did not ask for. Not seen on screen: on the
test Mac the status item's window could not be isolated for a capture; the counter
is held by its tests.

A session that has sat on one tool for a quarter of an hour now says so (D69): the
mod, 1.2.0, reports each tool's start and end with its shell line or file path, and
a working row shows `⌛ 22m` where its duration was, with the tool and the line on
its card. Not a seventh colour: a build can honestly take ten minutes, and only a
person can tell it from a command waiting on input. Tried on the test Mac: a
throwaway session's three-second `sleep` arrived as a start and an end three
seconds apart. The contract records the new hook and passes. A security review
asked for the rest: only the command's first line reaches the panel, secrets in it
masked; an "end" that overtakes its "start" no longer leaves a phantom; a call from an
earlier turn is not this one's; a subagent's call is not tracked.

`lampboard watch -- <command>` makes any long job a row (D70): the command runs in
the terminal as it would have — output, input, exit code, Ctrl-C — and the panel
shows it yellow, then green on 0 or red with its code, beside the sessions of the
same folder. Its rows belong to a third harness, `command`, with no context ring and
no window to raise. Photographed on the test Mac with three commands; the first
capture was an empty panel, because the sweep that forgets terminal sessions while
they are switched off took the watched commands with them, and a dashed ring said
"nothing read yet" about something that will never have a reading.

`/lampmaster <question>` now works inside any session with the mod, 1.3.0 (D71): the
question goes to the route the MCP tool uses, under the same limits, and the answer
is printed for the person, never left in the model's context. Tried on the test Mac
with a throwaway session: the invented session that renamed an endpoint, named with
its source, in 6 seconds; off, empty and with the panel closed, one line saying why.
`claude plugin validate` lists a hook with its matcher (`command.run{command=…}`),
which the contract check now reads as the hook's name.

LampMaster no longer waits for the hour when a session starts repeating a failure
or stops moving (D72): a quick round runs at the turn's end, ten minutes after any
other at least and six a day at most, only for a session and signal the last round
had not seen. The plan said a small model; measured on the test Mac, Haiku thought
for up to 56 seconds before answering, Sonnet answered the same frame in 6.5 for
less. Both found the invented session that had fixed the same missing script.

0.5.0 is out: LampMaster, the companion mod, `/lampmaster`, quick rounds,
`lampboard watch`, notifications that say what happened, the menu bar count,
Getting started and the trial tour. The next version acts on sessions rather than
only showing them, and D73 says so before any code does: every act is a click, each
capability that can start a turn is off until switched on, and the one door not yet
tried — deciding a permission from a mod — is the first thing measured. D9, which
still said only amber is ever notified, now says what 0.5 changed.

The first piece of the new panel is the queue's logic, without a pixel yet (D74):
what waits for you, as cards in the order that costs the least waiting —
permissions, questions, stuck turns, failures, answers, LampMaster last — armed
600 ms after they appear, and worked with `J`, `K`, `O` and `E`. The keys that will
answer a permission are there already and say they cannot yet.

And now drawn (D75): the queue sits above the rows in the wide panel, four cards at
most and a line for the rest, each dimmed for its first 600 ms, and the panel grows
by exactly what it draws. It takes keys only while the panel holds the keyboard,
which a click gives it. Photographed on the test Mac with the trial's sessions: a
session asking, a failed turn, an answer to read and LampMaster's suggestion, in that
order; the README's picture is that one now. Looking for why the trial's Codex row
had vanished from it turned up the reason it never drew its letter either: no
process named `codex` holds its rollout open, and that is the only proof of life a
Codex session gives.

So the trial now gives it one. The app runs itself as `codex trial-hold <rollout>`,
through a hard link in the trial's home — the only name a process table believes,
measured against a symbolic link (read as `tail`) and a script (read as `bash`) —
and the trial's rollout starts with the `session_meta` the sweep reads to know whose
it is. The row is a Codex row after three sweeps now, where before it went at the
first and came back from the trial's session file as a Claude Code row, which is the
picture the README had been showing. The README has six projects again, and a `G`.

Every row now says what its session is doing (D76), on a second line in the wide
panel: the ask, the tool it is on, why it died, the answer's first line, what holds
it. Twelve points a row, which is what reading the column without hovering costs.

The bar's logic (D77): text finds a session by its name, then by what it is doing;
`@` names one, `?` asks LampMaster, `/` runs an action; empty, it lists what needs
you. `⌘K` will reach it inside the panel; a shortcut from anywhere stays off until
chosen, because a global `⌘K` would take VS Code's chords away from it.

And drawn: the bar sits at the top of the wide panel as a button until it is
opened, because a field there took the keyboard whenever the panel became key. The
README's picture caught it in a first draft as a grey square: `make-screenshots.sh`
took the widest window of the process, and the field had left a hidden one wider
than the column; it now takes the widest visible one.

The bar can be reached from any application, once a shortcut is chosen in Settings
(`⌥⌘K` or `⌃⌘K`; off by default). Carbon's hot keys, so no permission is asked.

The Plancia's groundwork, without a pixel: the three depths of the UX with their
keys and widths, and a per-session log of what it has been doing — each tool with
its duration, each turn with what it alone cost.

The panel is 340 points wide now, the column 44 (D78): the widths the UX settled on,
because a row's second line and the bar are sentences. A panel kept at the right
of the screen grows to the left.

The Plancia opens (D79): a session beside the list, toward the middle of the
screen, from its row's menu or `⌘⇧L`, with its conversation in the chat window's own
view. Photographed on the test Mac through a new `--plancia` launch option. Building
it found that a LampMaster card in the queue opened nothing — it names sessions by
eight characters, and every lookup wanted the whole id.

And its tabs: Activity, each tool and how long it ran and each turn and what it
cost; Cost, the context and what the session has cost. Both from the mod's reports
and the hooks' turn ends, kept in memory for the sessions seen most recently.

Allow and Deny from the panel start with a measurement and its rules (D80). On the
test Mac a mod's `tool.check` waited twenty seconds for a listener and its `deny`
held; at sixty-five the engine went ahead on its own; answering `ask` in an
interactive session brought the ordinary dialog back. So the panel gets 55 seconds,
asks are only the ones the engine would have put to the dialog, and anything the
panel does not answer goes back to that dialog.

And the door: the mod asks the panel through `/check`, the panel answers through
`/check/answer`, and a throwaway interactive session on the test Mac had one `touch`
blocked and one let through by exactly those answers. The switch is off by default;
the buttons in the queue come next.

A security review then showed how a cloned repository could have answered for the
panel: its settings can set `LAMPBOARD_HOME`, and the mod followed it. Measured: a
project can set `LAMPBOARD_HOME` and cannot set `HOME`. So the mod follows `HOME`
alone, and never sends the token for a permission: it proves it holds it, with an
HMAC built by hand from the one hash function its runtime offers, and trusts only
an answer signed back. On the test Mac, a hostile project's listener that always
said allow heard nothing, and the panel's deny held.

## 5 October — the sessions nobody is in front of

The loop moved to the Linux machine that never sleeps; the Mac it tests on stayed
where it was, reached over ssh. The same day showed a risk in that move: a resumed
copy of the loop's own session worked the same branch in another terminal, until a
stray duplicate decision gave it away. A single copy is now checked before every merge.

The Agent View's background sessions (`claude --bg`) were invisible: their live file
says `kind: "bg"`, and the rule for "someone is in front of it" refused every kind
but `interactive`. They are now rows of their own (D103), and read what Claude Code
keeps about them in `~/.claude/jobs` (D104): the summary it writes, what a blocked
one needs, the id `claude attach` takes, which the row's menu copies. A throwaway
background session on the test Mac, with Haiku, showed the same id in five places
before any of it was trusted.

Then the decision board (D105). Something settled in one session reaches the
others in the same repository: pinned with `lampboard decide`, handed by the mod to
each session's next prompt as context, once per change. These are the first words
the mod puts into a conversation, so the request is proven with the permission key
and the answer is taken only when signed with it. A review found that the
repository's name, which a project chooses, was being signed into the withdrawal
sentence; the sentence now names nothing. A throwaway session on the test Mac
quoted the decision, then answered "withdrawn" once it was taken off.
