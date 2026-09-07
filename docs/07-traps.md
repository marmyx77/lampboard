# Traps

The catalogue of the real defects found in this project. Each one with its
**symptom**, **cause**, **correction** and **lesson**.

It is the most useful document in the folder, because every entry is time you
won't have to spend again. They are ordered by how much they teach, not by
severity.

---

## The lessons, one line each

1. **Verifying with the wrong tool is not verifying.** Four defects survived a
   check made with a medium different from the one the app actually uses.
2. **A fake success costs more than an error.** Most of the time lost here came
   from operations that said "done" without having done it.
3. **What you don't run is what breaks.** Three defects out of nine were in the
   one file that was never executed.
4. **A file's timestamp is not a sign of life.** Three separate defects, found in
   one hour, all of them reading `mtime` where a pid was sitting right there.
5. **Inferring a state is inventing one.** Two regressions in a single evening,
   both from deducing what a session was doing instead of measuring it.
6. **A list you filter is a choice about which mistake you can afford.** An
   allow-list and a deny-list fail in opposite directions; picking the wrong one is
   silent in exactly the direction that costs.
7. **A consumer must be able to tell "nothing" from "something you didn't get".**
   Anything dropped on the way to a reader has to be visible *to the reader*.
8. **A name in an enum is not a measurement.** It is worse than no evidence,
   because it feels like some — and being careful about a change's risk is not
   the same as checking whether it does anything.
9. **A correct model proves nothing about the screen.** The reducer was right and
   under test; the defect lived in the one layer no test touches, and it showed
   up in a state the model says cannot blink.
10. **A workaround the user learned is a defect you have not found yet.** "Click
    twice, slowly" was not a habit; it was the shape of a swallowed first click —
    and the accidents it caused were the shape of a column that reorders under
    the pointer.
11. **In a hosted SwiftUI view, the window runs the first round.** Moving by
    background, the first click in a non-key window, a drag on a handle: AppKit
    settles them by asking the hit view, and a SwiftUI gesture cannot answer.
12. **A feature that answers its own security question first can end up
    answering nothing else.** Decide what the row must *do*, then the mechanism,
    then its safety — and measure the machine before designing for it.
13. **Three readings that agree can agree on the wrong thing.** A denominator
    fitted to three hand-read percentages survived every sanity check and was
    refuted in twenty-four seconds by asking 18,622 files the same question.
14. **An API that compiles is not an API that runs here.** Every tooltip in the
    panel was written, reviewed and never displayed: AppKit shows them only in a
    key window, and this window is never key on purpose.
15. **When the suite dies with a signal, read the crash report before reading
    your code.** The name of the process that died is in it, and twice out of
    three it is not yours.

---

# A timestamp is not a heartbeat

Three defects, the same mistake, three different files. Grouped because finding
the second one should have made the third obvious, and it did not.

## Five projects that vanished on their eighth day

**Symptom.** Projects disappeared from the column while their VS Code windows were
open and their sessions were working. No error, no gap in the log. On the machine
where it was found, five at once.

**Cause.** A lock in `~/.claude/ide/` was believed only while it was younger than
seven days:

```swift
public func isFresh(at now: Date, maxAge: TimeInterval = .sevenDays) -> Bool {
    now.timeIntervalSince(lockModifiedAt) <= maxAge
}
```

But a lock is written **once**, when the window connects, and never touched again.
Its age measures how long the window has been open — and leaving a window open for
a fortnight is ordinary. The rule was expressing "this lock is probably orphaned",
which was a real concern, with a number that answered a different question.

**Correction.** The lock carries the editor's `pid`, and always did — the field was
parsed on day one and read by nobody. If that process is running, the window
exists, whatever the file's age. Age survives only as the fallback for a lock with
no usable pid, which is the case the rule was invented for.

**Lesson.** When a file carries a pid, the pid is the answer. `mtime` tells you
when something was written, which is only the same as "is it alive" for files that
are rewritten — and none of these are.

## A session that had been working for a week reported a week of silence

**Symptom.** A session actively working was invisible in the column, and stayed so
until its turn ended.

**Cause.** Adoption from the filesystem took its timestamp from
`~/.claude/sessions/<pid>.json`, which — exactly like the lock — is written at
startup and never again. A session opened seven days ago reported seven days of
silence, and the twelve-hour staleness rule removed it on sight. Measured:
transcript **1.3 minutes** old, session file **173.6 hours**.

**Correction.** Two changes, and both were needed. The activity timestamp now
comes from the **transcript**, which grows with every message and every tool
result. And pruning never removes a session whose process is confirmed running:
pruning exists to drop what cannot be accounted for, and a live pid is accounting
for it.

**Lesson.** The same one again, one file later.

## A hook that hit nothing, and said nothing

**Symptom.** A turn finished and the light did not go green. Intermittent,
maddening, and indistinguishable from the traffic light being broken.

**Cause.** A signal whose `cwd` matches no editor window is discarded — correctly,
because there is no row to put it on — and it was discarded **in silence**. After
restarting the Mac, a VS Code window writes no lock until its Claude panel
reconnects, so every hook from that window fell into a hole for as long as it took.

**Correction.** The behavior is unchanged. The log now names the folder nobody
claimed. Diagnosing this cost an evening; the next one costs reading a line.

**Lesson.** Discarding is a decision, and a decision that leaves no trace is
indistinguishable from a fault. Every `guard … else { return }` on the path of an
external signal deserves the question: *if this fires a hundred times, how would
anybody know?*

---

# Inventing a state

## Red while working, then yellow for everything

**Symptom.** Two regressions on consecutive attempts, both shipped to the user,
both worse than what they replaced.

**Cause.** Adoption has to give a session a state before any hook has spoken, and
`idle` was the honest placeholder. When the pruning fix made adopted rows survive,
that placeholder became visible: sessions hard at work showed **red**. The
correction was to infer — "the transcript moved in the last forty-five seconds,
therefore a turn is in flight" — and it was wrong for a reason that only shows up
on a restart: a transcript is appended for plenty of things that are not a turn,
**resuming a session among them**. Reboot, twelve sessions resume at once, twelve
files move at once, and the whole column turns yellow.

**Correction.** The inference was removed. `idle` is not a guess dressed as a fact;
it is the absence of information, and the first hook replaces it. The transcript's
timestamp is kept for the **clock**, where it is evidence, and kept away from the
**color**, where it was a guess.

**Lesson.** A column that is uniformly wrong is worse than one that is uniformly
cautious: the panel exists to make one session stand out, and if everything is
yellow nothing does. When tempted to derive a state from a proxy, ask what the
proxy does on the day everything happens at once.

**And the meta-lesson**, which cost more than the defects: both regressions were
made quickly, under the pressure of a user watching something broken. The fix that
worked came from the opposite move — stopping, replaying a real turn through the
real hook script on a real live session, and watching it across two realignment
cycles. Thirty seconds of measurement cleared three suspects and found the cause.

## A red test, hidden by my own grep

**Symptom.** A test had been failing for a day. Every check said everything passed.

**Cause.** The verification was `./Scripts/test.sh | grep -E "tests passed|failed"
| head -3` — and `head -3` cut off the summary line, leaving three green ticks from
the middle of a suite.

**Correction.** Read the tail, not the head. The summary is the last line for a
reason.

**Lesson.** This project has already shipped a test script that reported success
after running zero tests, and the entry for it is in this same file. The trap is
not the script: it is trusting a filtered view of a result. Twice now.

---

# Checks made with the wrong tool

## Title matching, broken for a whole day with ten green tests

**Symptom.** The click always led to the wrong window. Ten tests on the
recognition were green.

**Cause.** `NSAppleScript` returns the window list as an AppleScript list, and on
a list **`stringValue` is `nil`**. The code split it on `", "` and always got a
single empty element: no window was ever recognized, and the click always fell
back to the second strategy.

**Why nobody had noticed.** The manual check had been done with `osascript` from
a terminal, which **serializes the list into text**. The tests covered the
function, the manual check covered a different transport, and nobody covered the
joint between the two.

**Correction.** Read the descriptor's elements:

```swift
if descriptor.numberOfItems > 0 {
    let titles = (1...descriptor.numberOfItems).compactMap {
        descriptor.atIndex($0)?.stringValue
    }
}
```

**Lesson.** It is the origin of the entire e2e suite and of the `focus` command,
which prints the titles actually read.

---

## "I have the permissions", said by Terminal

**Symptom.** `lampboard focus lampboard` from a terminal answered
`✓ window raised`. The clicked panel did something else.

**Cause.** When you launch a binary from a terminal, macOS does **not** attribute
the TCC permissions to that binary: it attributes them to the *responsible
process*, which is Terminal. The check proved that Terminal can raise the window,
not that the app can.

**Correction.** The app's log records at startup what **the app itself** sees:

```
signature=stable accessibility=granted
```

**Lesson.** Same shape as the previous defect, in a different domain. When you
verify something that depends on the process's identity, **that process** has to
be the one answering.

---

## The socket that looked local

**Symptom.** None: the project ran for days with a socket reachable from the
whole network.

**Cause.** `NWParameters.acceptLocalOnly` looks like it says "this machine only"
and actually says "this network link only" — that is, the Wi-Fi the Mac is
attached to.

```
lampboard 32486 dev 4u IPv6 ... TCP *:9877 (LISTEN)
```

Anyone who got there could inject signals and drive the panel; with the read
endpoint it would have become a listing of the open projects.

**Correction.** `parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port:)`.

**Lesson.** Found by looking at `lsof`, not by re-reading the code. An e2e case
now queries `lsof` against the live process: it verifies the **fact**, not the
intention.

---

## The index that moves

**Symptom.** The click raised the wrong window — typically the last one used
before switching applications. **Every other time.**

**Cause.** Raising was two distinct Apple Events: one to read the titles, one to
`AXRaise` on `window <index>`. The list arrives in depth order, and **that order
changes on its own** as soon as the focus moves — that is, exactly while you
click a floating panel. The index computed against the first list pointed
elsewhere.

**How I told it apart from a permissions problem.** The log showed **zero
fallbacks**: the AppleScript was *succeeding*. Had it been a permission I would
have read `AppleScript failed`.

**Correction.** Raise **by title**, which is an identity rather than a position:

```applescript
set candidate to (every window whose name is "…")
perform action "AXRaise" of item 1 of candidate
```

**Side effect, and its correction.** Putting a title inside a script means
putting a **file name** in it, which isn't text you decide.
`AppleScriptString.escaped`, with six tests including a title built to break out
of the string.

**Lesson.** Intermittency is information, not an annoyance: it almost always
means something changes between two steps you thought were atomic.

---

# Fake successes

## `activate()` returning `true` without activating

**Symptom.** Click on the traffic light: nothing happened, and nothing said so.

**Cause.** `NSRunningApplication.activate()` invoked from an *accessory* app that
isn't frontmost is ignored by macOS — and **returns `true` anyway**.

**Correction.** `/usr/bin/open -b <bundle>`, which is a system process and does
have the right to activate. **With no path**: `open -b <bundle> <folder>` asks it
to *open* that folder and materializes a new window for it.

---

## An alert shown after a success

**Symptom.** "The Accessibility permission is missing" after a click that worked.

**Cause.** `return openViaCLI(path:) ?? error` — `nil` meant success, and
`nil ?? error` returns `error`.

**Correction.** `FocusResult`, a three-case enum (`raised`, `activatedOnly`,
`failed`), because they deserve different reactions: silence, a note in the menu,
an alert.

**Lesson.** Flattening different outcomes onto `Error?` produced **two** defects
in this file. When the cases deserve different reactions, they deserve a type.

---

## The fallback that always fired

**Symptom.** Every click opened a new VS Code window, with no project.

**Cause.** The fallback sat behind an `@autoclosure`, but the call site wrote
`fallback: { … }()` — the trailing parentheses **invoked the closure
immediately**, so `open` ran even after a successful raise.

**Correction.** Explicit guards, and out with the abstraction that hid the order.

**Lesson.** On a path where the order of the steps is the thing that matters,
writing it out explicitly is worth more than not repeating yourself.

---

## The test script that ran nothing and said it passed

**Symptom.** None. `./Scripts/test.sh` printed `0 tests passed` for the
end-to-end suite and exited 0. Running `swift run LampBoardE2E` by hand gave 66.

**Cause.** The runner picked the filter as "the first argument not starting with
`--`". The script invokes it as `--port 9899`, so `9899` became the filter, no
suite matched, and an empty run is a passing run.

**Correction.** The filter now skips the value of `--port` as well.

**Lesson.** Verified in reverse, as the rule requires: with the defect back,
`--port 9899` gives 0; with the fix, 66. But the deeper point is that **a green
result from having run nothing is the worst kind of fake success**: a failure gets
looked at, and zero passing tests get read as "all fine". Any runner that reports
a count should be suspected the day that count is zero.

---

## The filter that stopped at the first field

**Symptom.** Reading another machine's sessions worked, and the column filled with
`observer-sessions` — claude-mem's own machinery, which opens **thousands of
sessions a day**.

**Cause.** Not the remote path. A latent defect in `deservesTrafficLight`:

```swift
if let kind, !kind.isEmpty {
    return kind == AppConfig.interactiveSessionKind   // returns here
}
guard let entrypoint, !entrypoint.isEmpty else { return true }
return !AppConfig.nonInteractiveEntrypoints.contains(entrypoint)   // never reached
```

The observer writes `kind: interactive` **and** `entrypoint: sdk-cli`. Because
`kind` is present the function returns `true` immediately and the entrypoint —
which is in the exclusion list — is never looked at.

**Why it had never shown.** Locally those sessions were dropped for an unrelated
reason: no editor window claims `~/.claude-mem/observer-sessions`, so the workspace
resolver refused them. A correct rule was masking a broken one. Remote sessions do
not go through that resolver, and the moment that accidental filter was gone the
defect surfaced.

**Correction.** Both fields have to agree. `kind` says whether the loop is
interactive; `entrypoint` says whether a person started it. They are different
questions and both are written by Claude Code.

**And an assumption retracted.** A test asserted the opposite — *"the kind field
takes precedence over the entrypoint"* — reasoning that Claude Code writes `kind`
itself and that beats deducing from a command name. Both halves were true and the
conclusion was still wrong. Its neighbor justified the bias: *"one row too many
can be seen and fixed; a missing row stays silent."* That holds for one row. It
does not hold for two thousand a day. The test now asserts the measured case.

**Lesson.** *A filter that returns on its first field is a filter with one
criterion, however many it appears to have.* And more usefully: **two correct-looking
rules can hide each other.** The workspace resolver was right, the interactive
filter was wrong, and because the right one ran first the wrong one was free for
months. Removing a filter is a way of testing the ones behind it — which means a
feature that widens what gets in is also an audit of everything downstream, and
should be read that way rather than as a feature.

---

## The yellow that outlived its answer by a day

**Symptom.** Reported by use: *"too many yellows stay yellow — look at that
session."* The row had been `working` since 11:55 the previous day.

**Measure.** The per-signal log, again:

```
12:49:18  UserPromptSubmit   working -> working
12:55:01  Stop               working -> working     ← held by "work in flight"
```

Then nothing, for eighteen hours. The transcript's last record is at **12:55:02**,
one second after the `Stop`. The answer had been sitting there the whole time.

**What was not in flight.** No `run_in_background` in the entire session — zero.
The one workflow of that turn had finished and notified at 12:20, thirty-five
minutes *before* the `Stop` (four of its agents had died on a spend limit, but the
workflow itself closed). Nothing the user had asked for was running.

**What was.** Not recoverable for that `Stop` — the log recorded the count, not
the types — but the binary says what could have been. Claude Code's own "active
tasks" view is:

```js
Object.values(e).filter(bL).filter((t)=>t.type!=="remote_agent"&&t.type!=="dream")
```

It starts from `bL`, the very predicate that builds our payload, and then removes
`dream`: background memory consolidation that starts on an idle session, writes
nothing to the transcript, and does not wake the session when it ends. Claude Code
lists it in the hook payload and hides it from every view of its own. We took the
payload at its word.

**Correction, in two parts.** The log now names the *types* in flight on every
`Stop`, so the next one of these is read rather than reconstructed. And the rule
narrows by exactly Claude Code's own two exclusions — `dream` and `cloud session`
— anchored to the binary by a contract check, so the day Claude Code changes its
mind the check says so. Anything else, including a type never seen, still counts.

**Lesson.** *"Presence in the list is the signal"* was right about the filter and
wrong about the list. The producer's payload and the producer's **own view of the
same data** disagreed, and the honest definition of "work" was the one it shows
its users, not the one it hands its hooks. When a dependency exposes the same fact
through two doors, read both before choosing.

**And once more on instruments.** The count was logged; the types were not. The
fix took an hour because the one line that would have settled it in a second had
been written to save a few characters. Log the thing that explains the state, not
the thing that summarizes it.

---

## Thirty-three minutes of asking a question that had been answered

**Symptom.** Reported by use: *"when Claude asks something the light flashes,
rightly — but once I've answered it keeps flashing even though Claude has gone
back to work."*

**Measure.** The per-signal log, which existed for exactly this:

```
08:48:27  Notification/permission_prompt   working -> awaiting
08:52:08  SubagentStop                     awaiting -> awaiting  [subagent]
08:52:08  SubagentStart                    awaiting -> awaiting  [subagent]
   …      fifteen subagent events over thirty-three minutes, all awaiting -> awaiting
09:21:48  UserPromptSubmit                 awaiting -> working    ← only here
```

Subagents were **being spawned**, so the prompt had plainly been answered and the
turn had resumed. The row stayed amber until the user's next prompt, half an hour
later.

**Cause — two of them, independent, and both had to go.**

*First:* no in-turn heartbeat. Of the eight events registered **at the time**, the only ones that
can fire between a mid-turn `Notification` and the closing `Stop` are the subagent
pair. `PreToolUse` and `PostToolUse` were decoded but **not registered**, on the
documented reasoning that they "add nothing `UserPromptSubmit` and `Stop` already
bracket". This bug is what they add.

*Second:* even the subagent events could not help, because `awaiting` overrides
them by design — *"waiting for a permission always wins: it blocks everything,
subagents included, and it needs you now."* True while the prompt is open. False
the moment it is answered, and nothing said it had been.

**Correction, in two parts.**

- A subagent **starting** releases the amber. A main loop blocked on a prompt
  cannot spawn a child; a birth is proof the prompt was answered. A subagent
  *finishing* releases nothing — one already running when the prompt opened can
  finish while the turn is still blocked.
- `PostToolUse` joins the default event list and releases the amber.

**And the part that was nearly wrong.** The first version of the fix let *any*
tool event release the amber, which broke an existing test — `A late PreToolUse
does not clear the amber`. That test was right, and the binary says why:

```
"PreToolUse"),permissionDecision:…,permissionDecisionReason:…
```

`PreToolUse` carries the permission decision in its **own output schema**: it runs
*inside* the decision, therefore **before** the prompt. One arriving afterwards is
out of order, and releasing on it would clear a question still open. `PostToolUse`
cannot fire unless the tool actually ran — which requires the permission to have
been granted. Only that one is proof.

**Lesson.** *A rule that is right while a condition holds needs something that
says when the condition stops holding.* `awaiting` overriding everything was
correct and had no exit. And the exit had to be chosen by asking which event
**cannot** happen unless the thing you care about already happened — not by
symmetry with the green case, which is what the first attempt did.

**And a note on the instrument.** This was diagnosed in one log read. The
per-signal color-transition log was added three weeks earlier, after a defect
that took three evenings to find without it. It has now paid for itself.

---

## The blink that outlived its state

**Symptom.** Reported by use, two days after the previous fix in this family:
*"why is the development-methodology session blinking red?"* Red is `idle`, and
`idle` cannot blink: `shouldBlink` is true for `awaiting` alone, and a test pins
that down.

**Measure.** The model was right. The server snapshot said `idle` since 14:37,
and the per-signal log had the row's whole day:

```
11:23:28  Notification/permission_prompt   working -> awaiting
11:38:29  PostToolUse                      awaiting -> working
13:20:33  Stop                             working -> ready
14:37:12  (click on the row)               ready -> idle
```

Then the screen, by a means that can see it: the panel is a non-activating
`NSPanel` with no title, absent from every window list, so it was found by
`CGWindowListCopyWindowInfo` and photographed with `screencapture -l <id>` four
times, 0.35 s apart — half a blink period. The dot alternated between full red
and the dim red of rest. The six other idle dots did not move. This was the only
row that had been `awaiting` since the app started, nine hours earlier.

**Cause.** In the view, not the model. The dot was one `Circle` with a `@State`
flag. Status becomes `awaiting` → the flag goes on → `.animation(repeatForever,
value: flag)` starts the pulse. Status leaves `awaiting` → **that same render**
puts the opacity back to rest, *unanimated*, because the flag has not moved yet
and the `.animation(value:)` modifier sits out → then `onChange` flips the flag
off, with a short animation of nothing, because the opacity no longer changes.

SwiftUI stops a `repeatForever` animation in exactly one way: by replacing it
with another animation on the same value. Nothing replaced it. It kept driving
the presentation under every colour that followed — yellow for two hours, green
for an hour, then red for six.

**Correction.** Blinking is a different view. `Blinking` is a modifier put behind
an `if`: while `shouldBlink && !calm` the row shows a pulsing circle; the moment
that stops holding, the view is removed and a steady one takes its place. A
removed view takes its animations with it — that is the entire mechanism, and it
does not depend on how SwiftUI reconciles a running animation with an unanimated
change. The dictation button had the same shape and got the same fix.

**Verified in reverse.** With the new build running, a throwaway session in the
same folder was sent a synthetic `permission_prompt`: four window-id screenshots
0.35 s apart, all different — blinking. Then a `PostToolUse`: four more, all
byte-identical — steady, at the resting opacity. Before the fix the second set
would have differed like the first.

**Lesson.** Every test in this project runs on the reducer, and the reducer was
right. The defect lived in the one layer nothing tests, and it surfaced in a
state the model says cannot blink. *When a symptom is impossible by the model,
stop reading the model and look at the screen* — with an instrument that can
actually see it, which here meant a window id and two frames half a period apart.

**And on the previous fix.** The same words had come in two days earlier — *"it
keeps blinking after I answered"* — and were fixed in the reducer, where the log
showed a genuinely stuck `awaiting`. That was a real cause, and not the only one.
Two defects wore one symptom; fixing the first hid the second until the next
amber went through cleanly, and the survivor showed up in red.

---

## The click that only knocked

**Symptom.** Reported by use: *"if I'm working in another window and click a
traffic light, the first click does nothing — maybe it just focuses the panel —
and the second opens. But two quick clicks risk opening the session **after**
the green one: the first marks it read, it drops down the list, and the second
lands on whatever moved up. So I click twice, spaced out."*

**Cause.** AppKit's manners for a window that is not key: a mouse-down is spent
on making the window key, and is delivered to the view only if the view under
the pointer answers `acceptsFirstMouse`. The panel is `nonactivatingPanel`, so
it never activates the app — which is right — but it does become key on a
click, and resigns key every time the user goes back to the editor. So every
visit began with a click that only knocked.

The second half of the symptom is not a defect of the click at all. The first
click *worked*: it marked the green as seen, the row's urgency fell, the column
re-sorted under the pointer, and the second click landed on the row that had
moved into that place. Two mechanisms, one habit.

**Measure.** The panel now logs `became key` / `resigned key`. A synthetic click
posted with the panel non-key gave:

```
05:51:39  panel became key
          (nothing else)
```

The click made the panel key and reached no row. That was with the first
attempted fix already in place — `acceptsFirstMouse` overridden on the
`NSHostingView`. Nobody asked the hosting view: the rows sit inside SwiftUI's
own scroll view, and *that* is the view under the pointer.

**Correction.** In the window, not the view. `FloatingPanel.sendEvent` makes the
panel key *before* handing a mouse-down to `super`: by then it is a click in a
key window and is dispatched like any other. Same panel, same non-activation.
With that build, the same synthetic click gave:

```
05:54:23  panel became key
05:54:24  window chosen out of 10: “… — awevents — …”
```

And the double-click: `sendEvent` drops the second click of a double-click, both
halves, so the tap gesture never sees a mouse-up without its mouse-down. Nothing
in the panel is bound to a double-click, and the row under the pointer is
exactly the one you did not mean. A synthetic double-click (`clickState` 2 on
the second — AppKit reads `clickCount` from the event, it does not recompute it)
opened one window and logged `second click of a double-click dropped`.

**What the verification itself showed.** The first delivered click opened
**awevents**, not the row photographed fifty seconds earlier: in between, the
node had answered and three remote rows had joined, and a session had changed
state; the column re-sorted, and the click went to whatever was at that height.
The instrument reproduced the user's accident without meaning to. The panel's
row order is therefore now read from `/sessions` at the instant of the click,
and the target is refused unless it falls inside the panel's bounds — after one
click that landed 21 px below the panel because the window list had returned a
tooltip (249 × 61, also ours) instead of the panel.

**Lesson.** A user who has found a workaround has found a defect and is
describing it in the only vocabulary they have — a habit. *Click twice, slowly*
decoded into two facts: the first click is swallowed (fix: the window), and the
column moves under the pointer (fix: a double-click is one click). Fix the habit
instead and both stay.

**And on instruments.** Three of this entry's four measurements needed a
synthetic click, and a synthetic click needs to know where the row *is*, not
where it was. The order that decides where a row is lives in the app, and the
app already publishes it; ask it, don't photograph it.


**Afterwards.** The second mechanism did not survive the week. Once the first
click was delivered, the user looked at the column that had re-sorted under it
and asked for it not to: rows now keep the place they were given, and move only
by their handle (D23). The double-click guard stays — a double-click must never
do two things — but the row it protects against no longer moves.

---

## The drag that moved the panel

**Symptom.** The first drag on the new reorder handle moved the whole panel
ninety-six points down — exactly the distance dragged — and reordered nothing.
The preferences were untouched; the window's origin had changed.

**Cause.** The panel is `isMovableByWindowBackground`, which is how you put it
where you want it. Before any SwiftUI gesture gets a look at a mouse-down, the
window asks the view under the pointer `mouseDownCanMoveWindow`; for a SwiftUI
subtree the answer is yes, and the window takes the drag for itself. A
`DragGesture` with `minimumDistance: 2` never had a chance: the decision is made
at mouse-down, before any distance exists.

**Correction.** The grab area is an `NSView` (`DragHandle`) that answers **no**
to that question, handles `mouseDown` / `mouseDragged` / `mouseUp` itself and
reports the vertical travel to SwiftUI, which moves the rows. The three lines are
still SwiftUI, drawn on top with hit-testing off. Measured with synthetic mouse
events: the same drag now changes the order in the preferences and leaves the
window where it was, both upward and downward.

**Lesson.** In a SwiftUI view hosted by AppKit, the window still runs the first
round. Anything that competes with a window behaviour — moving by background,
resizing, the first click in a non-key window — is settled by AppKit's questions
to the hit view, and a SwiftUI gesture cannot answer them. When a gesture loses
to the window, the fix is a view that can speak AppKit, not a bigger gesture.

---

## The row that never spoke

**Symptom.** Reported by use: *"remote sessions never worked — always red, the
click goes nowhere, and the sessions look random: one of them I never opened."*

**Measure.** On the node, over ssh: `~/.claude/settings.json` had **no hooks**;
port 9877 there was free; the sessions the probe listed were real — a `claude` in
a detached tmux (`vacanza2026`, two days old, started by an automation) and the
one the user drives, whose window is **on this Mac**, titled `resume — folder
[SSH: 100.x.x.x]`. Every remote row had been born from the probe and had never
received a hook, because the hook on the node posts to `127.0.0.1:9877` *on the
node*, where nothing listens. Three facts the first design had not measured: the
node had no hooks, the user's remote window was a local window, and the
"sessions" were processes, not things anyone had opened.

**Cause.** D21 answered a security question — do not put `/signal` on the network
— and let the answer decide the feature: *read* the node instead of hearing it.
Reading gives presence and nothing else. A row with presence and no state is a red
dot; a row whose workspace is a folder on another machine has nothing here to
raise; and a probe that lists every live pid lists what nobody asked to see. The
design was internally consistent and useless, and it shipped because the check
was "does a row appear", not "does the row do anything".

**Correction.** D24. The node's hooks reach this Mac through a reverse ssh tunnel
the app keeps open — the far end bound to the node's loopback, so nothing on any
network can post — and lampboard installs those hooks on the node itself, over
ssh, with the same merge the local installer uses. A remote row is born when the
session speaks and confirmed alive by the probe, whose pid check now also
compares `procStart` with `/proc/<pid>/stat`. A click raises the Remote-SSH
window of the folder. Hosts moved from a hidden file to a Settings window and a
`remote` verb in the CLI.

**Verified.** From the node, `curl` to `127.0.0.1:9877/signal` with the host
header: `absent -> working host=minisforum`, `working -> ready`, and the row
carried the message; `lampboard remote check` reports python, curl, hooks and
whether the tunnel answers — asked *from* the node, the only place the question
means anything.

**And what the review found before it shipped.** The second design was put to an
adversarial review — three lenses, every serious finding attacked by a skeptic —
while the first lines were being written. Eight findings survived, none refuted.
Three were blockers: the probe ran its ssh handshakes **on the main actor**, so an
unreachable host (the common case, once tunnels exist) would have frozen the
panel for the connect timeout every twenty seconds; a remote row born from a hook
was erased by the next local pass whenever the host's last probe answer predated
it — the fake session used to verify the tunnel had in fact vanished between its
`Stop` and its `SessionEnd`, and the log line was read as "cleanup" instead of
"defect"; and `-R 127.0.0.1:9877` was a *request* sshd may override to the
wildcard address under `GatewayPorts yes`, telling the client only in a debug
message. The port was also every account's on the node, and a dead connection
left the server holding it against the reconnect. The review's answer — a Unix
socket in the user's home — was built, and **failed its first measurement**: the
socket appeared as `root:root 0600`, because the ssh server on the node is not
OpenSSH at all but **Tailscale SSH**, whose daemon forwards as root. One `ps` on
the node (`tailscaled be-child ssh --uid=1000 …`) settled what a page of
`sshd_config(5)` could not. What shipped keeps the port and checks each of the
three claims where it can be checked: the port is the user's (uid-derived), the
node reports the bound addresses after every connect, and a taken port is seen
before the ask.

**Lesson.** *A feature that answers its own security question first can end up
answering nothing else.* The right order was: what does the user need the row to
do (change colour, open on click), then which mechanism can do that, then whether
the mechanism is safe — and the tunnel was safe all along. And measure the
machine before designing for it: one `ls ~/.claude/ide/` on the node would have
shown the second design's presence rule was wrong, too, before it was written.
*And*: a "loopback" you did not verify from the other side is a claim, not a
fact — the same lesson this project had already paid for once with a socket that
looked local and was `*:9877`.

---

## The event I recommended from its name

**Symptom.** A recommendation, made confidently, in writing, to a person who was
about to act on it: *"`TaskCreated`/`TaskCompleted` are pure observation and I
would take them now — they turn the return to green from “next turn” into
“immediately”."*

It was wrong in every part.

**Cause.** Comparing this project against another one, the full hook event list
turned up in the Claude Code binary: thirty-one names, of which this app used
eight at the time. Two of them read like the answer to a limitation documented the day
before — that green only returns when the *following* turn ends clean. The names
were right there in the enum. The reasoning stopped there.

**What the probe showed**, twenty minutes later, from one real session that ran a
backgrounded `sleep 6`, polled it, and finished:

```
PreToolUse Bash | run_in_background = True | sleep 6
events: SessionStart, UserPromptSubmit, PreToolUse ×2, PostToolUse ×2, Stop, SessionEnd
```

Neither event fired. The emission site says why:

```js
hook_event_name:"TaskCreated", task_id, task_subject, task_description,
teammate_name, team_name
```

`teammate_name`, `team_name` — it is the **teammates task board**, a different
feature entirely. The names describe something real; it just isn't background
work.

**Correction.** Neither is implemented. The whole inventory is recorded in
`required-fields.json` with each event marked **measured** or **read**, and
`check-contract.sh` verifies the list against the binary so a new event has to be
classified rather than quietly ignored.

**Lesson.** *A name in an enum is not a measurement, and it is worse than no
evidence, because it feels like some.* This project already had the rule —
"inferring a state is inventing one" — and applied it to timestamps, to session
liveness, to task statuses. It did not apply it to a symbol read out of a binary,
because reading a binary already feels like the rigorous option.

**And the second lesson, about the shape of the mistake.** The recommendation was
made in the same breath as a *correct* piece of caution: the sibling event,
`PermissionRequest`, was flagged as risky and held back for a decision. So the
care was present. It was spent entirely on the consequences of the change and
none of it on whether the change did anything at all. **Diligence about risk is
not diligence about truth**, and having exercised one is a good way to feel
finished before exercising the other.

**A third lesson, smaller, from the probe itself.** The first attempt to force a
permission prompt passed `--permission-mode default`. The accepted values are
`acceptEdits, auto, bypassPermissions, manual, dontAsk, plan`. The flag was
rejected, the harness sent stderr to `/dev/null`, and the run looked like a clean
negative result. One more silent failure away from concluding the opposite of the
truth — see "A red test, hidden by my own grep".

---

## Twenty-one figures that had quietly stopped being true

**Symptom.** None. The code map states a line count for every file, a total for
every target, how many test cases there are and what the longest file is. Asked
whether the documentation was up to date, a script found **21 of 47** figures
stale, some by half: `PanelController.swift` was documented at 407 lines and was
557, `StateStore.swift` at 149 and was 227.

**Cause.** Every one of them was written by hand, and nothing in the repository
had any reason to look at them again.

**Correction.** [`Scripts/check-docs.sh`](../Scripts/check-docs.sh), run by
`Scripts/test.sh`: it verifies the per-target totals, the per-file sizes, the test
counts, the "no file exceeds N lines" sentence, that every relative link resolves,
and that no suite exists which the runner never calls. It does **not** rewrite
anything — a number that drifted usually means the prose around it drifted too,
and only a person can tell whether a file grew a responsibility or six lines.

**Lesson.** This one arrived by accusing somebody else first. The criticism aimed
at tmux — that `tty_default_features` is a hand-maintained table describing
something that moves, with no test that any of it is still true — was accurate, and
was equally true of this repository's own code map, written by the same hand that
made the criticism. *A standard you can state for someone else's project is a
standard your own is already being measured against.* Checking took twenty minutes.

---

## The script that said "✓ created" without having created

**Symptom.** The stable signature didn't work, and the build fell back to ad-hoc
**silently**. You find out days later, from a click that stops working.

**Cause.** The script printed the success right after the import. When the import
failed, the error scrolled past.

**Correction.** It signs a probe file and compares the `Authority` before
declaring success.

**Lesson.** It is the same shape as the alert-after-success, in bash.

---

# Wrong semantics

## Four events that stated falsehoods

| Event | Before | Now |
|---|---|---|
| `StopFailure` | `ready` (green) | `failed`. A turn cut short by a rate limit produced nothing to read. Exception: `max_output_tokens`, where the text exists and is merely incomplete |
| `Notification(idle_prompt)` | `ready` (green) | nothing. It is an inactivity timer, not an answer: it invented answers that never arrived |
| `SessionStart(source: compact)` | `idle` (red) | nothing. Compaction fires **mid-turn**: it cleared the yellow of a working session |
| `Notification(elicitation_dialog)` | ignored | `awaiting`. An MCP dialog blocks as much as a permission request |

**Lesson.** Every event has to be mapped by asking *what it proves*, not *what
the name suggests*.

---

## The immortal yellow

**Symptom.** Yellow rows that stayed that way forever.

**Cause.** Pruning exempted `working` — "a long turn is not a dead session". But
**`Stop` doesn't fire when you interrupt a turn with Esc**, and no other hook
covers it.

**Correction.** The threshold applies to every state. If it gets it wrong, the
damage is bounded: on the next signal the reducer recreates the row.

---

## The green that came back during the work

**Symptom.** A forty-five minute background workflow, and a green traffic light
for the whole duration.

**Cause.** The plan said "`Stop` resets the subagent counter". Implementing it
revealed that the real sequence is:

```
SubagentStart ×N → Stop → … work … → SubagentStop ×N
```

Resetting on `Stop` restores green **exactly during** the work.

**Correction.** The displayed state is **derived** from the counter. It follows on
its own that when the last agent finishes, the green set aside resurfaces.

**Lesson.** A plan written before the implementation can be wrong, and the
implementation is where you find out. The entry in
[04 decisions](04-decisions.md#d2--the-displayed-state-is-derived-not-stored) was
rewritten, not deleted.

---

## Green while a background shell was still working

**Symptom.** A session showed green — "there is an answer to read" — while it was
plainly still working. Reported by the person using it, not by a test.

**Cause.** Not subagents, which the column already handles. Background shells. A
turn can end with `run_in_background` work still going: the session writes a
recap, hands control back, `Stop` fires, and the shell carries on for minutes
before waking the session with a notification and another turn.

The field that says so, `background_tasks`, was found on the **first day** of the
project, probed, documented — and deliberately not used. The reasoning was
written down: *"the turn genuinely ended and an answer genuinely exists, so green
is correct."*

**Correction.** A `Stop` reporting any in-flight task leaves the row out of green —
first as `working`, later as its own state, `waiting` (D22). Green
returns on its own when the work finishes and the following turn ends clean, so
there is no counter to get stuck.

The first version of that correction filtered on `status == "running"`, and carried
the same defect one level down. See the next entry.

**Lesson.** The reasoning was coherent and wrong, because it answered the wrong
question. Green does not mean "a turn ended". It means "there is something to read
**and nothing more is coming**", and only the second half was checked. When a
signal has two claims in it, a correct-looking argument about one of them proves
nothing about the other.

**And the second lesson, which is about who finds these.** This one was invisible
to every test and every probe, because both were written by the person who had
already decided it was fine. It surfaced from somebody using the thing for a week
and saying *"it goes green while it's working"* — and their first guess at the
cause was subagents, which was wrong, and it did not matter. The observation was
right; the diagnosis was mine to get right.

---

## The fix that kept a piece of the bug

**Symptom.** None visible. The row went green while queued background work was
about to wake the session — the same lie as the entry above, in the narrow window
between a task being registered and starting to run.

**Cause.** The fix for green-during-background-work counted tasks with
`status == "running"`, and defended in a comment against finished ones: *"a finished
task is in the list too, and treating it as live would leave the row yellow for
ever."* Both halves were wrong, and they were wrong together. Reading Claude Code's
own filter settles it:

```js
if(e.status!=="running"&&e.status!=="pending")return!1;
if("isBackgrounded"in e&&e.isBackgrounded===!1)return!1;
```

A finished task **never** reaches the list. So the defense guarded a case that
cannot happen, and the cost of that guard was dropping `pending` — the one state
the defense was not thinking about at all.

**Correction.** Presence in the list is the signal, because that is what the field
is documented to mean: *"session is paused waiting for background work to wake
it"*. The status is still read, but as a deny-list of the three terminal words, so
an unfamiliar one counts as work.

**Lesson.** *An allow-list and a deny-list are not stylistic variants; they encode
which mistake you can afford.* Two files apart this project makes the opposite
choice and is right both times: a session id is refused unless recognized, because
an unknown character in a path is the dangerous one; a task status counts unless
recognized as finished, because an unknown state of work is far more likely to be a
new way of being busy. Picking the wrong one is silent in exactly one direction,
and here that direction was the expensive one.

**And the smaller lesson.** The comment defending the filter was confident,
specific, and had never been checked against the producer. The evidence took four
minutes with `strings`. A defense written from reasoning about a dependency, rather
than from looking at it, is a guess wearing a comment's clothes.

---

## The conversation that began in the middle

**Symptom.** None reported — found by comparison, not by use. The chat window keeps
the last 300 entries and silently drops the rest, so a long conversation opens
part-way through a sentence with nothing to say it had been cut.

**Cause.** `trimmed(to:)` returned the tail and threw the count away.

**Correction.** The count is kept, accumulated across polls, and the window says
"N earlier messages not shown".

**Lesson.** Borrowed whole from tmux, which has to solve the same problem when a
control client falls behind and refuses to solve it quietly: it sends `%pause` on
the wire, or disconnects the client with the message "too far behind". *A consumer
must be able to tell "there was nothing" from "there was something and you did not
get it."* Logging the drop is the weak version — it tells the author. Saying it in
the output is the strong one: it tells the reader.

---

## The downgrade that erased the error

**Symptom.** A `failed` session went back to "working", and the cause of the
error vanished.

**Cause.** The protection from late signals was hooked to `blocksDowngrade`,
false for `failed`. A late `PostToolUse` — the tail of the turn that had just
been cut short — downgraded it.

The reason `failed` wasn't in `blocksDowngrade` was a good one: if the turn
**resumes**, yellow is the correct information. But a trailing signal is not a
resumption.

**Correction.** `shouldKeep` tells the two cases apart. Two tests pin both down.

---

# Platform defects

## The crash the e2e suite couldn't see

**Symptom.** `swift run LampBoardApp` died at startup.

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'bundleProxyForCurrentProcess is nil'
8  LampBoardApp  AppDelegate.startNotifier(for:)
```

**Cause.** `UNUserNotificationCenter.current()` outside a `.app` bundle **does not
return nil**: it raises an exception and terminates the process. The guard was
there inside `SessionNotifier`, and missing on the line assigning the delegate.

**Why no test saw it.** The entire e2e suite runs `--headless`, and `--headless`
skips `startInterface()`. The test run never went through the branch with the
interface on.

**Correction.** The guard, plus an e2e case that starts the binary **without**
`--headless` and checks it is alive after two and a half seconds. Tested in
reverse: red with `code 6` (SIGABRT), green with the fix.

**Lesson.** A mode introduced to make something testable can create a branch no
test walks through.

---

## PKCS#12 that macOS can't read

**Symptom.**

```
SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
```

**Cause.** Two, overlapping. OpenSSL 3 encrypts by default with AES-256 and
computes the MAC with SHA-256, which the Security framework can't digest. And
with an empty password, "no password" and "a zero-length password" are two
different things in the MAC computation.

**Correction.** `-legacy` and a temporary random password. LibreSSL doesn't know
`-legacy` but already has the right defaults: the script tries and falls back.

**Lesson.** The error message pointed at the password. The problem was the
algorithm.

---

## `codesign` hanging

**Symptom.** The script never returned. No output, no error.

**Cause.** If the private key isn't in the "partition list", macOS opens an
*"allow access?"* dialog. In a non-interactive script that dialog reaches nobody.

**Correction.** `security set-key-partition-list -S apple-tool:,apple:,codesign:`,
plus a **deadline** on every signing. `-T /usr/bin/codesign` at import time isn't
enough in the `login` keychain, even though it is enough in one created on the
spot.

---

## `“$VAR”` breaking bash

**Symptom.**

```
line 141: NAME�: unbound variable
```

**Cause.** In UTF-8 `”` is `0xC2 0xBB`, and bash 5.3 under `C.UTF-8` **swallows
the `0xC2` byte into the variable name**, looking for one that doesn't exist.
With `set -u` the script dies.

**Correction.** Braces: `“${NAME}”`. All occurrences fixed with
`\$[A-Za-z_]\w*(?=[^\x00-\x7F])`.

**The detail that teaches the most.** In `build-app.sh` the faulty line was in the
"sign with a stable identity" branch, **never executed** until that day. The
defect had been there for hours and woke up at the exact moment the certificate
appeared.

---

## The window that read the whole file

**Symptom.** ⌘+click on a row — or `lampboard chat n` — showed the beachball
for ten to thirty seconds before the extended view opened. It had been
instantaneous; the defect had been there for two days, and nobody had changed
the chat code in those two days.

**Cause.** Two, stacked. `TranscriptReader.readAll` read the transcript **from
the beginning** into memory and handed it to `TranscriptTail.consume`, which
split it into lines with `String.split(separator: "\n")` — a *Character* split,
which walks the text grapheme by grapheme deciding at every step whether two
scalars form one character. All of it on the main actor. Nothing had changed in
the code: the transcripts had grown. The sessions in daily use had reached 61,
155 and 466 megabytes, and a window that shows the last three hundred entries
was parsing half a gigabyte to find them.

**Correction.** Three things. The window opens on the file's **tail** — the last
eight megabytes, from the first whole line (`TranscriptWindow`), with the title
read from the head as the terminal rows already did — and says so in a note at
the top when it skipped something. Lines are split on the **byte** `\n`, through
the UTF-8 view: the same lines, a fraction of the time. And the first read runs
**off the main actor**, with the one-second poll held back until it is done.
Measured: 0.5 s on the 61 MB transcript, 0.07 s on the 466 MB one.

**Lesson.** A cost that scales with the file finds you when the file grows, not
when the code changes — "nothing changed" is the wrong first question for a
regression, "what got bigger" is the right one. And a `Character` split is the
right default for text and the wrong one for a format whose separator is a byte
you can name.

---

## The permission that belonged to VS Code

**Symptom.** The first click on a terminal row resolved its seat correctly —
`Terminal /dev/ttys000` — and the log said *Automation permission for Terminal
missing*. No prompt had appeared, and none would.

**Cause.** The panel had been relaunched from the shell of this very session:
`nohup dist/LampBoard.app/Contents/MacOS/lampboard &`. macOS attributes
Automation to the **responsible process**, and for a binary started from a
terminal that is the terminal's owner — here VS Code. Earlier in the day an
`osascript` from the same shell had been denied Terminal, and that denial was
recorded for VS Code → Terminal. The panel inherited it.

**Correction.** Launch through LaunchServices — `open dist/LampBoard.app`, with
`--env` for the debug variable — so the bundle is responsible for itself. The
prompt then appeared, and the tab came to the front.

**Lesson.** 03-macos already said that every permission check run from a
terminal lies. It lies in both directions: a denial recorded for the terminal's
owner is a denial for everything that owner launches, including the app whose
permission you think you are testing.

---

## The session that left no file

**Symptom.** A `claude` started inside kitty and WezTerm for the live checks
ran, its `SessionStart` hook reached the panel — and the log said *no live
session file names the session*. No row.

**Cause.** The terminals had been launched from a shell that a Claude Code
session had opened, and inherited its environment: `CLAUDECODE`,
`CLAUDE_CODE_CHILD_SESSION`, the messaging socket. A nested `claude` treats
itself as a child session and writes no `~/.claude/sessions/<pid>.json`. D25
requires that file — deliberately, it is what keeps forged and foreign signals
out — so the rule did exactly what it says, to a session that looked ordinary
from the outside.

**Correction.** None in the code: `env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION
… claude` for the checks, and the drop line now says which condition failed
(*no live session file names the session* against *terminal sessions are off*),
which is what turned twenty minutes of guessing into one line.

**Lesson.** A guard that refuses silently is a guard you will one day argue
with. Every refusal in `StateStore.handle` names its reason in the log; the
reason was read, and the "bug" was the environment.

---

## `grep -q` under `pipefail`

**Symptom.** "✗ The signature doesn't appear to be issued by…" on a perfectly
valid signature. **Intermittently.**

**Cause.** `grep -q` exits at the first match and closes the pipe. `codesign`
still has five lines to write, receives SIGPIPE, exits with **141**, and
`pipefail` fails the pipeline *even though the match was there*.

It is a race: it depends on who gets there first. The first isolated attempt
returned `0` and made me discard the correct hypothesis; only reproducing the
exact sequence surfaced `exit 141`.

**Correction.** Write to a file and grep the file. Verified with **ten
consecutive runs**.

**Lesson.** A defect that works one time in two isn't disproved by a single
attempt.

---

## The shortcut that registers and never arrives

**Symptom.** Pressing the combination gets an answer from the foreground
application — recent tabs in one browser, the search bar in VS Code — and the
panel doesn't react.

**Cause.** `RegisterEventHotKey` returns `noErr` and the event is never
delivered. Verified with two independent binaries using the same standard recipe,
with the panel alive and the registration confirmed in the log: zero events
received.

**How much it cost to find out.** Three wasted rounds, for two reasons:

1. The first few times **the shortcut was simply switched off** — nobody had
   turned it on, and what the user pressed went to the foreground application.
   The code wasn't even in play.
2. The log recorded the action but not the **keypress**, so "it never arrived"
   and "it arrived and found nothing" were indistinguishable.

**Correction.** The feature was removed. See
[04 decisions · N6](04-decisions.md#n6--a-global-shortcut-inside-the-app).

**The lessons, which apply beyond this case.**

*Log the cause, not just the effect.* A log that says what happened afterwards
doesn't help you work out whether something happened before.

*Before diagnosing, check the feature is switched on.* It sounds obvious; it cost
two rounds.

*A test that needs two synchronized people isn't a test.* Two probes came back
empty because whoever was watching and whoever was pressing weren't coordinated.
The third version became a command the user runs themselves — whoever presses is
also watching, and the silence stops being ambiguous.

*Key codes are positions, not characters.* Code 50 is "the key to the left of
the 1": on a US keyboard it prints a backtick, on an Italian one a backslash.
Telling somebody to "press the backtick" when they don't have that symbol is a
sure way to make something that works look broken.

---

## `String(format:)` ignoring the width

**Symptom.** Columns jammed together in `lampboard sessions`.

**Cause.** `String(format:)` honors a width on C's numeric and textual
placeholders, but **ignores** it on `%@`.

**Correction.** `String.padded(to:)`.

---

## Two installations in the same second

**Symptom.** The second installation failed with a message about the backup while
the problem looked like something else.

**Cause.** The backup name carries the date down to the second, and `copyItem`
refuses to overwrite. You meet it by installing, uninstalling and reinstalling in
three clicks.

**Correction.** A counter. **Found by an e2e test**, not by hand.

---

## Two tabs instead of one

**Symptom.** "New conversation here" opened two tabs.

**Cause.** The path raised the window passing the `sessionId` — so it opened the
existing tab — and immediately afterwards opened a new one.

**Correction.** A parameter to skip opening the tab, used only from there.

**Lesson.** **No test could have seen it**: the deep link runs as a separate
process and nobody observes its effect. Against that category the only tool is
re-reading the path in full.

---

## The unreadable timestamp

**Symptom.** The timestamp in the row couldn't be read.

**Cause.** `.tertiary` over an `NSVisualEffectView` gets attenuated a second time
by vibrancy.

**Correction.** `Color.primary.opacity(0.62)`, with the hierarchy achieved
through font **weight** instead of fading the color.

---

# Environment traps

## The locked screen

Screenshots and accessibility **both lie** with the screen locked: the first
capture the lock screen, the second returns zero windows even with the
permissions granted.

It cost ten rounds of diagnosis on an "invisible" panel that was visible, and was
then nearly mistaken for a recognition regression.

**Always check before concluding:**

```swift
(CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"]
```

Hence the dedicated `noWindowsVisible` error, distinct from `windowNotFound`.

## The stale build

A new bundle does not replace the running process. An app started an hour earlier
is **indistinguishable** from a revoked permission.

Before diagnosing a click that doesn't work: `ps -o etime`.

## The ad-hoc signature

It changes on every build, macOS considers the app a different one, the
authorizations lapse **while still showing the switch as on**.

## The permission that was granted and wasn't

**Symptom.** A fresh install from the notarized disk image. macOS asks for
nothing. Clicking a row activates the editor but never raises the right window.
System Settings › Privacy & Security › Accessibility lists **lampboard with
the switch on**.

**Cause.** These authorizations are keyed on the code signature, not on the
name. The same bundle identifier signed differently — ad-hoc, a local
certificate, a Developer ID — is a different subject to macOS, and each leaves
its own record. The list collapses them into one row bearing one name, and shows
one of them. `tccutil reset` on the real machine reported success four times for
`com.lampboard.app`: four separate records, one visible.

So the pane said yes while `AXIsProcessTrusted()` said no, and the app was
right. The advice the README used to give — remove the row with "−" and add it
back — removes the visible record and leaves the others, which is why it can
appear to change nothing.

**The cure**, now carried by the error text itself so it does not have to be
remembered:

```bash
tccutil reset Accessibility com.lampboard.app
tccutil reset AppleEvents com.lampboard.app
```

**And the cure has its own trap.** `tccutil reset` does not revoke anything from
a process that is **already running**: macOS keeps its accessibility session
open until it exits. Measured while testing this very fix — the record was
reset, a row was clicked, and the click worked perfectly, which reads as "the
reset did nothing". It had done exactly what it says; the running app was simply
still holding what it had been granted. The command has to be followed by

```bash
pkill -x lampboard && open -a LampBoard
```

or the next check will be about a state nobody is in any more. It is the same
family of mistake as the switch that says yes while the app says no: the system
answering about something other than the process in front of you.

**What it cost, beyond the diagnosis.** Nothing prompted, because the click
checks the permission and takes the fallback rather than asking; and the reason
lived at the bottom of a context menu. An app that degrades silently into a
place nobody looks is indistinguishable from an app that is broken — and the
first person it defeated was the person who wrote it.

**What changed.** The fault now appears as a line under the rows with a button,
the button explains the permission before opening the pane, and when the
permission arrives the app finishes the click that was interrupted instead of
waiting to be clicked again.

## The self-test that invented a failure

**Symptom.** `lampboard selftest`, run while the panel was up, reported *"the
signal never reached the handler"* on a chain that was working perfectly.

**Cause.** `SignalServer.start()` returns before its listener is ready. With the
port already taken, it returned successfully, the test printed `✓ server
listening`, and the failure arrived afterwards through the error callback as
`Address already in use`. The probe POST then reached **the running panel**,
which answered 204 — so the transport looked fine — while the test's own handler,
attached to a listener that had never started, was never called.

**Why it matters more than it looks.** A diagnosis is run by somebody who
already suspects a fault. A failure it invents is not a cosmetic bug: it sends
them looking for a problem that does not exist, at the exact moment they are
least able to tell the difference.

**Correction.** Ask before binding. If something already answers on `/health`,
say who holds the port, confirm that it accepts signals, and state plainly that
the loop test was **not run** — never let silence read as a pass. Covered by two
end-to-end cases, which run with the panel up and would fail on the old text.

## The guard that had never looked

**Symptom.** None. `check-docs.sh` printed *"✓ no real home directory or private
VPN address in the tree"* on every run, for weeks, while
`Contracts/golden/hooks.jsonl` carried a real user name in thirteen places in a
**public** repository.

**Cause.** The check was one shell pipeline:

```bash
LEAKS=$(git ls-files -z | xargs -0 grep -nIE '(/Users/(?!dev|you|sam|me)…)' 2>/dev/null | … || true)
```

`/usr/bin/grep -E` has no lookahead. It answers `repetition-operator operand
invalid` and exits 2 — every single time. `2>/dev/null` threw the message away,
`|| true` threw the status away, and an empty `$LEAKS` was read as "nothing
found". The guard had never examined a file in its life.

Two independent decisions, each defensible on its own, combined into a lie: the
redirect was there because `xargs` is noisy about binary files, and the `|| true`
was there because `grep` exits 1 when it finds nothing — which is a *success* for
this check. Together they made an error indistinguishable from a clean tree.

**Why it is the worst kind.** Every other defect in this catalogue announced
itself: something did not work, something looked wrong, somebody noticed. This
one printed a green tick, which is exactly what it printed when it worked. There
is no observation that separates the two — only an experiment: commit the
violation and see what happens.

**Correction.** The matching moved into Python, where an error is an error, and
the guard now **proves itself before it is believed**: the patterns are run
against strings known to match and known not to, and a pattern that fails its own
example fails the check with `THE GUARD ITSELF IS BROKEN`. `Scripts/bite.sh`
plants a home directory, plants a VPN address, and blinds the pattern, demanding
a red for each. The golden file was scrubbed, and `check-contract.sh --record`
now scrubs the home directory on the way in rather than trusting somebody to
notice on the way out.

**Lesson.** A check that cannot fail and a check that cannot run print the same
character. Ask every guard, once, to catch something.

## The instrument that had stopped measuring

**Symptom.** None, again: `503 tests passed.`

**Cause.** Everything this project believes about itself passes through fifty
lines in `Sources/TestKit/Assertions.swift`, and nothing checked them. Adding one
line to `expect` —

```swift
if true { return }
```

— made the entire domain suite report success while verifying nothing at all. Not
a subtle degradation: a full green, no warning, no clue. The same attack had been
demonstrated on a sister project, where three hundred and thirty-six tests passed
against a neutralised assertion library.

**Why it matters even without an attacker.** Nobody has to be malicious for this
to happen. A bad merge in the assertion file, a refactor that moves the wrong
`guard`, a "let me silence this for a second" that survives the afternoon — the
result is identical, and the test suite's job is precisely to tell you when
something has quietly stopped working.

**Correction.** `TestKit/Instrument.swift` calibrates the assertions before
either suite runs: every assertion is made to fail and must record it, made to
pass and must stay silent, and a failing run must still reach a non-zero exit
code. Nineteen proofs, none of them written in the vocabulary being tested — the
verdicts are plain Swift comparisons. A blunt instrument ends the process with
**70**, not the 1 of an ordinary failure, because the two mean different things
and nobody should have to guess which they are looking at. `bite.sh` attacks it
from outside as well, neutralising `expect`, then the collector, then the exit
code.

**Lesson.** A measurement is worth exactly what the measuring device is worth,
and a device that has never been calibrated is not a device, it is a decoration.


---

# Three readings that agreed, and a formula that was not there

**Symptom.** None. That is the whole entry: a number that was about to be
written into the panel, that agreed with every observation available, and that
was wrong.

**What was being decided.** The panel had to say how full a session's context is.
The numerator was settled and verified — `input + cache_creation + cache_read`,
the same sum Claude Code's own status line reports. The denominator looked
obvious: the model's context window. Then a screenshot showed that Claude Code
displays *"% until auto-compact"*, not *"% of window"* — it compacts before the
window is full — so dividing by the whole window would promise room that is not
there.

**The measurement that looked like proof.** Three sessions were read by hand and
compared against Claude Code's own indicator:

| session | model | our reading | with the full window | with 0.92 × window | shown |
|---|---|---|---|---|---|
| this one | opus-5 | 697,813 | 30% | **24%** | 24% |
| a second | opus-4-8 | 627,330 | 37% | **32%** | 32% |
| a third | opus-5 | 847,105 | 85% used | **92% used** | 92% |

Three points, two models, fillings from 68% to 92%, and a threshold — 0.92 —
that fitted all three to within a point. Written down, it reads like a
measurement. It reached the prototype and was one commit from the code.

**What it actually was.** Two mistakes standing on each other.

The first: the fit was to *three* points, all of them on 1M models, and each of
those readings is a **floor** — this project's own finding, in this same file.
Every gap pointed the same way, which is exactly what a floor does. The
"agreement" was our number being 30–40k stale in all three cases.

The second is worse, and it is the one worth remembering. The threshold *does*
exist — `window − min(maxOutputTokens, 20 000) − 13 000`, plainly readable in the
binary — but it is compared against **Claude Code's own token estimate**, which
is not the sum we read. On one compaction the two were 0.4% apart (966,032
against 973,029); on another, sixty-fold. Borrowing that threshold means dividing
our numerator by somebody else's denominator, and nothing on screen would ever
have said so. And a fixed subtraction is not a ratio: 0.92 fits a 1M window and
means 0.835 on a 200k one, which no measurement here would have caught, because
all three readings were on 1M models.

**How it was caught.** By asking the transcripts a question that has one right
answer: *at what value of our own number does a session actually get compacted?*
Every `compact_boundary` carrying `trigger: "auto"` is a session that hit the
ceiling, and the last reply before it is our reading at that moment. 18,622
files, 236 compactions:

| window | n | highest reading | past 90% | above 100% |
|---|---|---|---|---|
| 1,000,000 | 20 | 99.91% | 10 | 0 |
| 200,000 | 216 | 99.99% | 79 | 0 |

The window is the ceiling. Under a `0.92` denominator, ten of those compactions
would have printed above 100% — the shape of the refutation was sitting in the
data the whole time, and it took a script and a minute to ask for it.

**Correction.** `Scripts/measure-compaction.py` runs the measurement;
`check-contract.sh` fails on any reading that exceeds its own window, and was
watched failing — the contract's opus-5 window set to 920,000 answers `108.6%`
twice and exits 1. `Contracts/assumptions.md` records the ceiling, and states the
one thing this cannot prove: our reading is a floor, so it can show the
denominator is not too small and never that it is not slightly too large.

**Lesson.** A number fitted to a handful of observations of *somebody else's*
display is a hypothesis wearing a measurement's clothes. Before it goes in, find
the event the number claims to predict — here, the compaction itself — and count
how often it happened where the number says it should.


---

# The tooltips that were written and never shown

**Symptom.** "Passando sopra le righe o sui semafori non compare nessun tooltip."
Reported by use, which is the only way this could have been found.

**What was wrong.** `.help(…)` was on the row, on the gear, on the filter note, on
the hidden-projects row and on the issue strip. It compiles, it reads correctly,
and in this window it does nothing. AppKit puts a tooltip on screen through
`NSToolTipManager`, which wants the window under the pointer to be **key** and the
application to be **active**. The panel is a `nonactivatingPanel` that becomes key
only in the instant of a click, and the app is an accessory that never activates —
both deliberate, both the reason clicking a light does not steal the focus from
the editor.

So the row's entire second layer had never been seen by anybody: the exact
context figure and the tokens behind it, the model with its version, the folder
underneath a renamed row, the slot and the command that opens it, which of the
sessions in a group are in which state, and the sentence explaining a failed turn.
All of it written, some of it under test, none of it displayed.

**Why no test caught it.** Every one of them checks a *string* — that the tooltip
says the right thing, which it did. There is no test in this project, and no
cheap one to write, that asks whether a tooltip appeared on a screen. The same
gap as D-19's blink: a correct model proves nothing about the screen.

**Correction.** `Tooltip.swift`: one borderless window that ignores the mouse,
never becomes key, appears after 450 ms under the pointer and removes itself on
any mouse-down — including the right-click that opens the row's menu, which
`.contextMenu` gives no notice of. `.help` stays only in the ordinary windows —
Settings, the conversations — where it works because those windows do become key.

**Lesson.** An API that compiles is not an API that runs *here*. A widget whose
whole design is "never take the focus" cannot borrow the parts of the toolkit
that assume focus, and the borrowing fails silently — the call is there, the text
is right, and the pixels never arrive.


---

# A red that was not ours

**Symptom.** `Scripts/test.sh` exited **139** — signal 11, a segmentation fault —
on a commit that had changed two markdown files and no Swift at all.

**What it was not.** The domain suite. Run directly, three times in a row, it
answered `547 tests passed` every time.

**What it was.** The crash report settles it in one line, and the useful habit is
to read that line first:

```
processo : swift-package
eccezione: EXC_BAD_ACCESS SIGSEGV
   llbuild · llb_buildsystem_command_get_description
   libdispatch.dylib · _dispatch_call_block_and_release
```

`swift-package`, not `LampBoardTests`. The crash is inside **llbuild**, SwiftPM's
build engine, on a dispatch queue, with four other builds running on the machine
at the time.

**Correction, and it removes the class rather than the instance.** The script
already built everything two lines earlier, and the end-to-end suite already ran
its binary directly. Only the domain suite went back through `swift run`, which
re-enters the whole package manager to exec a file that is already on disk. Both
now run the built binary. One less moving part between a green and the truth.

**Lesson.** A test runner that can fail for reasons that are not about the code
teaches people to re-run until it passes, which is the habit that eventually
hides a real failure. When a suite dies with a signal, `~/Library/Logs/
DiagnosticReports` names the process that died: read that before reading your
own code.

## The process that lives one turn

**Symptom.** A Claude Desktop conversation appears in the column, goes yellow
while the model works, and then **vanishes** instead of going green.

**Cause.** The rule everywhere else here is that a live process proves a live
session: a file names a pid, `kill(pid, 0)` answers, a start-time comparison
catches a reused number. Claude Desktop writes exactly that file — it is a Claude
Code session — and its agent process lives exactly **one turn**. The application
starts it to answer and removes the file when it exits. Measured: a conversation
whose last word landed at 22:44:38 left an empty `.claude/sessions` directory
stamped 22:44.

So the row disappeared at the precise moment there was something to read, which
is the moment the panel exists for.

**The lesson.** "A live process proves a live session" is a property of a
*surface*, not a law. Before carrying a liveness rule to a new surface, watch it
across a whole turn — start to finish — rather than during one.

## The fixture with a date in it

**Symptom.** Four end-to-end cases go red at eleven at night, on code that has not
changed. Green again in the morning, if the fixture's date is moved.

**Cause.** Every Codex fixture wrote `"timestamp":"2026-08-30T09:00:00.000Z"`,
and `AppConfig.sessionStaleAfter` is twelve hours. Once the clock passed 21:00Z
the row was adopted and pruned as stale **inside the same sweep** — the log even
said `codex adopted:` three times in fifteen seconds while `/sessions` stayed
empty.

**The lesson.** A test whose result depends on when it is run is not measuring the
code. Fixtures that are compared against `now` are written relative to `now`.

**Bonus.** Diagnosing it needed the app's own log, and a fake home is deleted when
the E2E run stops. Reproducing it by hand — a fake home, a fake `codex` holding a
rollout, the real binary with `LAMPBOARD_HOME` and `LAMPBOARD_DEBUG` — took two
minutes and answered it immediately.

## The key that went through a normaliser

**Symptom.** A remote row is renamed. The name does not appear, and no error does
either.

**Cause.** The new key for a workspace on another machine was `//host` and the
path. `RowNames` puts every key through `PathNormalizer.normalize` on the way in,
which collapses every run of slashes: the key stored was `/host/path` and the key
looked up was `//host/path`. Neither side was wrong on its own.

**The lesson.** A key is not a string you choose; it is a string that survives
every function it passes through. When you invent one, follow it into the table
and out again. The colon form — `host:/path` — cannot collide with a path, because
a path begins with a slash.

## The build that was verified and never installed

**Symptom.** A defect is found, fixed, tested end to end, watched on the running
app for two minutes, and reported as done. The next morning: "nothing has
changed."

**Cause.** There are two copies of this app on any machine that has ever
installed one — `dist/LampBoard.app`, which `build-app.sh` writes, and
`/Applications/LampBoard.app`, which is what starts at login. The night's work
was built, launched and verified in `dist/`. At 06:12 the login item started the
copy in `/Applications`, dated the previous evening, and that is the process that
took the port and answered every question afterwards.

Underneath it, a second one: the build script looked for a signing certificate by
a name written into the script, and the project had been renamed since. Every
build after the rename fell back to an **ad-hoc** signature — announced in one
line nobody was reading — so installing it would have wiped the Accessibility and
Automation grants, which are attached to the identity.

**The lesson.** Verifying a build is not the same as installing it. The script
now compares the two copies and says, every time, when the installed one is
older; and it asks the keychain for the identity instead of remembering a name.

## The sampler that blinked slower than the thing it watched

**Symptom.** The panel flickers, visibly, several times a minute. Polling
`/sessions` five times a second for fourteen seconds: perfectly constant. The
window geometry, sampled once a second: perfectly constant.

**Cause.** The rows disappeared for about **eighty milliseconds** at the end of
every sweep. Both samplers were slower than that, so both reported a panel that
never changed, twice, convincingly.

What actually happened only showed up in a log line that named the action:
`lost 6 to prune`. The twelve-hour age rule ran at the end of the sweep with the
set of confirmed sessions, and the Codex probe's answer — which is what confirms
those rows — now arrives from another actor a moment later.

**The lesson.** When something visible disagrees with a measurement, the
measurement is the suspect. Sample faster than the thing you are watching, or
better, make the code say what it did: a first-person log line found this in one
cycle after two rounds of sampling had found nothing. The first version of the
end-to-end case for it slept 200 milliseconds between looks and passed against
the unfixed code.

## The dialog nobody was looking at

**Symptom.** Installed from the tap, the panel never appeared. `lampboard
status`, `lampboard open`, every command: no output, no error, no timeout —
each one sat there until it was killed. The process was running; `pgrep` found
it. The port answered nothing.

**Cause.** Homebrew quarantines every download, and since Homebrew 6
`--no-quarantine` is gone, so the first launch raises the system's *downloaded
from the Internet* dialog. The cask's `postflight` launches the app the moment
the install finishes — which is the moment the person is reading the terminal,
not watching the screen. The dialog waited behind other windows. The app never
finished launching, the server never bound its port, and the CLI, which talks to
that port, waited for a server that was never going to arrive.

Nothing anywhere said so. Not the panel, not the CLI, not the install log.

**What it cost.** Half an hour, three wrong diagnoses, and two measurements of
the wrong object:

- `pgrep -x LampBoard` said the app was not running. The executable is
  `lampboard`, lowercase — `-x` matches exactly, so it never matched anything.
  Every check built on it read as "not running", including the one that
  concluded the postflight had failed.
- `spctl` was pointed at `/Applications/LampBoard.app` to decide whether a
  release was notarized. That is the installed copy, which carries the local
  signature: `release.sh` deliberately never signs the bundle in use, because
  macOS grants Accessibility and Automation to an identity and re-signing in
  place would revoke them in silence. The candidate is `dist/*.dmg`, and it was
  notarized the whole time. A release audit had been told the opposite.

**The lesson.** Both mistakes have the same shape as the ones this file already
catalogues: a measurement that returns cleanly while looking at something other
than the thing being judged. `pgrep -x` on a name nobody verified, `spctl` on a
path that was never the artefact. Neither failed. Both answered.

**What holds now.** The cask's caveats and the README say that macOS asks once
and that nothing works until it is answered. The trap itself cannot be closed
from here: it is how macOS treats a downloaded application, and the alternative
— an app that launches silently on install — is worse.

## The amber nobody was waiting for

**Symptom.** A Codex row blinks amber — the one state that means "this turn is
stopped until you answer" — while nothing is waiting for anybody. Reported from
use: three of them in a single audit message.

**Cause.** Codex publishes `PermissionRequest` for a tool call that needs
approving, and the event does not say **who** approves it. Routed to
`approvals_reviewer: auto_review`, the answer arrives by itself in a few hundred
milliseconds. But amber lifts at `PostToolUse`, which arrives when the command
**ends**, so the row keeps blinking for the whole execution: measured at 6.0 s,
6.4 s and 31.0 s on the three that were reported, and reproduced afterwards at
5.9 s and 3.4 s.

The code carried a comment saying such a request is amber "for a few hundred
milliseconds", and a four-second delay dimensioned on it. Both were true only of
an instantaneous command. Three of the five measured cases passed the threshold,
so they also fired the notification the threshold exists to suppress.

**What made it hard to find, and it was not the code.** Reproducing it took six
attempts, and five of them measured something that could not possibly ask for
permission:

- `git rev-parse` and `spctl` and `codesign -dv` are **reads**, and the sandbox
  grants `root: read`. No read has ever needed approval;
- `/tmp` is in the writable set;
- the user's home is a **trusted project** in `config.toml`, so writing there
  needs no approval either;
- the network is denied outright rather than escalated, so `curl` fails without
  ever asking;
- and the sessions opened to get `PreToolUse` registered had
  `approval_policy: never`, which forbids escalation altogether — while the
  session that *had* produced the ambers was started before that hook existed
  and never reloaded it.

Every one of those facts was in a file already read before the first attempt. The
sandbox policy, the trusted projects and the approval policy were all sitting in
`config.toml` and in the rollout's own `turn_context`. The failure was not
missing data; it was measuring before finishing the reading.

`codex exec --approve-for-me` puts the two conditions in one session — a fresh
one, which loads the current hooks, and an automatic reviewer, which produces
requests nobody answers — and the sequence came out on the first run.

**The measurement that changed the design.** `PreToolUse` had been registered on
purpose, on the assumption that it would arrive between the request and the
execution and could close the amber exactly. It arrives **88 ms before the
request**. Had it been implemented on the assumption, the amber would have been
closed by an event that fires before it opens — a fix that tests would have
passed and use would have exposed.

**What holds now.** The reviewer is read from the rollout the event names, per
request because it changes mid-session (D38). Not knowing shows the request.
`check-contract.sh` fails if a `turn_context` stops carrying the field, so a
format change turns a check red rather than turning a feature off.

---

## The two sources that agreed about a model neither was asked about

**Symptom.** Reported from use on 2026-09-02, in these words: *the residual
context is gone in many of the projects*. The ring beside the lamp still drew,
still carried its letter, and had no arc — on five of the six rows on screen.

**Cause.** The transcripts were writing `claude-fable-5-1`. `ContextWindows`
knew `claude-fable-5`. A point release had shipped and the table said nothing
about it, so `window(for:)` answered `nil`, and `nil` means no denominator, no
percentage, and no arc.

**Why the gate that exists did not see it.** `check-contract.sh` holds the table
against the model registry inside the Claude Code binary, and it was green:
*16 models in the binary, 16 recorded*. All three installed versions — 2.1.246,
2.1.247, 2.1.251 — carry `claude-fable-5` and none of them carries
`claude-fable-5-1`. The two sources agreed with each other perfectly about a
model neither of them was being asked about, which is the shape of the failure
worth remembering: **a check between two sources cannot see a third**.

The model reaches a transcript because the API served it, not because the local
CLI registry lists it. So the registry is the wrong ground truth for the
question *will a ring draw*. The transcript is.

**Why it read as the wrong thing.** An empty ring with a letter in it looks like
*nothing has been measured yet*, which is a state the panel really has. It does
not look like *this model is unknown*. The dashed circle exists to say the
first, and it was not drawn, so the row said the one thing that was false.

**Fixed twice, because one of the two would have happened again.** A trailing
minor group now falls back to its parent: `claude-fable-5-1` asks
`claude-fable-5` and inherits its million. Inheritance stops at a parent the
table does not have, so nothing is invented. And a third check reads the model
ids out of real transcripts, reports any that resolve to no window, and names
every one that resolved only by inheriting — because the day a point release
moves its own window, that line is the only warning there will be.

**The cost of the silence, measured.** Five sessions, between 45% and 97% of a
million tokens, none of them showing a figure. One was four percent from the end
of its window.

---

## The button that worked, and looked like it had not

**Symptom.** Reported from use the morning after the menu bar was added: *the
button that brings it back to a floating window, when it is in the bar, does not
work*. Pressed, and nothing appears to happen.

**Cause, and it is not the button.** It fired every time. `toggleHome` ran, the
home changed, the preference was written, the panel was ordered front. What it
did not do was **move**: it came back exactly where the drop-down had been,
hanging under the lamp, the same width with the same rows. The only difference
was that it no longer went away when you looked elsewhere, which is not
something anybody sees in the second after pressing a button.

The reading was right and the wording was generous. A control that says it will
bring the panel back to its own window has not done its job while the panel is
still standing where the menu left it.

**Fix.** Returning to the floating home now places the panel at the corner
`observePanelMoves` remembers — which only ever records a position somebody
chose, because it refuses to save a drop-down's. With no remembered corner, a
fresh install that went to the menu bar first, it hangs from the top right where
a new panel goes.

**What made it expensive to find, and it was the instrument.** Six attempts, and
five of them measured nothing at all. `System Events`' `click at` is an
**accessibility action**, not a mouse event: it asks the element under the point
to act on itself. A borderless panel whose content is a SwiftUI hosting view
exposes no such element, so every one of those clicks landed nowhere — no event
to the panel, and no other application activated either. The signature was a
panel that stayed key and a log with nothing in it, which reads exactly like a
dead button and is instead a dead instrument.

Two false leads came out of that. Clicks were tried at coordinates derived from
screenshots, and the screenshots themselves closed the drop-down, because
`do shell script` takes the focus and a drop-down closes when it loses key. And
`strings` was used to check whether an instrumented log line had reached the
binary: it had, and `strings` cannot see it, because Swift stores a literal of
fifteen bytes or fewer inline rather than in the string section. `panel home=`
is eleven bytes and is not in the binary either, while it is plainly in the log.

What finally measured it was a real `CGEvent` posted at the point. That is the
tool to reach for the next time something inside this panel has to be clicked
from a script, and the reason is worth keeping: **the panel is invisible to
accessibility on purpose**, so anything that drives it through accessibility is
measuring something else.


## The status item the system agreed to and never drew

**Symptom.** Reported from use, the evening of a release: *it doesn't start any
more*. Started from Spotlight, from the Finder, twice, three times — nothing.

**What was true.** The application was running the whole time. Its process was
alive, its server answered `GET /health`, its window existed in the window list
with the right size. The panel was living in its menu bar home, which is a home
whose only door is the lamp — and there was no lamp in the menu bar.

**Cause.** `NSStatusItem` has no way of failing. The bar was full, and asking for
an item on a full bar succeeds: an item comes back, `isVisible` answers `true`,
its button has a window, that window has a frame, and macOS draws nothing at all.

Measured, because a claim like that has to be. Twenty-six items created in one
process on a 14-inch MacBook with a busy bar: twenty-six reported visible, zero
on screen, and the frames handed out marching leftward from the notch — 809, 755,
711, … down to **−345**, off the side of the display. A photograph of the menu
bar taken while that process was alive shows none of them.

The lamp of the machine this happened on had landed at x=809. The screen's own
answer for where status items live — `NSScreen.auxiliaryTopRightArea`, the strip
to the right of the notch — began at 848. Thirty-nine points between a feature
and an application nobody can open.

**Why it looked like a launch failure and not a missing icon.** An accessory
application has no Dock icon and no window macOS will raise for you, so starting
it a second time did *nothing at all*: the reopen event arrived and nobody
answered it. Everything a person can do had been done, and every one of those
gestures was a no-op.

**Fix, in two halves, because one of them is a guess and the other is not.**

The half that cannot be wrong: starting the app again now summons the panel
(`applicationShouldHandleReopen` → `PanelController.summon()`). It needs no lamp,
no pointer aimed at twenty-two points of menu bar, and nothing learned in
advance. It is also the gesture that had already been made.

The half that is a judgement: a panel in the menu bar asks the lamp where it
landed, and a lamp outside the strip brings the panel back to its own window with
an alert saying why (`MenuBarPlacement`). The judgement is in the third answer.
The frame is not laid out at once — `(0, 0, 28, 0)` on the turn the item is
created and on the next one, settled about three tenths of a second later — so
*not yet* is retried rather than believed. Five tries, two seconds, and then the
panel comes home anyway: rescuing one that did not need it costs an alert, and
leaving one nobody can open costs the application.

On a screen with no notch there is no strip to compare against and the rule says
so instead of guessing. That home keeps its lamp; the door that needs no pixels
is the one above.

**What it cost to find, and what it did not.** Nothing, in the end, because the
window list answers questions the eye cannot: a process with a window at level
101 and no lamp beside the clock is the whole diagnosis in one line. What made it
worth writing down is that every honest-looking signal said the feature was fine.
`isVisible` said yes. The frame said a number. The item existed. Only the
photograph disagreed.
