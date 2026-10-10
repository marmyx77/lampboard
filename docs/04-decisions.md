# Decisions

Every entry says **what** was decided, **why**, and **what was discarded**.
The negative decisions — the ones about what *not* to do — are at the bottom and
are worth as much as the others: they are the ones somebody will redo first if
the reason isn't written down.

Format: the decision, the context, the alternatives, and the **signal that would
make it worth revisiting**.

---

## D1 · The state has two independent sources

**Decided.** Hooks for the events, filesystem for existence, realigned every five
seconds.

**Why.** The hooks report what happens, never what disappeared or what was
already there. With only the first source the column fills with dead rows and
starts empty on every launch; with only the second you would know who exists but
not what state they're in.

**Discarded:** reading the transcripts in `~/.claude/projects/` as a source of
*state*. They are read today for the chat window, the preview line and the row
clock (D14, D17, D19), never for the colour: an internal format that changes
must not decide what a light says.

**Signal to revisit:** if Claude Code exposed a reliable close event for every
way of terminating a session — Esc included.

---

## D2 · The displayed state is derived, not stored

**Decided.** `SessionState` keeps `baseStatus` and computes `status` from the
subagent counter.

**Why.** With background agents, `Stop` arrives **while they are working**.
Taking it literally paints green — "there is an answer to read" — onto a session
that is still working: the most expensive lie the column can tell.

Deriving also solves the way back: when the last agent finishes, the green that
was set aside resurfaces on its own, without anyone having to remember it.

**Discarded:** resetting the counter on `Stop`, as the plan said. It was written,
tried, and turned out to be exactly the wrong behavior.

**Cost accepted:** a lost `SubagentStop` leaves the counter hanging and the row
yellow. Mitigated by resetting at the **next prompt**, which is a certain boundary.

**The same rule, later, through a second door.** Background shells do it too: the
turn ends, the recap is written, and `run_in_background` work carries on. `Stop` carries `background_tasks`, and any of them `running` (other than `dream`
and `cloud session`) now keeps the row from going green — it paints `waiting`,
see D22.
That case was examined on day one and dismissed with a coherent argument — that a
turn had ended and an answer existed — which answered the wrong question. Green
asserts *there is something to read* **and** *nothing more is coming*; only the
first was ever true there. See [Traps](07-traps.md).

---

## D3 · The criterion is where it runs, not how it was started

**Decided.** A session deserves a traffic light if its `cwd` sits inside a folder
an editor has open. The entrypoint only serves to **exclude** what isn't
interactive.

**Why.** `claude` launched from the integrated terminal has entrypoint `cli` but
runs in the same window, in the same project, and answers to the same click.
Filtering on an allow-list discarded it — and silently discarded every future
entrypoint too.

**The general point:** an **allow**-list, when it's wrong, hides. A **deny**-list,
when it's wrong, shows one row too many. The second mistake can be seen and
fixed; the first stays silent.

**Signal to revisit:** if enough non-interactive sessions appeared to make noise.
Today `kind == "interactive"` plus a short entrypoint deny-list (`sdk`, `sdk-cli`, `sdk-ts`, `sdk-py`, `print`) covers them — `kind` alone let claude-mem's SDK observer through.

---

## D4 · One row per project, on by default

**Decided.** Sessions from the same project share a single row. The dot shows the
most urgent state; the click opens the most urgent session.

**Why.** Measured: **22 distinct `session_id`s across 12 windows**. One row per
session drew 22 targets for 12 raisable windows, and ten of them led where
another already led.

**The risk, and its mandatory mitigation.** A click marks as seen **only the
sessions that were in the most urgent state** (`sessionIdsToClear`). Without that
limit, opening a project to answer a permission would erase the ready answer of
another session: grouping would become a loss of information instead of a
reduction in noise.

**Discarded:** keeping one row per session while sorting by project, so that
siblings stay adjacent. It reduces the disorder but not the number of redundant
targets.

---

## D5 · The deep link to the tab is off by default

**Decided.** The click raises the window. Opening the Claude tab as well is
optional, and starts off.

**Why.** Two consequences, which only surfaced once raising started working
properly:

1. VS Code asks for permission on **every** invocation. A click that asks for
   confirmation is no longer a click.
2. The extension reuses the tab only if it already has a panel for that
   `sessionId`; otherwise it **creates a new one**. That always happens for
   integrated-terminal sessions, which have no Claude panel at all — so even
   with the switch on, the link is sent only for sessions whose entrypoint is
   `claude-vscode` (`DeepLinkPolicy`); a `cli` session gets the window and
   nothing more.

The click keeps its promise anyway, because taking you to the right window is
done by accessibility, not by the link.

**Why it stays in the code:** for anyone working with one session per window and
Claude panels always open, it works well. The switch is also the escape hatch if
a future version of the extension breaks the contract.

---

## D6 · It raises by title, not by index

**Decided.** Recognition picks the title in Swift; AppleScript receives the
**name** to look for.

**Why.** Reading the titles and raising are two distinct Apple Events, and the
list is in depth order: between the two, the order changes on its own as soon as
the focus moves. The index computed against the first list ends up pointing at
another window — typically the last one used. Symptom: "sometimes it raises the
wrong one".

**Discarded:** moving the recognition inside AppleScript to do everything in one
call. It would make the most bug-prone part of the project unverifiable without
opening windows.

**Cost accepted:** the title can change between the two calls. In that case the
script fails with `-1728` and falls back, instead of raising the wrong window.

---

## D7 · `POST /signal` without a token, `GET /sessions` with one

**Decided.** Asymmetric on purpose.

**Why.** The read endpoint exposes the names and paths of the open projects,
which on a development machine are information. The one that *receives* the
signals, by contrast, cannot afford to fail: the hook script runs as the user and
could read the token, but a hook that fails authentication would block a Claude
Code turn for the sake of a decorative widget.

**What the token really protects against.** Other users on the machine, and
anyone arriving from the network. **Not** a process running as your own user:
that one can open the `0600` file, and no on-disk secret can prevent it.

Presenting it as a defense against the code running inside the sessions would be
a false reassurance — worse than no defense, because people stop thinking about it.

**Revisited, 20 September 2026.** The premise above was never measured, and when
it was it did not hold. Three turns against a dead port took 7.2, 7.4 and 8.4
seconds against a baseline of 7.2, 8.5 and 7.9, and `UserPromptSubmit`, `PostToolUse`
and `Stop` failed without a word reaching the screen. The one event that does report
a failed hook is `SessionEnd`, and it stays on the script, which swallows the answer
and exits 0 — so a `401` costs the turn nothing and tells nobody. The route now
**refuses a token that is present and wrong**, and still accepts one that is
absent. What stays asymmetric is *when*, not whether: hooks written by 0.4.0 carry
no token, and refusing them the day the rule landed would have turned every row
dark on every machine that had not reinstalled. D48 is what makes requiring it a
decision the app carries out rather than a hope about other people's habits. What
the token does not protect against is unchanged: a process running as your user
can read the file.

---

## D8 · The features that ask for permissions start off

**Decided.** Notifications and the presence file are off by default. Neither asks
for an authorization until you turn it on.

**Why.** A system dialog that appears unasked gets a "no", and that "no" is
forever. Asking at the moment the user flips the switch is the only moment when
the answer is informed.

For the presence file there is a further reason: it **inverts a built-in
behavior** of Claude Code. If the detection gets it wrong, the result is not one
notification too many but a notification **lost** — and lost notifications go
unnoticed.

---

## D9 · Only `awaiting` is notified, never `ready`

**Decided.** Only the state that **blocks**.

**Why.** A ready answer can wait until you look at it; a permission cannot —
until you answer, that work is stopped. With a dozen sessions, notifying on green
as well would produce tens of alerts a day, and a channel that alerts too often
gets switched off within two days. At that point the real blocks would stop
arriving too.

**A detail that matters:** what gets notified is a **transition**, not a state.
With the feature off the notifier keeps taking note of what is already blocked,
so flipping the switch with ten stalled sessions doesn't fire ten alerts at once.

**The gate holds only explicit silences.** There used to be a presence condition
as well — no alert if the panel is visible and you touched the Mac recently — and
it was removed in the face of the evidence: the panel is floating, so it is
always on screen, and if you're at the Mac you're active. What remains are three
checks the user chooses and can see: the memory that avoids duplicates, the
per-project silence, and the timed one.

**Revisited, 4 October 2026.** A turn that **fails** is notified too: red, like
amber, is a session nothing will move but you, and *Getting started* had been
promising it while the code did not. Finished turns stay out unless asked for, with
*Also notify when a turn finishes*, off by default — the reason above still holds
for everybody who has not asked. Both are announced on the transition only, so a
column already red at launch is not a burst.

---

## D10 · Failures get stated

**Decided.** Every operation that can fail silently declares it: a raise that
only half worked leaves a note in the menu, the signing script verifies before
declaring success, `LaunchAtLogin` refuses to register instead of registering an
identity that will change on the next build.

**Why.** This project lost more time to **fake successes** than to errors. An
alert shown after a success, a script that said "✓ created" after a failed
import, an `activate()` returning `true` without activating anything: every time
the symptom appeared days later, far from the cause.

**Concrete form:** `FocusResult` is a three-case enum rather than an `Error?`,
because `raised`, `activatedOnly` and `failed` deserve different reactions —
silence, a note, an alert.

---

## D11 · A test framework of our own

**Decided.** `TestKit`, 227 lines.

**Why.** The Command Line Tools without Xcode provide neither XCTest nor the
complete swift-testing. This is not a preference: the alternative was having no
tests.

**Consequence:** the tests are executables (`swift run LampBoardTests`), not a
test target. That's fine: it makes running them anywhere trivial, even inside
another process.

---

## D12 · Two suites, not one

**Decided.** `LampBoardTests` for the domain, `LampBoardE2E` for the chain.

**Why.** In this project the worst defects have never been inside a function:
they were in the **seams**. Title matching stayed broken for a whole day with ten
green tests; the socket was listening on every interface while the code looked
like it said the opposite.

The E2E suite launches the production binary against a fake home and talks to it
over HTTP, going as far as running `hook.sh` with the payload on stdin. It
verifies the **fact**, not the intention: the socket defect was found by looking
at `lsof`, not by re-reading the code that configured it.

**Cost accepted:** a minute against instantaneous. That is why they are separate.

---

## D13 · A keyboard slot is a pin, not a row number

**Superseded by [D23](#d23--the-column-does-not-reorder-itself).** The premise —
that the column reorders by urgency and so a row number cannot be an address —
no longer holds: the column keeps the user's order, and a slot is now simply a
position in it. Kept as written, for what it teaches about addresses.

**Decided.** Pinning a project binds it to the next free slot, 1 to 9.
`lampboard open 3` raises whatever holds slot 3. Pinned rows sit at the top of
the column **in slot order**.

**Why not just number the rows.** The column reorders by urgency continuously —
that is its whole job. A key bound to "the third row" would point at a different
project every few minutes, and a shortcut that acts on the wrong session is worse
than no shortcut: you press it without looking, which is the only reason to have
it. An address that moves is not an address.

So the order cannot come from anything the app observes. It has to come from the
user, and pinning was already exactly that — a short, deliberate list of projects
that matter. One concept now does two jobs that were always the same job: keep it
on top, and give it a key.

**What it cost.** Pinned rows no longer sort by urgency among themselves. A pinned
project that starts waiting stays where it is — it lights up, and it is still
above everything unpinned, but it does not jump to the front of its own group.
That is the price of the address being stable, and it is pinned down by a test so
nobody removes it as a bug.

**Discarded:** a second concept, "slots", separate from pinning. It would have
avoided touching existing behavior at the cost of two near-identical lists in the
menu, and this project's rule is that a feature which doesn't answer the question
doesn't get in.

**Discarded:** leaving a hole when a middle slot is unpinned, so the ones below
keep their keys. It is the more faithful analogue of physical keys, but it needs
an array with gaps in `UserDefaults` for a rare case. Unpinning compacts instead,
and "Move up / Move down" exists for anyone who wants to rearrange without
unbinding.

**Where the idea came from.** The Codex Micro's six Agent Keys, each bound to a
thread. The hardware makes the stability obvious — a key is a physical place. In
software it is the part you have to build on purpose.

---

## D14 · Two surfaces: a column you glance at, a window you sit down in

**Decided.** The panel is unchanged — a column of traffic lights that never takes
focus. The **extended window** is separate and opens on request: conversations on
the left, the selected one on the right. Close it and you are back to the lights.

Three ways in: the panel menu, ⌘+click on a row (which lands on that
conversation), and `lampboard chat <n>`.

**Why the panel could not simply grow.** It is a non-activating `FloatingPanel`,
and that is the whole reason it works: it sits beside the editor you are typing in
and must never steal focus. The extended view needs the opposite — you scroll it,
you select out of it, you type into it, you want it in ⌘-tab. One window cannot be
both, and the choice is not close.

**Discarded: one window per conversation, the ICQ shape.** It was argued for at
length — a roster of *states* rather than a list of messages, which is
structurally what this column is — and it was built, and it lost to half a day of
use. Switching project meant hunting for a window; with a dozen open, the desk
becomes the thing you manage. A list you click down is faster than a window you
look for. The argument was good and the use was better.

What survived that reversal is everything that was not about window management:
the transcript reader, the decoder, the mailbox, their tests. Only the pixels
moved.

**The cost, and the number that bounds it.** Every conversation you visit stays
parsed in memory so returning is instant, but **only the selected one polls its
file and only the selected one arms a message listener**. The running cost of the
window is one file poll and at most one waiting process, whatever the length of
the list.

**Discarded: embedding the real VS Code panel.** macOS does not let one
application host another's window; the ways round it are private SkyLight APIs and
a weakened SIP. What *is* reachable — positioning detached VS Code windows behind
our sidebar and raising the one you want — turns lampboard into a window
manager, and window managers die on Spaces, full screen and multiple displays.
Left as an experiment, not a plan. Note in passing that VS Code already ships the
useful half: **Claude Code: Open in New Window** detaches the chat into a bare
window of its own.

---

## D15 · Writing into a running session, through the front door nobody documented

**Decided.** The extended window has a composer. A message written there is left
in a mailbox on disk, and a **second `Stop` hook** marked `asyncRewake` carries it
into the session at the end of its next turn.

The mechanism in one line: Claude Code spawns that hook **detached**, so it
outlives the turn; whatever it prints on stdout becomes a message and **exit code
2 sends it**. Both halves of "send" are one act.

**Why this and not the obvious routes.** Eight ingress surfaces were investigated
and six are closed for good — recorded under
[N7](#n7--acting-on-a-running-session--the-codex-micro-command-keys) and in
`Contracts/assumptions.md`. The deep link refuses a prompt to an open panel;
the IDE WebSocket exposes twelve editor tools and no way into the chat; a
companion extension cannot reach another extension's webview, by platform
invariant; `--resume` from a second process **forks the transcript into a tree
with no warning**, and a completed turn was lost that way in testing.

**Why files and not a socket or a pipe.** The reader is not ours: Claude Code
spawns it, at a moment we do not choose, and it has to find the message already
there. Opening a named pipe for writing blocks until a reader exists — so typing
while Claude worked would hang the panel, which is exactly when you most want to
type. A file is late-binding by nature, and "queue it while busy" falls out for
free.

**Three things that are true and unpleasant, and are surfaced rather than hidden:**

- **`asyncRewake` is `@internal`.** It can be renamed without deprecation, and
  when it is, delivery stops **in silence** — no error, no log, the message simply
  never arrives. The contract check greps the shipped binary for the names on
  every run. That check is the warning, and it is not optional.
- **A dormant session hears nothing.** A listener can only be born at the end of a
  turn, so opening a conversation that is doing nothing arms nothing. The window says so — *"this conversation is asleep — a message will wait for it,
not vanish"* — instead of showing a spinner for something that will never
happen. It resolves itself the moment anything happens
  in that session.
- **The mailbox has no authentication, so the whole feature is off by default.**
  Dropping a file in it starts a turn that speaks in the user's voice with their
  tools. Permissions are `0700`/`0600`, like the access token, which stops another
  account on the machine — and stops nothing running as the user. There is no fix
  available: the reader is a shell script Claude Code spawns and it cannot know who
  wrote the file.

  So the switch decides, and it starts **off**. While it is off the listener is not
  registered at all: no hook, no mailbox, nothing on the machine that can start a
  turn in your name. Turning it on shows a dialog that states the trade in those
  words. The window reads everything either way.

  This follows [D8](#d8--the-features-that-ask-for-permissions-start-off), and for
  a sharper reason than the features it joins: those default off to avoid being a
  nuisance, this one defaults off because it is a capability.

  **The precise shape of that limit**, which took reading tmux to state properly:
  it is not that authentication was left out of the mailbox, it is that **a file
  has no author and a socket does**. tmux carries the same threat model — a socket
  in a directory anyone on the machine can try — and answers it with `getpeereid()`
  on the connection, a uid and gid attested by the kernel rather than claimed by
  the caller, with an ACL layer on top. A file dropped in a directory carries no
  equivalent. So per-writer authorization here is not a feature that is missing; it
  is a consequence of choosing a drop directory as the channel, and it could only
  ever be reopened by changing the channel — which the paragraph above explains we
  cannot do, because the reader is not ours to design.

  What *is* borrowed from tmux, and now implemented, is the smaller half: before
  writing through that path, `lstat` it and refuse anything that is not a real
  directory belonging to this user. Creating narrowly and being narrow are not the
  same thing — `createDirectory` succeeds against a symlink already in place, and
  the `chmod` that follows lands on the link's target. tmux refuses to start at all
  in that situation.

**What it looks like on the way back.** A delivered message returns wearing a
`task-notification` origin, the same envelope a background agent gets. The window
recognizes its own by the preamble it puts on outbound messages and draws it as
the user's own bubble; the VS Code panel cannot, and will show it as a system
turn. That difference is not fixable and is not worth hiding.

**Verified by reproduction**, three times, twice through the shipped scripts: an
idle session, a message written by an unrelated process, and a full agentic turn —
reasoning, tool call, answer — one second later.

---

## D16 · Markdown is parsed in Core and drawn in the shell

**Decided.** Answers are split into blocks by `MarkdownParser` and drawn by
`MarkdownView`. Headings, paragraphs, lists, fenced code, quotes, rules and pipe
tables; inline markup goes to `AttributedString`, which the platform already
provides.

**Why not a library.** The project has no dependencies, and a rendering package
brings a build story, a version to track and a surface to follow, in exchange for
constructs Claude does not write.

**Why the split.** Parsing is a decision and belongs where it can be tested
against awkward input without drawing anything; the seams between constructs are
where such parsers fail, and there is a test that feeds it one answer containing
every construct at once and asserts the order.

**Two rules that came from the content, not from taste:**

- **Code blocks and tables scroll sideways rather than wrap.** A wrapped command
  line cannot be copied and pasted, and copying things out of this window is most
  of why it stays open.
- **The user's own messages are not rendered as markdown.** They typed plain text;
  turning their asterisks into emphasis would put stress in their mouth they did
  not write, and would eat the characters.

**Anything unrecognized becomes a paragraph** — its own source text, readable —
rather than disappearing. That is the safe direction to be wrong in.

---

## D17 · The conversation list shows what was actually said

**Decided.** The line under each name is the last thing spoken, read from the
transcript.

**Why not `last_assistant_message`**, which the hooks hand over for free: it is
wrong twice. It is only ever Claude's side, so a project you have just written to
shows the previous answer — and on an interrupted turn it holds the **error text**
rather than anything anybody said.

**How the cost is kept.** Only the last 32 KB of each file is read; when that
slice holds nothing but tool calls — which is what the tail of a working session
looks like — it widens twice and then leaves the row blank rather than reading the
whole file; and results are cached on the file's size, which only grows. Drawing
the list costs one `stat` per row when nothing has moved.

---

## D18 · Dictation is ours, on the device, and it does not press send

**Decided.** A microphone button in the composer, using `SpeechTranscriber` — the
macOS 26 speech API. Everything on the device: no audio leaves the Mac and the
language model is a local asset. Press to start, press to stop, and what was heard
**goes into the box**, not into the session.

**Why not just the system's dictation**, which needs no code and no microphone
permission from us because the system captures and inserts the text. It is the
right answer for anybody it works for, and the README says so. It is driven by a
system shortcut rather than a control, it is off by default on a fresh Mac, and it
cannot do the one thing that makes dictation worth having in a chat: stop talking
and have the words be there.

**Why it does not send.** Dictation mishears. A wrong sentence you can still edit
is a different object from one already delivered, and delivery here starts a turn
that spends tokens and runs tools.

**Why the language is chosen strictly.** The recognizer transcribes everything as
the locale it is given, so handing it English for an Italian speaker does not
degrade politely — it produces fluent nonsense that nothing downstream can detect.
The rule is exact language and region, then the same language elsewhere, then
**nothing**: a refusal the interface can explain beats a confident lie. There is a
test named for it.

**What it costs.** Two permissions, and the feature exists only on macOS 26 —
below that the button is not drawn at all, because a control that cannot work
invites a click and answers with silence.

**Discarded:** shipping without the pulsing indicator. It is the only proof the
microphone is open; a dictation that silently failed to start looks exactly like
one listening patiently. That was not hypothetical — the first version had a
defect where the microphone opened and the state never went up, and without the
pulse there was nothing on screen to say which of the two had happened.

---

## D19 · The panel reports what it knows, and does not deduce what it doesn't

**Decided.** A session adopted from the filesystem, about which no hook has yet
spoken, is `idle`. Not because it is at rest — we have no idea — but because that
is what "no information" looks like in this vocabulary. The first hook replaces it.

**Why this is a decision and not a default.** It was briefly replaced by an
inference: *the transcript moved in the last forty-five seconds, therefore a turn
is in flight*. It reads as reasonable and it is wrong on exactly the day it
matters. A transcript is appended for many things that are not a turn, **resuming
a session among them** — so after a reboot, twelve sessions resume at once, twelve
files move at once, and every light turns yellow. A column that is uniformly wrong
is worse than one that is uniformly cautious: the panel exists to make one session
stand out.

**The general rule this belongs to**, which the project had already and which the
episode cost a day to relearn: **a state is measured or it is absent.** Deriving
it from a proxy — a file's age, a directory's contents, a count — produces a value
that is right in the calm case and confidently wrong in the busy one, and the busy
one is when somebody is looking.

The corollary is what to do with the proxy. The transcript's timestamp is real
evidence of *when*, and it is used for the clock on the row. It is not evidence of
*what*, and it is kept away from the color. Same measurement, two questions, one
answer each.

**Signal to revisit:** a source that says what a session is doing rather than when
it last did something. The last record of a transcript is a candidate — a
`tool_use` means a turn is in flight, an `end_turn` means it is not — and that
would be measurement rather than inference. It is not built, and it is worth an
hour with tests rather than ten minutes without.

---

## D20 · The traffic light does not answer questions

**Decided.** lampboard registers only hooks that **observe**. The four that
**decide** — `PermissionRequest`, `PermissionDenied`, `Elicitation`,
`ElicitationResult` — stay unregistered, and this is a standing rule rather than
a to-do item.

**What makes them different.** Every hook this app registers today is a spectator:
Claude Code sends the event, the script forwards it, the turn continues whatever
happens. The script cannot alter the session, because there is no channel through
which it could. The decision hooks have one. Their output schema, read in the
binary, carries a verdict:

```
hook_event_name: "PermissionRequest",
decision: { behavior: "allow", … } | { behavior: "deny", message?, interrupt? }
```

Registering one puts the script between *"Claude wants to run `rm -rf build/`"*
and *"the user decides"*. It would print nothing, as it does today, and the
question would reach the user unchanged. But the **cost of a defect** changes
class: today the worst a broken hook does is leave a light behind; there, stray
output that parses as a verdict approves a tool call the user never saw.

**What we would gain, stated fairly**, because the trade is real and not
one-sided. `PermissionRequest` carries `tool_name` and `tool_input`, so the row
could say *"waiting: Bash — rm -rf build/"* instead of an unexplained amber. And
it would replace an inference: today `awaiting` is derived from `Notification`
plus a `notification_type` subtype that nobody documents and that also carries
`idle_prompt` — the field that once had this app inventing answers that never
arrived. A dedicated event is strictly better evidence.

**Why the answer is still no.** The gain is precision on a state that already
works. The cost is that a monitor becomes a participant. This project keeps its
capabilities off by default and its one writing feature behind an explicit switch
([D15](#d15--writing-into-a-running-session-through-the-front-door-nobody-documented));
sitting in the permission path by default would contradict that on the app's most
sensitive surface.

**And the evidence is not there anyway.** The schema is measured. The *firing* is
not: a non-interactive `claude -p` never reaches an approval prompt — three probe
sessions, including one forced with `--permission-mode manual`, ran the tool and
produced no `PermissionRequest`. Which is exactly the standard of proof that had
just collapsed under `TaskCreated`, one hour earlier, in
[docs/07-traps.md](07-traps.md).

**Signal to revisit:** a measured, interactive recording showing that a hook
returning empty output leaves the approval flow untouched — **and** a decision
that the amber row is worth naming the tool. The first is a fact; the second is a
posture, and it is the user's to take, not the code's.

---

## D21 · Other machines are read, not heard

**Superseded in part by [D24](#d24--other-machines-are-heard-through-a-tunnel-we-open).**
Reading stayed — it is how a remote row is confirmed alive — but it stopped being
how a row is *born*: a row nobody can click and that never changes colour turned
out to be noise, and the tunnel D24 opens is not the network exposure this entry
refused. Kept as written for the reasoning about `/signal`, which still holds.

**Decided.** Sessions on another machine appear in the column because lampboard
**asks that machine over ssh**, on a slow timer. The alternative — installing the
hook there and letting it post here — stays closed.

**What made the choice.** `POST /signal` carries no token. `GET /sessions` does,
`/signal` never did, and on loopback that was a defensible asymmetry: anything
already running as the user can move the column, and a token would not change
that. It stops being defensible the moment the endpoint is on a network. Opening
it on the tailnet would put **unauthenticated state injection** on every device
that can reach the Mac, to save twenty seconds of latency on a machine nobody is
looking at.

Reading needs nothing open, no token to distribute, and no new listening surface.
It also matches what the distributed-brain plan already says out loud —
local-first with aggregation, no single point of failure — and it fails in the
right direction: a node that is asleep costs one poll that returns nothing.

**What the node does, and why there.** Two of the three facts a row needs are only
true where the processes are: whether the pid is alive, and when the transcript
last changed. So the probe runs *there* — piped to `python3` over the connection,
nothing installed, nothing left behind — and returns one JSON array. Deciding
here from shipped files would answer both questions about the wrong machine.

**Three things this makes different, on purpose:**

- **A remote workspace is the session's own folder.** Locally a row exists only if
  an editor window claims the `cwd`, because the panel is about windows you can
  click. That criterion is meaningless for a tmux pane on a headless node, and
  applying it there is exactly what kept those rows invisible: no lock on this
  machine claims `/home/…`, so every one was dropped.
- **`nil` and `[]` are different answers.** The reader returns an optional: `[]`
  means *asked, nothing running*, `nil` means *no answer*. Collapsing them would
  let a dropped VPN erase live rows — the same mistake as reading a timestamp and
  calling it a heartbeat. A host that does not answer keeps its previous rows.
- **A click on a remote row raises nothing.** There is no window here. It says
  where the session is instead of opening a modal that says "cannot open".

**What it does not do.** The chat window cannot open a remote conversation: the
transcript is on the other machine. Reading it over ssh on every poll is a
different feature with a different cost, and it is not in this one.

**Cost.** One ssh handshake per host every twenty seconds, against five seconds
for the local pass. `BatchMode=yes` so a host wanting a password fails in a second
instead of waiting for a prompt nobody will see, and a hard kill at twice the
timeout so a half-open connection to a sleeping node cannot hold the poll.

**Off unless asked.** Hosts came from `~/.lampboard/remotes`, one per line — since D24 they are set in the Settings window or with `lampboard remote add`, and that file is only imported once on upgrade.
Absent or empty means off, which is the default: reading another machine is an
outbound connection this app would otherwise never make. Names are checked against
an allow-list before reaching ssh — a name starting with a dash would be read as
*options*.

**Signal to revisit:** a token on `/signal`. With one, the push route becomes
defensible and the latency goes away; without one, this decision stands.

---

## D22 · A sixth state, for a session that has stopped but is not done

**Decided.** `waiting`, soft blue: the turn is over, and something Claude started
— a background shell, a monitor on a CI run, a subagent — is still running and
will wake the session. It sits between `working` and `idle`, does not blink, has
nothing to clear on click, and resists a trailing tool event the way green does.

**Why five were not enough.** The rule "work in flight at `Stop` keeps the row
working" fixed a real lie — green over a session with a shell still running — by
telling a smaller one. Yellow means *Claude is thinking*. After a `Stop` with two
monitors on a CI run and a shell serving the tests, Claude is not thinking: it has
handed control back and is **waiting for an event**. A CI run takes an hour; the
row said "working" for an hour; and the person looking at it, rightly, asked what
on earth it was working on. Measured on the log that answered:

```
Stop  working -> working  inFlight=3[monitor,monitor,shell]
```

**It is not an inference.** The state is exactly what the payload declares:
Claude Code documents `background_tasks` as the way to tell *"session is done"*
from *"session is paused waiting for background work to wake it"*. The first is
green, the second is blue. Nothing is guessed from timestamps or silence.

**What the row says.** `waitingOn` keeps the types, so the tooltip reads
`waiting on monitor ×2, shell`. A blue row that stays blue for a day is now a
row that names the shell holding it — which is what makes the remaining honest
question, "is that shell a dev server nobody will ever stop?", askable.

**Subagents follow the same grammar.** A subagent alive after the parent's `Stop`
used to paint yellow over any state; it now paints blue, for the same reason.
And a subagent *starting* while a question is pending proves that question was
answered, so an `awaiting` row becomes `working` (D20's sibling rule) — from any
other state a starting subagent repaints nothing, because one launched at the
end of a turn arrives after the parent's `Stop`.

**The way back is the same as before.** The work finishes, Claude Code starts a
turn to report it, `UserPromptSubmit` paints yellow and empties `waitingOn`, and
that turn's `Stop` is green if nothing else is in flight.

**Alternatives.** Keeping it yellow with a tooltip — but the colour is what you
see from across the room, and it was the colour that lied. Going straight to
green — the lie D17's ancestor fixed. A blinking blue — blinking is spent on the
one state that blocks you, and this one does not.

---

## D23 · The column does not reorder itself

**Decided.** Rows keep the place the user gave them. A project seen for the first
time is appended at the bottom; from then on it moves only when dragged by its
handle (≡, on the right of the row) or nudged from the menu. A change of state
lights a row up **where it is**. Slots are positions: the first nine rows are
keys 1 to 9. This supersedes D13, which no longer has a problem to solve.

**Why.** Reported by use, and true on reflection: a column that re-sorts itself
has to be re-read every time it changes. A green rising to the top pushes every
other row down by one; a red sinking pulls them all up; and the eye, which had
learned that the third row is *that* project, finds something else there. The
urgency sort was built to answer "which one needs me" — but the colour already
answers that, and answers it without moving anything. Sorting moved rows to say
what the colour was saying already.

The second cost is what made it a defect rather than a taste. A row that moves
under the pointer is how the wrong session gets opened (07-traps, *The click that
only knocked*): the first click cleared a green, the column re-sorted, the second
click landed on whatever had moved in. A fixed order removes the mechanism, not
just the symptom.

**What it cost.** A row asking for attention at the bottom of a twelve-row column
is a dot at the bottom, not at the top. The notification and the blinking amber
still cover the case where you are not looking, and "only what's waiting"
collapses the column to the rows that need you — in your order. Pinning is gone
as a concept: every row is where you put it, so "pin to top" is a drag. The
`pinned` field left the `/sessions` contract; nothing outside read it and it had
no meaning left.

**Discarded:** freezing the order only while the pointer is over the panel. It
prevents the mis-click and keeps the urgency sort — but the column still shuffles
the moment you look away, which is the part that was reported as confusing.

**Discarded:** urgency *within* the user's order, e.g. a green rising among its
neighbours only. Half a fixed order is no order: the eye cannot learn a rule
with an exception in it.

**Where the order lives.** `preferences.rowOrder`, one list for three readers —
the panel, the extended window and `/sessions`. `StateStore` gives a newcomer its
place *before* publishing the state, so headless mode and the CLI agree with the
panel; the panel rebuilds its view when the options it was built with change. The
list may name projects with no live session: their slot is empty, and `open n`
says so rather than opening the neighbour — unchanged from D13, and still the
worst thing a blind key could do. Whoever upgrades finds their pinned projects at
the top, in slot order, and everything else below as it is seen.

---

## D24 · Other machines are heard through a tunnel we open

**Decided.** A remote machine's Claude Code hooks reach this Mac through a reverse
ssh tunnel lampboard opens and keeps open: `ssh -N -R
127.0.0.1:<port>:127.0.0.1:9877 host`, where `<port>` is **derived from the
user's uid over there** (`30000 + uid % 20000`). On the node, that loopback port
*is* this app, so the hook script installed there — by lampboard, over ssh, with
the same merge the local installer uses — posts to it and adds one header,
`X-LampBoard-Host`, naming the machine; the header is believed only for a host this
app was told about. After every connect the node is asked, from `/proc/net/tcp`,
**where the port is actually bound**: anything but loopback closes the tunnel
and says so. A remote row is **born when the session speaks** and **dies when
the node's probe no longer lists its pid** (or on `SessionEnd`). Clicking it
raises the Remote-SSH window of its folder, if one is open here. Hosts are
configured in the Settings window (or `lampboard remote add`), not in a file.

**What was wrong with D21, measured.** Reading alone produced rows that never
changed colour — no hook ever reached this machine — and that a click could not
open; and it listed every live `claude` on the node, including one left in a
detached tmux for two days that nobody had opened from here. *"Always red, the
click goes nowhere, the sessions look random"* is the accurate description of a
row that carries no state, no target and no consent. The session the user actually
drives lives in a **Remote-SSH** window on this Mac, titled `… — folder [SSH:
host]`: there was a window to raise all along.

**Why a tunnel and not a token.** D7's argument stands: `/signal` has no token,
and putting it on a network interface would be unauthenticated state injection
from every device on the VPN. The tunnel does not do that: its far end is bound
to the node's loopback — *verified*, not assumed — so the only thing that can
post through it is a process running on the node, the same trust the local
loopback already extends to every process on this Mac. A token would have to be
distributed and rotated on every node; the tunnel needs only what already exists,
the ssh key.

**What the review found wrong with `-R 127.0.0.1:9877`, and what became of it.**
The adversarial review before shipping found three things wrong with a plain
port, none visible from the Mac. The bind address is a *request*: under
`GatewayPorts yes` OpenSSH binds the wildcard address instead and tells the
client only in a debug message — the exact exposure this decision claims not to
have, with the app showing "connected". A fixed port is every account's: another
user on the node could post into this column, and the hook script would hand
`last_assistant_message` to whoever held the port while the tunnel was down. And
a connection that dies — sleep, VPN — can leave the server holding the port, so
the reconnect fails against its own ghost until the backoff gives up. The
review's answer was a Unix socket in the user's home, which has none of these.
It was built and **failed on measurement**: the machine at hand runs **Tailscale
SSH**, not OpenSSH; its daemon does the forwarding as root and created the socket
`root:root 0600`, which the user's `curl` cannot open. What shipped keeps the
port and answers each problem where it lives: the port is the user's own
(uid-derived), so accounts never share one; the node reports the bound addresses
after every connect and the tunnel closes itself on anything but loopback; and a
port already bound is seen *before* the connect and waited out, one log line,
not a failure loop. The same review found the probe blocking the main actor and a
newborn remote row erased by the next local pass; both are fixed below.

**Why born by hooks, not by the probe.** The obvious presence rule — "the cwd is
inside a folder some editor window has open on the node", i.e. the local rule
applied there — was tried on paper against the node and failed: the one ide lock
there is `/home/<user>`, and every session on the machine is under it. A row that
exists because the session did something is a row about something you did; the
probe still answers the one question it is good at, *is this pid still alive*,
now with a guard against reuse (`procStart` against `/proc/<pid>/stat`). A host
that has never answered keeps its rows — silence is not death — and a host
removed from the settings takes its rows with it.

**What it cost.** A remote session that has said nothing since the panel started
is invisible until it does. The tunnel is a long-lived ssh process per host,
restarted with backoff when the node sleeps or the VPN drops, and every route of
this server — `/sessions` and the token-gated ones included — is reachable from
the node's loopback, by any account on it while the tunnel is up; the token is
now doing the network-facing work it was sized for, and the residual risk — on a
machine with several accounts, a squatter on the user's port while the tunnel is
down would receive hook payloads — is stated here rather than engineered away.
Installing the hooks means lampboard writes
`~/.claude/settings.json` on another machine — with a dated backup that keeps the
file's mode, atomically, through Python fed on stdin so no shell ever sees the
data, and **only if the file is still the one that was read** (sha256): Claude
Code over there writes it too. No tab deep link for a remote row: the link goes
to the local extension host. The probe runs off the main actor — an unreachable
host is the common case now, and it must never freeze the panel — and a row is
protected from its verdict until the probe has looked *after* the row's last
sign of life. Every ssh this app starts carries `-a -x ForwardAgent=no
PermitLocalCommand=no`, whatever `~/.ssh/config` says for that host.

**Discarded:** reading Claude Code's own `status` from the session files. It is
there — for `cli` sessions, since 2.1.243 — but not for the VS Code extension's
sessions, and only `idle` was ever observed. Half a source is a guess with a
timestamp.

**Discarded:** a token on `/signal` and the port on the tailnet. Right in
principle, and a second secret to manage on every node for what one existing key
already does.

**Deferred, and why.** Attributing a signal by the listener it arrived on — one
local port and one `SignalServer` per host — instead of by a header the node
writes. It is the cleaner design (renaming a host, two Macs naming one node
differently, a header-less post all resolve by construction) and the review asked
for it. What is shipped instead: the header is only believed for a configured host, and
the far end is a loopback port owned by that user's uid on that machine — so an
unrelated device cannot write it, though another account on the node can while
the tunnel is up. That closes the forgery that mattered; the rest is a rename that
today needs the hooks reinstalled, which `remote add` says out loud.

**Signal to revisit:** a node that is not reachable over ssh but can reach the Mac
— the tunnel then has to be opened from the other side, and that is a different
feature.

---

# Negative decisions

What was decided **against**. If somebody picks these up again, they have to
answer first the reason they were excluded.

## N1 · Allowing or denying a permission from the row

The `PermissionRequest` hook exists in binary 2.1.220 and can decide the outcome.

**Why not.** The hook **blocks the turn** until it answers. If lampboard isn't
running or has crashed, **every permission request hangs** — a decorative widget
would become a breaking point for the real work.

And a widget that grants permissions to Claude Code is an attack surface on a
local endpoint.

**What it would take:** authentication on every route, and a safe default
behavior if the panel doesn't answer within a short time.

## N2 · A summary when you come back

A single notification on your return, instead of one per event.

**Why not.** When you come back you look at the panel anyway, and the column
already says everything. To be done **only if** the per-event notifications prove
noisy — and today they are off, so that evidence doesn't exist yet.

## N3 · JetBrains and the other IDEs

**Why not.** `WindowTitleMatcher` is tuned to VS Code's format
(`file — folder — profile`); JetBrains uses `project – file`, which is a
different grammar. Adding an editor that can't be tested doesn't widen coverage:
it creates a row you can see and a click that doesn't work, which is **worse than
no row** because it teaches you not to trust it.

Cursor is included because it is a VS Code fork — same lock format, same title
format — and only three names differ, read from the `Info.plist` rather than
guessed.

## N4 · The extension's MCP server

The extension exposes an MCP server over WebSocket with twelve tools for
manipulating the editor.

**Why not.** It would give far more control than a traffic light needs, and it
would tie the project to an internal interface much wider than a URI handler.

## N5 · `windowId` in the deep links

**Why not.** Routing between windows turned out to be non-deterministic: the link
lands where the focus is, not where the parameter says.

## N6 · A global shortcut inside the app

**Implemented, tested, and removed.**

`RegisterEventHotKey` is the only route without extra permissions for an
*accessory* app. On macOS 26 it **registers and never delivers**: verified with
two independent binaries, same recipe, live panel, zero events.

The alternative that does work requires **Input Monitoring** — permission to read
every key pressed. For a traffic light that is out of proportion.

**But the reason it was removed rather than left switched off is a different
one:** `register()` returns success, the switch stays on, and nothing happens.
The app **cannot notice** that it doesn't work, so it cannot say so. It is the
"fake success" category — the same as `activate()` returning `true` without
activating, and the script that said "✓ created" after a failed import. A switch
that can lie is worse than a switch that isn't there.

**In its place**: `lampboard next` exists and works, and binding a combination
to that command is what the macOS Shortcuts app is for. It isn't a fallback — it
is better on three counts: the user picks the combination, the interface says
whether it is already taken, and when it doesn't work you can see it.

**Signal to revisit:** a system API letting an accessory app register *one*
combination with verifiable delivery.

---

## N7 · Acting on a running session — the Codex Micro command keys

OpenAI's Codex Micro (July 2026) puts *command keys* on a macropad: accept, reject,
push-to-talk, branch, new chat — all acting on the agent thread that is currently
running. The question was whether lampboard could do the software equivalent.

**Why not.** Every one of those reduces to the same primitive: *send text to that
specific session*. The channel looked available — the extension's `/open` URI
handler reads a `prompt` parameter next to `session`. It isn't. The extension
applies the prompt **only when it creates a new panel**, and refuses otherwise
with a message written for the user:

> `"Session is already open. Your prompt was not applied — enter it manually."`

The one case where sending text would be useful — a session that is open and
waiting for you — is exactly the case it refuses. What remains reachable is
"open a **new** conversation, pre-loaded with a prompt", which starts work rather
than steering work in flight. That is not the feature.

**What was worth taking anyway.** Two things, both of which needed an address
rather than a channel — see [D13](#d13--a-keyboard-slot-is-a-pin-not-a-row-number):

- **Agent Keys** → `lampboard open <n>`, raise the project in slot n.
- **"Start new chat"**, which is one of their command keys and the only one that
  survives, because it creates a **new** panel instead of touching a running one
  → `lampboard new <n>`.

**And the half-measure that was left out.** The `prompt` parameter does work on a
new conversation — but following it into the webview shows it ends at
`setInputText`, which **prefills the composer and does not submit**. A key that
opens a tab with text you still have to confirm is not a command key, so
`lampboard new` sends no prompt. It is recorded in
`Contracts/assumptions.md` under `extension.newconversation`, because "we already
checked, and here is how far it goes" is the part that stops the question being
reopened from scratch.

**The rotary dial, for completeness.** `effort.level` arrives on every `Stop`, and
`--effort` / `/effort` can set it — but only when a session starts, or by typing
into it. The dial's whole value is changing it mid-flight, which is the same wall.

**Cost avoided.** The refusal was found by reading the shipped extension, not by
testing against a live session. Two minutes instead of an intrusion into a working
desktop — and a firmer answer, because a user-facing string in the code is a rule,
not an observation that might have been a fluke.

**Signal to revisit.** The refusal disappearing. It is tracked in
`Contracts/required-fields.json` under `extensionOpportunities`, and
`check-contract.sh` reports it as an **opening** rather than a breakage — the one
place where the contract checker watches for good news.

## D25 · A folder nobody claims is a place too

**Decided.** With "Show terminal sessions" on (panel menu, Settings, or
`lampboard terminal on`), a local interactive session whose folder no editor
window claims gets a row of its own, with **the folder its session file names**
as its workspace. It is born when the session speaks or is adopted from the
session file, like an editor session; it exists only while a **live local
session file** names it — a hook alone is not enough — and it leaves when the
process is gone. Off by default (D8: clicking one will ask for an Automation
permission per terminal application). Off takes the rows away at once.

**Why the file's folder and not the hook's.** Measured: Claude Code moves its
process directory with the Bash tool's persistent `cd`, and the hook payload
carries that directory — one session's transcript held 16,170 records at the
project root and 29 under `docs/`, from a single `cd docs`. Editor rows never
noticed, because a subfolder still resolves to the window's folder. A terminal
row anchored on the hook's `cwd` would have moved on every `cd`. The session
file's `cwd` is written once, at startup.

**Why the file at all.** A signal whose `X-LampBoard-Host` names a host the app was
never told about is treated as local (D24), and so is any process on loopback
that speaks the protocol. Requiring a live session file for the id is the one
condition that keeps a forged header, a foreign path and a dead process out of
the column — and it costs nothing, since the file is what the click needs anyway
(the pid).

**The row knows what it is.** `SessionState.origin` is `.editor` or `.terminal`,
set by whoever resolves the workspace — the resolver's answer at signal time, or
adoption — and nowhere else. Not on `Workspace`: that type is the row's
identity, and a terminal session and an editor session in the same folder must
still group. Everything that treats a terminal row differently reads this field:
the label, the glyph, the menu, the click, `new`, the switch turning off.
Nothing infers it from the entrypoint: `claude` typed in the integrated terminal
is `cli` and an editor row, as before.

**Label.** A terminal row holding one session with a known conversation title is
named by that title; otherwise by the folder, as every other row. The title is
what the person sees in their terminal's title bar, and the folder of a session
started in `~` is a username. The name changes once, when the title arrives, and
falls back to the folder when a second session joins the row. The rule lives on
`SessionState.displayName`, and every surface that names a session to a person
goes through it — the row, its tooltip, the answers of `open n` and `next`, the
notification title, the hidden summary. Window matching and `/sessions.workspace`
keep the folder name.

**The click, by origin.** An editor row takes the path it always took — window
by folder title, no process walk — and the tab deep link only when the session's
entrypoint is `claude-vscode` (D5). A terminal row's click goes through the
session's process — pid from the session file, `procStart` against the kernel's
start time, the chain up to the hosting application (`ProcessTree`,
`SeatClassifier`) — to that application's own way of selecting a tab: by tty
through the dictionaries of Terminal.app and iTerm2 (`TerminalScripts`). A tmux
pane is selected inside tmux and its attached client's tab raised the same way;
a zellij pane's client is paired with its server through their Unix sockets
(`lsof`) and its tab raised likewise, with the tab titled by the session name
as the fallback. Ghostty has no tty in its dictionary but lists every terminal's title and
working directory: the match happens in Swift and only the chosen id goes back
into a script. Where that description names more than one surface, or none, the
tty is asked instead — a marker title written to it, the listing taken again,
the surface carrying it identified and its old title put back. WezTerm's CLI lists panes by tty; kitty's, over its remote-control
socket, lists windows by pid — with remote control off the click activates
kitty and the menu says why it stopped there. Consequence,
stated: a `claude` started in a Terminal.app tab **inside a folder that is open
in VS Code** is an editor row and its click raises the VS Code window. The
alternative — a process walk on every editor click — would show a Terminal
Automation prompt with the feature off, which D8 forbids.

**What does not change.** Attribution of a session whose folder is open in an
editor. Grouping by folder. Slots, order, hide, mute, calm, the chat window,
notifications, message delivery (hook-based, so it reaches a terminal session
the same way). Remote rows.

**Discarded:** a row per terminal tab. It would split the folder rows people have
already placed, and the click resolves the tab anyway. **Discarded:** born only
when it speaks, as for remote hosts — locally the pid check makes adoption safe,
and a switch that shows nothing until the next turn reads as broken.
**Discarded:** the process tree overriding the folder for editor rows, see *The
click, by origin*.

**Deferred, and why.** `.reconcile` ignores an empty set of live pids, so a lone
terminal row whose process dies without `SessionEnd` stays until the twelve-hour
prune. The fix — a reader that tells "unreadable" from "empty" — is right, and
the end-to-end harness leans on the current leniency in a third of its cases;
that rewrite is its own change.

---

## D26 · A row can be renamed, and the name is only a name

**Decided.** Right-click → *Rename…* (or `lampboard rename <folder> [name]`)
gives a row the name the user wants to read. It changes what the panel, its
tooltip, the notification, `open n`, `next` and `/sessions.label` **show** —
nothing else. The window is still found by its title, the transcript by its
path, the folder is still the folder, and `/sessions.workspace` still says it.
A blank name restores the original.

**Why keyed by folder, not by session.** A session id is born and dies with a
process; a name that vanished at every restart would be a name you gave twice a
day. The folder is the row's identity (D4, D23) — the name follows the row, and
with grouping off every session of that folder shows it. That is the cost
accepted: the request said "sessions", the durable thing is the place.

**What it does not touch.** The order, the slots, hide, mute, calm: all keyed by
folder already, and a rename moves none of them. The conversation title of a
lone terminal row yields to the given name, as does the folder.

**Discarded:** a name per session id, for the reason above. **Discarded:**
renaming the workspace itself — the name is the key every window is found by
(D6), and a key you can edit is a key you will one day break.

---

## D27 · A bounded freeze now, and the click stays on the main thread

**Decided.** Every command the click runs — `lsof`, `tmux`, `wezterm`, `kitten`,
`open` — goes through `Command` with a deadline: five seconds for a probe,
fifteen for `open`, which may have to start an application that is not running.
Nothing moves off the main actor.

**The problem.** `PanelController` is `@MainActor`, so the whole click runs on
the thread that draws the panel, and every one of those commands was launched
with `try process.run()` followed by `process.waitUntilExit()` — an unbounded
wait. Two of them can genuinely stop: `lsof` stats every open descriptor, so a
network mount whose server has gone away holds it there indefinitely, and the
three multiplexer clients each ask a server of their own over a socket. When
that happens the panel does not redraw, no other row is clickable, and the
column keeps showing the last state it managed to draw while the signals pile
up behind it — the lights telling a past, which is the one thing this app must
not do.

**Measured, on a healthy machine:** `lsof` 0.059s, `ps` 0.065s, AppleScript to
System Events 0.672s, `open -b` 0.749s. A click costs between 0.7 and 1.5
seconds of main thread even when everything works.

**Why not the real fix.** The real fix is to resolve the seat and consult the
tools off the main actor, hopping back only to report — that removes the freeze
*and* the 0.7–1.5 second hitch. It is not done here for three reasons, and none
of them is that it does not matter. `NSAppleScript` is not thread-safe and would
have to be pinned to one thread of its own. No automated test covers the click:
neither suite raises a window, so the only verification is a person clicking each
kind of row. And the ranking between "annoying hitch" and "must fix" depends on
a measurement nobody has taken yet — the click timed on the rows actually in
use, VS Code, zellij, Terminal.app.

**So this is deliberately the smaller half.** It converts an unbounded freeze
into a bounded one with a sentence under the rows, and leaves the behaviour
identical in every case that was already working. What it does not do is make
the click feel instant.

**Discarded:** a watchdog that abandons the click halfway. It would leave an
application activated but its window not raised, which is the state the panel
has the hardest time explaining, and the one that reads as "it half works".
**Discarded:** skipping `lsof` because it is slow. It is the only way to pair a
zellij client to its server (D24), and at 59 milliseconds it is the fast part of
the chain.

---

## D28 · A listener gets a ring, not a colour

**Decided.** `background_tasks` entries are now read in three groups, not two.
Housekeeping (`dream`, `cloud session`) is ignored, as before. Work — a shell, a
subagent, a workflow, **and anything unrecognised** — turns the row blue, as
before. A `monitor` does neither: the row keeps the colour it would have had,
and the dot is drawn with a blue ring around it.

**Why.** A monitor watches for a condition. Until that condition happens it
produces nothing, writes nothing and wakes nobody — while the answer the session
wrote before registering it sits above, unread. Painting the row blue says "more
is coming" about something that may never come, and hides the one fact the
column exists to deliver. Measured on a real session: two monitors registered at
06:38 held a row blue for an hour with a finished reply underneath.

**Why a ring and not a sixth colour.** Because it is not a state. The turn ended
green, or red, or the session is working again, and *besides that* an ear is
open. A colour of its own would have forced a choice about which of the two
facts to hide, and the one being hidden was the answer. The ring is the same
blue the column already teaches: as a fill it means "registered, nothing needs
you"; as a ring it means the same thing without taking the colour that carries
the news.

**What the ring outlives.** Reading the answer. A green clears when you look at
it, and the ear does not close because you looked — so the row keeps what is
registered behind it and the ring survives into the idle state, until the
listener actually goes.

**Unknown types are work.** The mistake here is not symmetrical. Calling real
work a listener paints green over a session that is still busy — the exact lie
`waiting` was introduced to prevent (D22). Calling a listener work only shows
blue a while longer. So the listener list is short, explicit, and closed.

**Discarded:** blue after N minutes, so short work never shows at all. It trades
a wrong colour for a late one and makes the column's meaning depend on a clock.
**Discarded:** dropping monitors from the payload entirely. Then a row with an
ear open is indistinguishable from one without, and the tooltip that says
*"still listening: monitor ×2"* — the thing that turns a puzzle into a fact —
would have nothing to say.

---

## D29 · A context figure is a floor, or it is nothing

**Decided.** Each row can say how full its session's context is, read from the
end of the transcript, in three renderings and never two: `62%` when nothing has
been added since the last reply, `≥62%` when something has, and `—` when the
number is known to be wrong. The dash is never a blank.

**Why not one number.** Only assistant records carry a token count, so what can
be read is the context as it stood at the last reply; anything loaded since — a
pasted file, a tool result, a resumed history — is invisible. Measured across 171
compaction boundaries, the truth was a median of 1.00× the last reading and a
maximum of **17.67×**: one session would have displayed 56,555 while holding
close to a million. A figure that is occasionally seventeen times too small is
not a figure, it is a trap, because somebody would start a large task on it.

**The denominator is a contract, not a constant.** The window is not in the
transcript: it records `claude-opus-5` and says nothing, and `--model sonnet`
with no suffix resolves to a million as well. It is a property of the model, and
the table lives in `Contracts/required-fields.json` with `check-contract.sh`
re-reading Claude Code's binary on every run — a release can move a window
silently, and the panel would go on dividing by the old one with complete
confidence. A model absent from the table gets no percentage at all.

**Remote sessions are read where they live.** A transcript on another machine is
not a file here, and `HookPayloadDecoder` deliberately nils the path for any
signal carrying a host. But the probe already stands in that directory: it now
sends back a **miniature of the tail** in the same shape as the real thing, and
the Mac reads it with exactly the code it reads a local transcript with. The
rule stays in one place; the machine we do not update judges nothing.

**Discarded:** a bare percentage. It is the version everybody asks for and the
one that would lie. **Discarded:** anything on the dot — fill level, arc, a
second ring, red at 90%. Red already means "idle, nothing is coming from here",
and the ring is spent on D28. **Discarded:** a burn rate, or "fills in about
forty minutes". The input is a floor sampled once per completed turn, and a
single measured turn grew by 52,218 tokens. **Discarded:** building it on
Claude Code's status line, which reports the number exactly and does not run
under the VS Code extension — six of the eight sessions open here would get
nothing.

---

## D30 · The context takes the slot's cell, and the window is the denominator

**Decided.** The cell left of the name no longer carries the row's keyboard slot.
It carries an eleven-point ring: the arc is how much of the context window is
gone, the letter in the middle is the model family — `O`, `S`, `H`, `F`, `M`, and
`n` for one this build has no window for. Monochrome. The slot moved into the
tooltip, which also gained the exact figure, the model with its version, and —
on a renamed row — the folder underneath.

**Why the slot lost.** It answers "which key opens this" once and then never
changes, on a row whose position never changes either (D23). The saturation is
the opposite kind of fact: it moves while you work, and it is the one that
decides whether a large task starts here or in a fresh session.

**The price, measured.** Ten points of the name: on a plain row with a `14:56`
timestamp the field goes from **110.87 pt to 100.87 pt**. Six of those went to
the ring being wider than the cell it replaced (15 against 7) and four to the
light growing from 11 to 13 — because the first version of this shipped at eleven
points and came back with one word from use, *illeggibile*. A letter inside a
stroked circle needs the circle: 15 points across, a 2.5-point stroke and an
8-point capital, which leaves 10 points of clear middle.

**Why monochrome.** Six states already own the colour in this panel. A ring that
turned red near the end would be a seventh voice, arriving exactly when the row's
own colour matters most.

**Three silences, three marks.** A dashed circle means nothing has been read from
that session yet. A solid circle with a dimmed letter means a figure was read and
is known to be wrong — the session was compacted since. An `n` means the model is
unknown here. An empty ring for all three would have read as "there is room",
which is the one thing none of them says.

**The denominator is the whole window, and that was nearly wrong.** Claude Code
compacts *before* the window is full: its indicator counts down to
`window − min(maxOutputTokens, 20 000) − 13 000`, which is plainly readable in
the binary. Three hand-readings of that indicator agreed, to within a point, with
a denominator of `0.92 × window`, and that number reached the prototype.

It was wrong. That threshold is compared against Claude Code's **own** token
estimate, which is not the sum this project reads out of `message.usage`: on one
compaction the two were 0.4% apart, on another sixty-fold. So the question went
to the files instead — at what value of *our* sum does a session actually get
compacted? Every auto-compaction in 18,622 transcripts, 236 of them, answers the
same way: **never above the window**, and up to 99.91% of it on a 1M model,
99.99% on a 200k one. Against a `0.92` denominator, ten of those compactions
print above 100%. `Scripts/measure-compaction.py` re-runs the whole thing in
under a minute, and `check-contract.sh` fails on any reading that exceeds its own
window.

**Discarded:** a number in the cell instead of a ring. `≥62%` is five glyphs
where the arc is none, and the column has twelve rows. **Discarded:** colouring
the arc by fullness — see above. **Discarded:** drawing the floor as *extra* arc.
It would invent tokens nobody counted; the paler ink says the same thing without
claiming a figure.

---

## D31 · A legend, and it counts

**Decided.** A `?` in the footer, and an entry in the menu, open a window that
says what the six colours and the two rings mean — with a live count of each
beside it, taken through the same renderer the column uses.

**Why now.** The panel started with three colours and needed no explanation. It
has six, two of which differ only in brightness, plus a ring that is not a state
and a second ring that is not a light. That is past what a stranger can infer,
and the project is about to be public.

**Why it also counts.** A key that only says "green means an unread answer" is
read once and never again. The same table with a number beside each row answers
the question people actually have — *how many are waiting for me?* — and that is
what makes it worth opening twice. The counts come from
`PanelController.currentRendering`, so a census and a column cannot disagree:
same renderer, same options, hidden projects left out of both.

**They are one family, and that took two tries.** The first version paired a
question mark in a circle, a bare gear and a pair of loose diagonal arrows: same
point size, nothing else in common. The arrows are two thin marks with no
bounding shape and their ink hangs to one corner, so beside two round outlines
they read as smaller, lower and unrelated — which is what "disordinato" meant.
All three are `.circle` variants now: 15 × 15, one silhouette, one weight. The
menu's is `ellipsis.circle` rather than `gearshape.circle` for two reasons that
agree — a gear inside a circle at twelve points comes out a grey blob beside a
crisp question mark, and this button opens the panel's **menu**, not a settings
pane. A hairline above the band says where the rows end; without it three glyphs
float on the same surface as the column and read as debris.

**Where the three glyphs sit.** The width control is on the left, centred in the
lights' own column; the legend and the menu are on the right, in the drag
handles'. Neither is a toolbar arrangement — each one lands in the column of the
thing it acts on, so the strip reads as the bottom of the grid rather than as a
bar bolted under it. At twelve points and in the timestamp's colour, because the
first version — nine points at 0.32 opacity — was reported as *"too small, and
really hard to see"*, which is what a control looks like when it is drawn as
a watermark. And the band is exactly as tall as a row, so the footer belongs to
the column's rhythm instead of interrupting it: measured on screen, the glyphs
have eight points of clear space above their ink and eight below.

**Discarded:** a popover off the footer. The panel never takes focus, and a
popover hung off a non-activating window cannot be scrolled, cannot be left open
beside the column, and cannot be found again once it has closed itself.
**Discarded:** opening it by itself on first run. It is the one moment a stranger
exists — and also the kind of thing that is presumptuous the second time. It
stays a door, not a greeting.

---

## D32 · The panel draws its own tooltips

**Decided.** `.help(…)` is not used anywhere inside the floating panel. A single
borderless window, reused, shows the text under the pointer after 450 ms and
takes itself away on a click, a scroll or the pointer leaving.

**Why.** AppKit's tooltips are put on screen by `NSToolTipManager`, which wants
the window under the pointer to be key and the application to be active. This
panel is neither, on purpose: it is a `nonactivatingPanel` that becomes key only
in the instant of a click, so that clicking a light never takes the focus from
the editor. Every `.help` on a row was therefore dead text — and the row's entire
second layer, the exact context figure, the model with its version, the folder
under a renamed row, the slot and its command, was written, tested, and never
once displayed. Found the only way it could be: reported by somebody hovering
and seeing nothing.

**What it shows.** Not a paragraph. `RowSummary` (Core) decides what appears, in
what order and under which word; `TooltipCard` draws it and decides nothing else.
The header carries the light's own colour and nothing else does — a tooltip with
a second palette would compete with the column it exists to explain. The context
gets the one bar on the card, because it is the one fact there that moves while
you work.

That split is the part worth keeping: the old builder lived in a `private var` on
a view, where no test in this project could call it. Fifteen cases now hold the
rules — including the two that would otherwise print something false: a reading
invalidated by a compaction must not show its tokens (`— 412,117 of 1,000,000`
reads as a figure with a typo in front of it), and the help line must not promise
a modifier that does nothing, which is why a session on another machine is not
offered a folder this Mac cannot open.

**What it must never do.** Take the focus, take a click, or outlive the thing it
explains. So: `ignoresMouseEvents`, `orderFrontRegardless` and never `makeKey`,
and a local event monitor that removes it on any mouse-down — because a
right-click opens the row's menu over the very row being explained, and
`.contextMenu` gives no notice that it did.

**Discarded:** making the panel key on hover, which would have taken the focus
from the editor every time the pointer crossed the column — the exact defect the
non-activating panel exists to prevent. **Discarded:** a SwiftUI popover, which
is clipped by a panel 240 points wide and 35 in the strip. **Discarded:** leaving
`.help` in place as well: two tooltips for one row, one of which almost never
appears, is worse than either.

---

## D33 · The folder appears under the pointer, and costs nothing at rest

**Decided.** Hovering a row reveals a small folder glyph between the timestamp
and the drag handle; clicking it opens a Finder window **inside** that folder —
`NSWorkspace.open`, not `activateFileViewerSelecting`, which reveals it selected
in its parent instead. You already know where the project is; you want to be in
it. ⇧+click does the
same without the glyph, and the row's menu carries "Show in Finder". None of the
three appears on a row that lives on another machine.

**Why not always visible.** Measured: the glyph and its spacing are 18 points,
taken off the name of every row for ever. The name is 100.87 points on a plain
row — it would go back to 82.87, which is exactly where it was this morning, when
`acme-os-platform` was reading `acme-…latform`. An action taken a few times a
day does not get permanent tenancy in the field that is short.

**What it costs instead, and this was said before it was built.** Under the
pointer the name shrinks by those same 18 points, so a long name re-truncates
while you are looking at it. That is a real defect and it was the argument
against this option; it is mitigated by a 120 ms ease rather than a jump, and it
only shows on names longer than 82 points. The alternative that costs nothing —
swapping the glyph in where the timestamp is — hides a fact under the pointer and
announces itself nowhere, which is worse.

**Why remote rows get nothing at all, not a disabled entry.** `/home/dev/.notes`
exists; it does not exist *here*. A greyed-out menu item is still a promise, and
an icon that is sometimes missing changes the width of the name — the same jump,
with worse timing.

**Discarded:** the tooltip as the place to put it. It ignores the mouse by
construction, which is what stops it from ever taking the focus; nothing in it
can be clicked, and that is a feature.


---

## D34 · One row shape for every harness; the card carries what it cannot say

**Decided.** A Codex session gets the same row as a Claude Code one: the same
dot with the same six meanings, the same ring meaning the same thing, the same
slot. What differs is not the drawing. It is **what the row is able to promise**,
and that is stated in the card rather than left to be discovered.

Four rules, and the fourth is the one the others exist for.

**The ring always means context occupancy.** Never a plan allowance, never a
second quantity borrowed into the same shape. Codex publishes
`rate_limits.primary.used_percent` beside its token count and it is a genuinely
useful number, but it is a fact about the *account*: every Codex row would carry
the same figure, and a reader who did not know that would read it as a property
of the row. It goes in the card, where a figure that exists for one harness and
not the other costs nothing.

**The letter in the ring stays the model.** `O`, `S`, `H` for Claude Code, `G`
for the GPT family. Two rows in one project are told apart at zero cost in
pixels, and the cell keeps the one job it has. `G` and not `5`: a digit in a
column of letters reads as a version number.

**A Codex row never turns red from silence.** Codex publishes no error event of
any kind — checked against the published event table, not assumed — so a failed
turn simply stops emitting hooks. Silence does not distinguish a crash from a
long thought, and painting a row red on that basis would be lying in the one
place lying is most expensive. `Harness.cannotReport` names it, and every
consumer that would otherwise infer a state has to consult it first.

**The card declares what the harness cannot say.** One line, on every row that
belongs to it: *Codex reports no failures: a turn that fails stops speaking*.
This is the rule the other three serve. A limit somebody is told is a limit; a
limit somebody meets by trusting a green row that was never going to turn red is
a defect with a good explanation.

**The divergence on `PermissionRequest`, which is deliberate.** D20 refuses to
register Claude Code's permission hook: the amber state already arrives through
`Notification`, which is passive, so sitting in the approval path would buy only
the text of the question. **Codex has no `Notification`.** Without
`PermissionRequest` a Codex session blocked on an approval is indistinguishable
from one that is thinking, and the panel loses the single state it exists to
show. So it is registered there and not here. The hook writes nothing to stdout,
which Codex's own documentation defines as declining to decide — the ordinary
approval prompt proceeds exactly as it would have. It reads; it does not answer.

**What it also buys, and what that says about D20.** Codex's `PermissionRequest`
carries `tool_name` and `tool_input`, so a Codex row can show `Bash: git push
origin main` where a Claude Code row shows only amber. That asymmetry is a
measurement, not an omission: the shipped Claude Code binary builds its
notification as `Claude needs your permission to use ${tool}` and carries no
`tool_input` at all, on a six-second timer that is cancelled if you answer first.
The command exists on that side too — only inside the hook D20 declines. D20 is
therefore unchanged and better understood: what it costs is the text, and the
text is worth less than the posture.

**Discarded: a harness glyph in the row.** A sixth element on twenty-four rows,
permanently, for a fact that changes about once a month. The model letter already
separates them and the card names them in full.

**Discarded: colour as the harness marker.** It would have cost nothing in space
and it fails the same accessibility test the panel is closing elsewhere: a
distinction only colour carries is not a distinction for everyone.

**Found by running it.** The five-second liveness sweep reads
`~/.claude/sessions`, where Claude Code drops one file per live process. Codex
keeps no such directory, so the sweep deleted every Codex row within five seconds
of the hook that created it — the row appeared in the log and was gone, with
nothing anywhere saying why. `reconcile` now carries the harness it speaks for
and prunes only what it can see. No unit test would have found that; the
end-to-end injection did, on the first try.
---

## D35 · A colour may be derived, and it says so

**Decided.** Every other row in this panel is **told** what it is: a hook fires,
says `Stop` or `UserPromptSubmit`, and the panel repeats what it was told. A
Claude Desktop conversation cannot be told about. It runs with a
`CLAUDE_CONFIG_DIR` of its own, inside the application's data, so the hooks
registered on this machine are not its hooks, and there is nowhere to put ours
that exists before the session does.

The alternative was to leave the surface out, which is what the README said for
months. What changed is a measurement, not an opinion: a **local** session writes
exactly the files every terminal session writes, and its transcript is the same
format this project already reads for timestamps and for context.

So the colour is **derived**, from the record the session writes about itself, and
three things follow.

**Two phases, because two are all the file can carry honestly.** The assistant
speaking in words is the end of a turn; a tool call, a result handed back or a
fresh prompt is the middle of one. A message that holds a sentence *and* a tool
call is running: a model routinely says what it is about to do and then does it,
and the tool call is the last thing it did.

**What it cannot see is said out loud.** A session stopped waiting for a
permission has not ended and no record marks the pause, so it reads as running.
That is the state this panel exists for, and this surface cannot give it. The row
never goes amber, `Harness.cannotReport` already exists for exactly this, and the
README says it in the table rather than in a footnote.

**A derived colour is dated, and only ever moves a row forward.** It is re-read
every five seconds, so without a date it would undo the click: clear a green row,
and the next sweep finds the same answer still at the end of the file and lights
it up again for something you have read. A hook satisfies this by existing, which
is why hooks never needed it.

**Rejected: inferring from the file's modification time.** Already tried on
another surface and already wrong — a transcript moves for plenty of reasons that
are not a turn, resuming among them, and after a reboot the whole column went
yellow at once.

## D36 · Presence is what a conversation leaves, not what a process is

**Decided.** A Claude Desktop row exists while its **conversation** does, and the
agent process has no say in it.

This overturns the first implementation, and the way it was wrong is the reason
the entry is here. The rule everywhere else in this panel is that a live process
proves a live session: a session file names a pid, `kill(pid, 0)` answers, and a
reused pid is caught by comparing start times. Applied here it produced a row that
appeared while the model worked and **disappeared at the end of the turn** — the
one moment the panel exists for.

The measurement: a Claude Desktop agent process lives exactly one turn. The
application starts it to answer and removes its session file when it exits. A
conversation whose last word landed at 22:44:38 left an empty `.claude/sessions`
directory stamped 22:44.

So presence comes from the pair the application keeps for itself — the index
beside each conversation, and the transcript — bounded by three gates that are all
the application's own answers rather than inferences of ours: a folder it resolved
as **local**, not archived, and active within `sessionStaleAfter`. Fifty-one
conversations sit on this machine going back to April; without the horizon every
one of them is a row.

The session file is still read. It just means what it honestly means: **a turn
running right now**, dated by the looking rather than by the transcript, because
it is not a record of anything.

**Rejected: a window of its own for this surface.** Twelve hours is what every
other row already obeys when it stops hearing news, and two numbers that must
agree are the drift a gate exists to catch.

**Revisited, 25 September 2026.** The application has a second name. Claude Code
2.1.281, started by it, writes `claude-desktop` into `CLAUDE_CODE_ENTRYPOINT` and
into the session file, where the surface had only ever been seen as `local-agent`.
Met on a session the application had opened on a node over ssh: the row arrived
through the hooks under the new name, the click compared it with the old one and
went down the editor path, and a remote row with no Remote-SSH window raises
nothing. Both spellings are the application now, asked through
`ClaudeDesktop.isEntrypoint` in the four places the name was compared — the click,
the deep-link rule, the desktop sweep, and "found rather than announced". A
desktop row on a node raises the application here, which is where the
conversation is. The name a surface goes by is read, not remembered.

---

## D37 · A workspace is a machine and a path, everywhere or nowhere

**Decided.** The key a row is grouped, ordered, named, hidden and muted by is the
**host and the path**, not the path.

`Workspace` had said this for months — `host` is part of its `Equatable` and its
`Hashable`, and its own comment explained that two machines can hold the same
path — and every caller that needed a key threw the host away and used
`workspace.path`. So a folder here and a folder on a node collapsed into one row,
in whichever state the more urgent member happened to be, and hiding one hid both.
A comment claiming an identity the code does not enforce is worse than no comment.

Two details are the whole design.

**A local key is the path and nothing else.** Every name, slot and hidden flag
anybody has saved is stored under that string, so keeping it byte-identical is
what makes this cost nobody their layout. There is no migration because there is
nothing to migrate.

**A remote key is the host, a colon, then the path.** The first spelling was
`//host` and the path, and it was quietly wrong: these keys pass through
`PathNormalizer.normalize`, which collapses every run of slashes, so the key that
went in was never the key that came back out and a renamed remote row lost its
name. A leading character that is not a slash cannot be a path, so the colon form
collides with nothing and survives being normalised.

## D38 · Amber means somebody is waiting, and Codex has to be asked who

**Decided.** A Codex permission request turns a row amber only when a **person**
answers it. When Codex routes approvals to its own reviewer, the row stays as it
was — yellow, working — because nobody is blocked and nothing should blink.

This qualifies D34 rather than contradicting it. D34 says a Codex row carries the
same six meanings as a Claude Code one; that was true of the drawing and false of
amber, which on Codex also lit up for requests nobody had to answer.

**What it cost before.** Codex publishes `PermissionRequest` for a tool call
whether a person or `auto_review` will approve it, and the event says nothing
about which. Amber lifts at `PostToolUse`, which arrives when the **command**
ends rather than when the approval lands, so an automatic approval left the row
blinking for the whole execution. Measured in one audit: **6.0 s, 6.4 s and
31.0 s**, plus 5.9 s and 3.4 s reproduced deliberately afterwards. The four
seconds of `awaitingNotificationDelay` were dimensioned against a comment saying
such a request is amber "for a few hundred milliseconds" — true only of an
instant command — so three of those also fired the notification the delay exists
to suppress.

**Where the answer comes from.** Not from the event: from the session's rollout,
whose path the event carries in `transcript_path`. The `turn_context` records
name `approvals_reviewer`, and it **changes during a session** — measured
switching from `user` to `auto_review` halfway through an audit — so it is read
per request rather than once. The reading is the shell's job: the reducer
receives a resolved fact and never a file path.

**Not knowing shows the request.** An unreadable rollout, a record not written
yet, a value nobody has seen before: all produce "cannot tell", and cannot tell
shows amber. A false amber costs a glance; a swallowed one costs a turn stopped
without anybody knowing, which is the failure this whole panel exists to prevent.
The format is undocumented and Codex calls it unstable, so `check-contract.sh`
now fails if a `turn_context` stops carrying the field — the correction goes red
instead of going quiet.

**What was rejected.** Waiting before showing amber, in either form. A fixed
delay does not work because the amber lasts as long as the command, not as long
as the approval: every threshold is passed by a command that runs longer than it,
and the 31-second case passes any threshold anybody would accept. And
`PreToolUse`, which looked like the natural signal to close on, arrives **88 ms
before** the request rather than after it — measured, after it had already been
registered for that purpose.

## D39 · Una riga si può togliere, e torna solo se dice qualcosa

**Decided.** The row menu has *Remove this row*. It takes one conversation off
the column immediately, without a dialog, and the row comes back the moment that
session shows a sign of life that is newer than the click.

**Why it is needed.** A row can outlive what it describes, and the machine cannot
tell. Measured here: a `claude` process still loaded nine hours after its chat tab
was closed — the extension keeps it so the tab can be reopened — and a Codex
daemon holding thirty-nine rollouts open, including conversations closed long
before. In both cases the panel is right that the conversation exists, and the
person is right that it is gone. **The existence of a tab is published nowhere**,
so no probe can settle it and no threshold can guess it.

**Not hiding, and not a mute.** Hiding is a lasting choice about a *project* and
collects it into the summary; muting silences notifications. This is one
conversation, and it is not a preference: it is a correction of what the column
says right now.

**The date is the mechanism, not the id.** A dismissal records *when*. A
discovered row is admitted again only on evidence newer than that moment —
because the sweep a second later offers the very same evidence, and letting it
through would undo the click on the next tick. This is the same shape as the
prune-restore oscillation that made the panel flicker in August, and it is
avoided the same way: by comparing against the moment rather than the identity.

**A signal outranks everything.** A hook fires because a turn moved, so it clears
the dismissal without any comparison of dates. The click said "this is not here
any more"; the session saying something is the row disagreeing, and the row wins.

**No confirmation.** It costs nothing to undo, and a dialog for something this
cheap teaches people to click through dialogs.

**And a second entry, which does end it.** *End this session…* asks first, and
the asking is the difference between the two: removing a row is undone by the
session saying anything, ending a process is undone by nothing. The question
names the process id, when it started and the folder, because "are you sure"
without a subject is a question nobody can answer.

It is offered **only where the process is provable**. Claude Code writes
`~/.claude/sessions/<pid>.json` with the session id beside the process id — the
only place on this machine where the two are stated together, since the process
holds no descriptor on its transcript and names nothing in its environment. Codex
has no equivalent, and that is a fact about Codex: its conversations are served
by one shared daemon, so ending it would end all of them. There the entry says so
rather than doing nothing quietly.

Two guards, and the second was nearly the end of the feature. Process ids are
reused and those files outlive what they describe — fifteen of them here, several
naming processes that had ended — so the start time on record must match what the
system reports, checked again **after** the confirmation because a process can go
in those seconds. And the file records that instant in **UTC** while `ps` answers
in local time: measured, every pair differed by exactly the offset of the zone, so
comparing the two strings never matched and the entry would have been invisible
for ever. A guard that can only fail is not a guard, it is a feature that does not
exist. `ps` is now asked with `TZ=UTC`.

`SIGTERM`, never `SIGKILL`: the session is asked to end and gets to save what it
was holding.

**The register is kept on disk**, because the reason a row was removed does not
end when the panel does: a tab closed this morning is still closed tomorrow.
Entries past `sessionStaleAfter` are dropped on the way in — beyond that the row
would have gone by itself, so keeping them could only hide a session somebody
wanted back. It is written when the register **changes**, in either direction, so
a session that came back does not find its dismissal waiting at the next restart.

**What it cost to get right.** The first version kept the register only in the
state, and the row came back three seconds after the click: `reconcile` runs on
every sweep and rebuilt the state without carrying it. The test written alongside
covered `upserting` and `removing` — the copies that were in mind — and not the
two that mattered. Every state built by hand in the reducer now carries the
register, and a test walks it through all four.

## How to add a decision here

When you make a non-obvious choice, write it down **before** implementing it,
with the alternatives you are discarding. If the implementation then proves you
wrong — as happened with D2 — rewrite the entry saying what you learned, instead
of deleting it. A decision overturned by a fact is more instructive than one that
was right first time.

---

## D40 · The panel has two homes, and the lamp in the menu bar is a surface of its own

**Decided.** The panel can live in one of two places: a window of its own, above
everything, staying where it was put — which is what it has always been and what
it still is by default — or under a lamp in the menu bar, opening and closing
from it like a menu. A lamp can sit in the menu bar in **either** case, and
whether it is there is a separate switch from where the panel lives.

**Why two switches and not one mode.** The obvious design is a single choice:
*floating* or *menu bar*. It is wrong for a reason that only shows up in use.
The panel floats above ordinary windows and below the system menus, which means
a full-screen editor covers it. Somebody who keeps the panel out all day still
loses it for the length of a full-screen session, and a lamp in the menu bar is
exactly the thing that survives that. Tying the lamp to the drop-down would have
told that person they cannot have it without giving up the panel they chose.

So: `PanelHome` says where the panel is; `showsMenuBarIcon` says whether the
lamp is there. One direction is forced and only one — a panel that lives in the
menu bar keeps its lamp, because nothing else could bring it back. The switch
that would strand it is refused, with the reason, rather than obeyed.

**Why the drop-down is not also always on top.** A drop-down closes when you
click elsewhere. That is what makes it a drop-down rather than a window that
happens to hang off an icon, and it is the whole of the difference between the
two homes: floating stays until you put it away, the menu bar goes away when you
look elsewhere. Everything else is identical — same view, same rendering, same
click on a row, same menus. Anything that behaved differently between the two
would be a second product to keep true.

**What the lamp draws, and why one lamp.** The menu bar is twenty-two points
tall and shared with every other application. Six lamps up there would be a
second column, worse than the first at everything the first is for, and spent out
of the scarcest space on the machine. So the lamp says the one thing a glance can
carry — the most urgent state the column is showing — with a number beside it
when more than one row is in that state, and the panel says the rest.

`idle` is drawn as a hollow monochrome ring rather than the column's dim red.
Dim red works among a dozen rows, where it reads as *this one is resting*; alone
beside the clock it reads as a fault. The ring follows the menu bar's own light
and says *nothing is happening* without claiming anything is wrong, and it is
the shape the lamp spends most of the day in.

**What makes it blink, and it is not what was asked for.** The request was red
and unseen green. The lamp blinks for **amber, green and red** — the three
states a click clears, which are exactly the three that mean *there is news here
nobody has taken in*. Leaving amber out would have made the lamp say less than
the column it stands for, on the one state that stops the work. Yellow and blue
never blink: a session merely working is the ordinary condition of this machine,
and a signal that is on for most of the day is not a signal.

*Don't blink* on a project silences the movement up here as well and not the
colour, which is the same thing it means on a row.

**Why the lamp reads the rendering and not the state.** Grouping, the
*only what's waiting* filter and the hidden set all change which rows a person
can see. A lamp computed from `TrafficLightState` would answer for rows the
column is not showing, and then the two disagree — with the one that is wrong
being the one that has no room to explain itself. So `MenuBarSummary.of` takes
the `ColumnRendering` the panel is drawing. Hidden rows count, for D4's reason:
a hidden project is not a forgotten one.

**Alternatives.** A menu bar *only* application, with no floating panel: that is
the competitor's shape, and it throws away the property this project was built
on — a column you do not have to open. A second window instead of moving the
one: two columns that can disagree. Six small lamps in the bar: measured against
the space available and rejected above.

**The lamp cannot be dragged out of the bar.** macOS offers `.removalAllowed`,
which lets somebody command-drag a status item away, and it was set in the first
draft. It is the same stranding the *Hide this lamp* entry refuses — a panel
living up there with nothing left to open it — reachable by a gesture that gives
no warning and asks nothing. Hiding it has a door, and that door knows when to
say no; a drag does not.

**The cost, stated.** A drop-down cannot be always on top, so in that home the
panel is gone whenever you look away, and getting to a row is two gestures rather
than none. That is the trade somebody makes by choosing it, and the footer button
makes it one click to change their mind.


## D41 · A home you cannot be brought back from is not a home

**Decided.** The panel may live in the menu bar only while something can open it,
and the application itself is now always that something: starting LampBoard when
it is already running puts the panel on screen, whatever home it is in. On top of
that, a panel in the menu bar checks that its lamp was actually drawn, and comes
back to its own window — saying why — when it was not.

**What made this necessary.** D40 already refuses the switch that would strand
the panel (*Hide this lamp*, greyed while the panel lives up there) and refuses
the drag that would do it silently (`.removalAllowed` off). Both defend against a
person removing the lamp. Neither defends against **macOS never drawing it**, and
that is not hypothetical: a full menu bar accepts a status item, reports it
visible, hands out a frame, and draws nothing. The panel then exists, answers on
its port, and cannot be reached by any gesture anybody knows. Reported from use
as *it doesn't start any more*, which was the only fair reading. The measurement
is in [07-traps.md](07-traps.md#the-status-item-the-system-agreed-to-and-never-drew).

**Why the reopen is the primary fix and the check is the secondary one.** The
check is a judgement about geometry that can be wrong in both directions: on a
screen with no notch the system offers nothing to compare against, and a rule
that guessed there would be moving panels on a hunch. Starting the application
again cannot be wrong. It is also what somebody who cannot see the panel actually
does — the gesture was already being made, twice, three times, and until now
nothing was listening.

**Why the check still exists.** Without it the panel comes back only for as long
as the person keeps summoning it: the next login puts it behind the same absent
lamp. A home is a place you are returned to, so the state is corrected rather
than worked around, and it is written to the preferences so the correction
outlives the run.

**Why an alert and not a quiet correction.** The user chose that home. Moving the
panel out of it without a word would be the app disagreeing with them in silence,
and the next thing they would do is put it back — into the same trap. The alert
says what happened and that the lamp stays switched on, so it returns of its own
accord when the bar has room.

**Alternatives.** Refusing the menu bar home when the bar is full, at the moment
somebody chooses it: it reads as the feature being broken, and the bar's fullness
changes through the day. Falling back silently: see above. A command-line escape
hatch (`lampboard panel floating`): a real door, and a poor primary one — somebody
who thinks the app will not start does not open a terminal. Worth adding beside
these, not instead of them.


## D42 · The published address does not carry a version

**Decided.** Every release publishes two disk images: `LampBoard-<version>.dmg`,
and a byte-for-byte copy called `LampBoard.dmg`. The copy exists so that

```
https://github.com/marmyx77/lampboard/releases/latest/download/LampBoard.dmg
```

is an address nobody ever has to edit. It is what the site's download button
points at, and what anything fetching on a schedule should use.

**What is wrong with a link that names a release.** It is correct on the day it
is written and wrong at the next one — while still answering `200`, because the
old asset stays where it was. Nothing breaks loudly: the button works, the file
downloads, it installs, and it is the previous build. Nobody reports it, because
nobody who already has the app ever clicks it. The site was gated against this
already (the stamp, and a rule that refuses a page naming any other version) but
the gate only runs when somebody releases the web half, and a person who forgets
that step gets exactly the silent failure above.

Asked for from outside, which is what settled it: the fleet manager deploying
this to other people's Macs polls an address periodically, and a versioned one
would pin it to 0.2.9 for ever with no error anywhere.

**What the site gives up.** The page no longer states, in its link, which file it
hands you; the version is on the label beside it. That trade is the right way
round: with a version-free link, the thing that can go stale is a **label**,
which is visible, and the thing that cannot is the **download**. Before, it was
the other way about.

**Why a copy and not a rename.** The versioned name is what a person downloading
by hand should end up with in `~/Downloads`, and it is what the update feed
fetches — everything the app says afterwards about an update names the file it
went for, and `LampBoard.dmg` names no version at all. So both exist, and
`ReleaseFeed` picks the versioned one deliberately rather than taking whichever
GitHub happens to list first.

**Why the copy is made last.** After notarization and stapling. A copy taken
earlier would be an unstapled image wearing a trusted name — refused on a Mac
that has never seen it, in the one channel where nobody is watching the output.

**What keeps it true.** A rule in `_release/check.py`: the newest release carries
those names, each address answers 200, and the bytes each serves are the size the
release published under it. Without it, forgetting one asset once turns an address
into a 404 for every machine polling it and for nobody else.

**And a package, for the same address and a different reason.** A disk image is a
disk image: the format has no version field anywhere in it. A person mounting one
does not care; a fleet manager does, because it has to answer *is the copy on that
Mac older than this* before it sends anything, and with nothing to read the
administrator types the number by hand — high means update commands that never
stop, low means updates that never start. A package carries `identifier` and
`version` in its own metadata, which is what gets read.

So a release publishes four files: the disk image and the package, each under its
version and each under a version-free name. `Scripts/make-pkg.sh` wraps the
bundle `release.sh` has already stapled — never one of its own, because wrapping
an unstapled application produces something that installs and then refuses to
open, in the one channel where nobody is watching. It signs with a **Developer ID
Installer** certificate, which is a different certificate from the one that signs
the app, and it refuses to produce an unsigned package: the disk image has a use
unsigned, for a tester who knows how to answer Gatekeeper, and this has none.

No install scripts in it, and that is a decision too. The hooks live in each
person's own `~/.claude/settings.json`; a package runs as root with nobody's
session around it, and one that wrote into a home directory it guessed would be
writing into the wrong one on any Mac with two accounts. The application asks on
first launch, which is where somebody is there to answer.


## D43 · The panel is dark on a Mac set to either

**Decided.** The panel and its card are drawn in the dark appearance whatever the
Mac is set to. Settings, the legend and the conversation window follow the system
like any other window.

**What happened.** Reported from use, on a Mac in light mode: *black on grey,
unreadable*. It was not a small miss. Half the surface is written for a dark
ground and cannot follow a light one — the hover wash and the block edges are
white at low opacity, the material is `.hudWindow`, and every lamp hue was chosen
and measured against that. The other half — names, timestamps, badges — is
`Color.primary`, which does follow. So the two halves disagreed, and what broke
was the one thing the column exists for: reading which project is which.

Measured on two photographs of the same panel, before and after: a project's name
against its own background, **4.5:1** following the system and **6.8:1** held
dark. The ratio flatters the first number — it compares the darkest pixel of a
stem with the commonest pixel of the background, and most of a twelve-point glyph
over a translucent surface sits nearer the middle — but it is the right
direction, and the second is what everything here was tuned against.

**The alternative, and why not now.** A real light theme: new hues, a glow that
survives on white, every overlay inverted, the lamps re-measured against a pale
ground. That is a design pass with somebody's taste in the loop, not a switch,
and it would double what has to be kept true — two palettes, two sets of
screenshots, two things to check on every change. It stays available and it is
not what this defect asked for.

**Why holding it dark is not a workaround.** The panel is an instrument that sits
on top of the work, like the dashboard of a car, which is dark whatever the
weather outside. It is what this has been drawn, measured and photographed as
since the first day, and the README's pictures have never shown anything else.

**Where it stops.** Two surfaces, named explicitly: the panel and its tooltip.
Settings and the legend are ordinary windows full of ordinary controls, built from
semantic colours and system materials, and a person's Mac should decide how those
look. The menu on the lamp is a menu bar menu and follows the menu bar.


## D44 · A row stands for a conversation, not for a process

**Decided.** A session earns a line in the column when it has a conversation on
disk. A `claude` process that has never said anything does not, at either door:
neither the `SessionStart` hook that announces it, nor the adoption pass that
finds its file in `~/.claude/sessions`. Every other hook still creates a row on
its own, because every other hook reports something that happened.

**What happened.** Reported from use: a project showed two conversations where
the editor had one, one of them named as if it were a conversation of the
person's own. Both processes were alive. VS Code had started a second `claude`
twenty-three seconds after the first, when the session was restarted, and never
killed the first. Measured on that machine at that moment: six `claude`
processes alive, one of them for thirteen days, and exactly one with no
transcript anywhere on the disk — the row that had been reported.

The panel was not inventing anything. It was answering a question nobody asks:
*which processes are running*. The question it exists to answer is *what are my
agents doing*, and a process with no conversation is doing nothing and never
will.

**Why the transcript and not the process.** It is the only evidence that
distinguishes them, and it is the right one on its own terms: the transcript
**is** the conversation. Everything a row shows — the state, the last message,
how much context is left, what a click opens — comes from it. A row without one
is a row where every field is empty.

**Why the search and not the derived path.** `TranscriptLocator` derives where a
transcript would be, and is right 7065 times out of 7066. The exception is a
session in a **git worktree**, which reports the main repository as its `cwd`
while Claude Code files the transcript under the worktree. Refusing a row on
"nothing at the derived path" would make every worktree session vanish, and this
project is worked on in worktrees. So the derived path is the fast answer and a
search by session id across the project folders settles it: measured here, 74
folders, 11,788 transcripts, 2 ms, and it runs only where the derivation missed.
When the folder cannot be listed at all the answer is *yes*, because not being
able to look is not evidence of silence.

**The cost, stated.** A **new** session writes its transcript at its first turn,
not when it starts — measured on one here, 101.8 seconds later, which was the
time somebody took to type. So a session opened and not yet spoken to has no
row, and gets one the moment it is used. A resumed session is unaffected: its
conversation is on disk before it announces itself.

**The alternative, and why not.** Admit the row on `SessionStart` and prune it
after some number of minutes if it is still empty. It keeps the row for a
freshly opened tab, and it pays for that with a row that appears and then
vanishes while somebody is looking at the session it belongs to, which reads as
a fault. A row that has not appeared yet reads as a rule, and it is one that can
be said in a sentence.

## D45 · A figure about the account does not sit on a row

The allowance — the five-hour window, the week, one model's own weekly cap — is a
property of the account. Every other number in this panel belongs to a session:
the colour, the context ring, the model letter, the slot.

Putting the allowance on each row would state one fact six times, and six copies
of one fact read as six facts: a column of rows each showing "36%" invites the
reading that *this* conversation has spent 36% of something. It has not. So the
allowance is drawn **once**, at the foot of the column, in **bars** rather than
rings — because the ring is already spoken for here, and a second ring a few
points below meaning something else would read as the same measurement about a
different subject.

**One line per account, and it shows the session limit.** Not all three limits —
the first version drew four lines per account, eight for somebody signed into two,
and buried the column it was meant to annotate: with seven projects open, three
went off the bottom of the panel. And not "whichever is highest", which was the
second version and was arbitrary: a weekly figure at 32% is not news, and showing
it instead of the five-hour window meant the one number a person can act on kept
disappearing behind one they cannot.

The line is **the session window, its percentage, and how long until it resets**,
in the same twelve-point rounded face the project names use. That is the pair of
facts somebody acts on: whether to start another turn now, and when it becomes
free again. The exception is a limit that is genuinely spent — above 90% — which
becomes the binding one, because a session window resetting in forty minutes buys
nothing if the week is gone. Everything else is in the tooltip, exactly as it is
for a project row.

Both of those were corrections made after looking at the running panel, and both
had passed a review that checked the figures instead of the picture. A number that
is right and unreadable has not been shown.

**The bar carries the lamps' own three hues** — green below forty, yellow to
seventy-five, red above. The first version was monochrome, on the reasoning that
the state colours belong to the lamps and a second use of them would borrow a word
already taken. That was over-careful: the grammar is already learned a foot up the
panel, and inventing a second one for the same idea asks somebody to hold two.

What keeps the lamps first is **volume, not palette**: five points of bar at
eighty-five percent opacity against a saturated disc of thirteen. The bar is the
only long horizontal thing here, so it reads without ever being the brightest.

**The hover is a card, not a sentence.** It was `.help(…)` to begin with, which in
this panel shows *nothing at all* — the window is never key, and `Tooltip` says so
in as many words, which is what made the other two limits unreachable. It now uses
the panel's own tooltip, drawn as `AllowanceCard`: the same monospaced labels, the
same aligned grid and the same bars as a project's card, because the two appear in
the same place a second apart and a second layout would read as a second
application.

## D46 · A borrowed credential is used, never renewed

The allowance figures need Claude Code's OAuth token, which sits in the login
keychain. Measured on 20 September 2026: the access token lives **eight hours**
and Claude Code rotates it there; the refresh token beside it lasts about four
weeks. Both are readable through `/usr/bin/security`, the tool Claude Code writes
the item with, which the item's access list trusts. (This entry used to say the
item carried no access-control list and that an ad-hoc binary read it without a
dialog. The dump says otherwise, and D52 records what that cost.)

So renewing the token ourselves would be easy, and it is forbidden. Refresh tokens
are commonly rotated when spent: minting a new access token with Claude Code's
refresh token could invalidate the copy Claude Code holds and **sign the person
out of the tool this panel exists to watch**. A widget that logs you out of your
editor is not a trade anybody would accept, and the failure would look like Claude
Code's fault rather than ours.

The rule is enforced by absence rather than by discipline. `ClaudeCredentials`
exposes one function, and it returns the access token; there is no function in the
codebase that reads the refresh token. A capability that does not exist is a
stronger guarantee than a comment asking nobody to use one.

The consequence is deliberate and visible: with no Claude Code session in eight
hours the token expires, the answer is a 401, and the strip goes quiet with a
sentence saying it is waiting for Claude Code to refresh its sign-in. That is
exactly the stretch in which nobody is spending any allowance.

## D47 · An allowance is never drawn without saying whose it is

The allowance strip was built reading this machine's credentials and drawing one
set of bars. The assumption underneath it — that a person has one Claude account —
was never stated, and it is wrong.

Measured on 20 September 2026, on the two machines this project is developed
across: this Mac is signed in as an **organization** account on a Team plan, and
the node the tunnel reaches as a **personal** one on a Max plan. Two accounts, two allowances, two different
*sizes* of allowance — and about nine tenths of the work happens on the second one.

One unlabelled bar reading "36%" in that situation is not an incomplete feature, it
is a **wrong** one. It invites the reading that this is your remaining room, while
the sessions actually spending a different account's allowance sit a few points
above it in the same column. The panel's whole claim is that a glance tells you the
truth; a figure that quietly describes a tenth of your work breaks that claim more
thoroughly than showing nothing would.

So: one group of bars per account, each named, and the nodes are asked as well as
this Mac. The name appears only when there is more than one account, because with a
single one the address is a line of text telling the person what they already know.

**Two machines on one account draw one group.** Matched on the account uuid, never
on the address — the address can be absent, and the uuid is what the answer is
keyed on. When neither side can prove its identity the groups stay separate:
drawing one allowance twice is a smaller failure than hiding a second one, which is
the failure this decision exists to undo.

**The node is asked on the node.** The request is made over there and only the
answer — three percentages — crosses the wire. Fetching the token back would put a
credential in this app's memory, and in whatever ssh buffered, for the sake of
decoration. The node already has the credential and a network.

## D48 · A launch repairs the hooks addressed to it, and nothing else

**Decided.** At every launch, once the token is settled and before the server
answers, the app reads its own registrations — the native headers in
`settings.json` and the text of the script — and rewrites both when either lacks
the current token. Only an installation **addressed to this instance** is touched:
the port in the native URLs, or in the script's target when there are none, has to
be this instance's own. And it is a repair, not an installation: the events that
were registered stay registered, and message delivery stays as it was.

**Why.** Requiring a token on `POST /signal` cannot wait on people reinstalling.
Hooks written by 0.4.0 carry none; they sit in `settings.json` until somebody
happens to run the installer again, and "require it a release later" is a hope
about other people's habits. The app knows the token, knows which entries are its
own, and one file write nobody sees finishes the migration. The script matters as
much as the headers: `SessionStart`, `SessionEnd` and `Stop` run it, and `Stop` is
what turns a row green.

**What the first version got wrong, and how it was found.** It reinstalled at its
own port with a fresh installation's defaults. The end-to-end run has a case that
starts the bare binary on another port against the shared home; under a deliberate
mutation that left the script without a token, that instance judged the script
stale, rewrote every hook to post to *itself*, and exited — and the two cases after
it that run the script posted into the void. It read as a test problem for an
afternoon. It was the repair taking over an installation that was not its to take.
The same code would have dropped `PreToolUse` and the message listener from anybody
who had them and, run before the token store, it read a burned token on the very
launch that regenerated it. Three defects, one rule missing: *whose installation is
this?*

**Discarded.** Repairing whatever is found, at the launching instance's port: that
is the takeover above. Requiring the token without a repair: every row dark on
every machine that had not reinstalled, with nothing on screen to say why. Marking
our entries in the user's file so as to recognise them: the recogniser stays
structural, as the uninstaller's is, and the port is read off the hooks the same
way.

**The node, and the previous name.** The first version reached neither. A node's
hooks are written over ssh, and bringing them up to date was left to a person
pressing "Install" on every node they own — which works for the one machine its
author remembers and for nobody else's. Now every check the fleet runs — at
launch, when a host is added, when a tunnel comes back up after failing — judges
the node's hooks by this same rule (`HookRepair`, shared with the local installer)
and rewrites them when they are stale, through the scripts that already make a
dated backup and refuse to write over a file that changed. And "ours" includes the
script path the project had before it was renamed: found on the node this panel
watches on 20 September 2026, nine command hooks under `.clawd-light`, alive and
posting through the tunnel with the old host header, that a rule knowing only the
current name read as *nothing installed*. Every node set up before the rename is
in that state, and so is every Mac that upgraded across it without reinstalling;
the migration removes those registrations as it writes the current ones, and the
event added since comes along.

**A near miss, caught by a domain case.** The message listener was detected with
`isInstalled`, which also claims the native hooks — so every native installation
read as having delivery on, and the repair would have registered the mailbox for
people who had never turned it on: the one feature that lets a process on the
machine start a turn in the person's voice (D15). Detection is by exact command
path now, and the case that found it stays as the regression.

**Verified without touching the node.** A domain case rehearses the whole remote
repair through the real Python scripts against a home laid out like the node —
inspect, judge, merge, apply, inspect again — and `lampboard remote check`, which
is read-only, reports the verdict the panel will act on. The write happens at the
panel's next connection.

## D49 · Native hooks are a capability read from Claude Code, not assumed

**Decided.** Before writing an `http` hook the installer reads which Claude Code
is installed — the native installer's `~/.local/bin/claude` link is named after
its version, and `claude --version`, run with a deadline from the places a binary
lives, is the fallback — and below **2.1.63**, the release whose changelog added
the type, every event goes on the script instead. Locally, in the launch repair,
and on a node, where the inspection reports the version and the same rule decides.
`install-hooks`, `status` and `remote check` say what was found and what it meant.

**Why.** The migration to native hooks was measured on 2.1.268 and shipped in
0.4.0 without asking what version anybody else had. On an older Claude Code the
`http` entries are unknown to it, and the panel hears at best the three events
that still run the script: a column gone quiet for every person pinned on an old
release, with nothing anywhere to say why. "Claude Code updates itself" is true
and is not a reason to write a configuration a copy cannot run.

**Unknown fails open.** A version that cannot be read is taken as current. The
people on an old release are few; the people whose `claude` sits somewhere the
reader did not look would be everybody else, and a rule that failed closed would
put all of them back on a process per event for the sake of a lookup. `status`
says "not found, taken as current" in those words, so the assumption is visible.

**Not measured.** What an older Claude Code does with an entry of a type it does
not know — ignore it, or refuse the whole file — was not observed; no such binary
was at hand. The rule does not depend on the answer: either way those events do
not arrive, and either way the script does.

## D50 · The update check follows a redirect, not the API

**Decided.** The check sends a `HEAD` to the address that never changes,
`…/releases/latest/download/LampBoard.dmg`, with redirects **not** followed, and
reads the newest release's version out of the `Location` GitHub answers with. The
target has to sit under this project's own download prefix or the answer is
refused; a version that cannot be read is no offer. The REST API is asked only
when no redirect came back at all — never when one came back and was refused.

**Why.** The API answers anonymous callers sixty times an hour **per public
address**, and its own headers say so: `x-ratelimit-limit: 60`. An office sits
behind one address, so every panel in it and every other tool asking GitHub
without a token — Homebrew, editor extensions, other updaters — spends the same
sixty. On 21 September 2026 the colleagues behind one router read "GitHub is
rate-limiting anonymous requests: try again later" while the person on another
network was offered the update, and the sentence was true, useless, and pointed at
the wrong cause: nobody was asking too often, everybody was asking from the same
place. The download address carries no such quota — it is what the site's button
and every fleet manager already poll — and the version it redirects to is the same
fact the API would have stated.

**What stays.** The pinning: a redirect anywhere but under
`github.com/marmyx77/lampboard/releases/download/` is refused, as an API asset
pointing elsewhere was. Drafts and pre-releases need no rule here, because
GitHub's `latest` skips both by definition. And the API parser stays, as the
fallback, because a corporate proxy that swallows redirects is a thing that
exists.

**Discarded.** A token in the app to raise the quota: a secret shipped to every
Mac is not a secret. Asking the site instead of GitHub: the site is stamped from
GitHub and would only add a hop to the same fact, and D42 already says the
published address is the one that never changes.

## D51 · A remote row is homed on the node's window, not on the hook's `cwd`

**Decided.** The probe that reads a node's live sessions also reads its editor
lock files — `~/.claude/ide/*.lock`, written there by the Remote-SSH extension,
judged alive there because the pid means nothing anywhere else — and a remote
row's folder is the window whose folder contains the session's `cwd`, resolved by
the same function that resolves a local row against this Mac's locks. Failing a
window, the folder the session's own file names, written once at start; failing
that, the `cwd`, which is what every remote row had before. A row that spoke
before its host had ever answered is **moved** when the answer comes, colour and
history untouched.

**Why.** A hook's `cwd` follows every `cd` the session makes. Found on 21
September 2026: a session started in `simlab` whose Claude had stepped into
`simlab/experiment` reported the second in every hook, the row was called
"experiment", the window was called `simlab [SSH: devmachine]`, and the
click found nothing to raise. The session beside it worked because it had never
left its root. Locally this never showed, because the local resolver has always
folded a `cwd` into the window that contains it; remotely there was nothing to
fold it into, and the row took whatever the last hook said.

**Why the node's locks and not a guess.** The name the click needs is the one in
the window's title, and the window's folder is the one fact the extension writes
down. Trimming the `cwd` to some ancestor would be a guess about how deep a
project is; the lock file is the answer. It is also the same evidence, read the
same way, as on this Mac (D37: a workspace is a machine and a path).

**Visible.** `lampboard remote check <host>` prints the editor windows the probe
sees over there, so a row named after a subfolder can be read against the list.

## D52 · The credential is read through the tool that writes it

**Decided.** The allowance reader gets Claude Code's access token by running
`/usr/bin/security find-generic-password` and parsing what it prints, not by
calling the Security framework from this process.

**Why.** The first version called `SecItemCopyMatching`, and macOS put up
"LampBoard wants to access the key 'Claude Code-credentials'" — with a password
field — at every launch. *Allow* covers the running process only. *Always Allow*
adds the application **at its path** to the item's access list: pressed on the
build in `dist/`, it did nothing for the copy in `/Applications`, and a person who
updated four times in one day saw the dialog four times, each time for the same
feature. Read on 22 September 2026 with `security dump-keychain -a`: the item's
decrypt entry trusts exactly two programs — `/usr/bin/security`, because Claude
Code writes the item through it, and whichever copy of this app somebody had once
pressed *Always* for — plus a partition entry for Apple's tools. The tool is
trusted for as long as Claude Code keeps writing through it, whatever this app is
called, wherever it lives, whichever version it is; a read through it asks nobody
anything, and needs nobody to press *Always*.

**What it does not change.** The token is still borrowed and never renewed (D46);
the parser still reads the access token and nothing else out of the blob; the
strip still goes quiet on a 401 rather than minting anything. One process spawn
per read, every two and a half minutes while the switch is on, is the price, and it
is the same tool Claude Code itself spawns for the same purpose.

**Corrects D46.** That entry said the item carried no access-control list and that
an ad-hoc binary read it with no consent dialog. Either the measurement went
through `security` without anybody noticing, or it was wrong. It was believed for
two days and cost a dialog per launch to everybody who turned the strip on.

## D53 · The application's accounts are read from the processes that spend them

**Decided.** Besides the keychain on this Mac and the credentials file on each
node, the allowance strip reads the accounts the Claude application runs Claude
Code as. It finds them in the environment of the running Claude Code processes —
`CLAUDE_CODE_OAUTH_TOKEN`, on processes carrying `CLAUDE_CODE_ENTRYPOINT` — on this
Mac through `ps -Eww`, and on each node, on the node, through `/proc/<pid>/environ`.
For each account it asks the usage endpoint and the profile endpoint, which names
the account, and draws one line like any other.

**Why.** The application signs the Claude Code it starts in as **its own**
account, and hands the credential over in the environment and nowhere else.
Measured on 26 September 2026: the application's sessions ran over ssh on the node
as a Team account, the node's credentials file held a different one, and the
strip drew that one and nothing of the account actually being spent that morning.
The processes are the only place that account exists outside the application's
own encrypted store — and reading that store would mean decrypting another
application's secrets with a key whose keychain entry trusts only that
application, which is the dialog of D52 again and a line this panel does not
cross.

**The boundaries.** Only processes of the same user, which is all the operating
system shows anyway; only Claude Code's, so that a token some other program
happens to carry is never asked about; each account once; at most four. The token
is borrowed exactly as in D46: read at each poll, used for two GETs, never kept,
never renewed — and there is no refresh token in that environment to be tempted
by. On a node the request is made there and only the answer crosses the tunnel,
as for the node's own account. No application session running means nothing
found and nothing said.

**Also.** The node's script now hands every token to curl on its standard input
(`--header @-`) instead of its command line: an argument is readable by every user
of a machine, an input is not. That was true of the node's own token before this
change as well.

## D54 · One answer per account, and a 429 keeps what was read

**Decided.** Every account is asked about once a round, and only until one of its
tokens answers: this Mac is asked first, then the application's sessions here,
then each node is told which accounts are already in hand and skips them — its own
sign-in and any hosted token of an account that has answered. A token that is
**refused** does not count, and the next token of the same account is tried. The
account a hosted token belongs to is asked once and remembered, on the Mac in
memory and on a node in `~/.cache/lampboard/accounts.json`, both keyed by a hash of
the token and never by the token.

When anything is answered 429 the strip keeps the last reading of each account on
screen, with its own age, for up to half an hour, and the next ask waits twice as
long as the last, up to twenty minutes. The first ordinary answer restores the
ordinary interval.

**Why.** Measured on 29 September 2026: the node was signed in on its command line
as the same account the application's sessions ran as there, so each round asked
for it twice, and the usage endpoint — asked as well by Claude Code itself and by
the application — answered 429. The strip then went empty and said so, throwing
away a reading two minutes old to show nothing. The same morning showed that the
limit is kept **per token**: the node's own token, which its Claude Code sessions
ask with, was refused while the application's token for the same account was
answered — hence "until one answers" rather than "once".

**Also.** The ssh runner learnt that ssh had exited from `waitUntilExit()` on a
global-queue thread, after reading both pipes to end-of-file. It hung there for the
full fifteen-second deadline on a process that had finished in one second, about
every other time and more often the larger the answer — so the node's allowance
line, and potentially its sessions, went missing without a word. The exit is now
learnt from a termination handler set before the launch, in the ssh runner and in
`Command.run` alike.

## D55 · A window opened through a link hosts the sessions under its target

**Decided.** When the local editor windows are read, each folder is also resolved
on disk (`realpath`), and a session whose `cwd` falls under either spelling belongs
to that window. The row keeps the window's spelling.

**Why.** The window's folders are what the editor was asked to open, and a folder
opened through a symbolic link keeps the link's name; the session's `cwd` is the
process's working directory, which the kernel hands back resolved. Measured on 29
September 2026: a window on `~/Development/livenotes`, a link to
`~/Development/voicedesk`, hosted a session reporting `voicedesk`. Nothing matched, the
session fell back to being a terminal row, and clicking it raised nothing for five
days. The window's spelling is kept because it is the name in the title the click
looks for.

**Cost.** One `realpath` per open folder per window read, done where the windows
are read and not on every signal; the pure resolver compares strings as before.

## D56 · Whose a token is, is asked of the token

**Decided.** The account a line is labelled with — and the account the nodes are
told is already in hand — comes from the profile endpoint, asked with the very
token the figures were asked with, once per token and remembered by a hash of it
(in memory on the Mac, in `~/.cache/lampboard/accounts.json` on a node).
`~/.claude.json` is no longer read for it, on either side.

**Why.** That file names the account of the last sign-in any Claude Code on the
machine went through; the keychain holds the token of whichever sign-in wrote it.
Measured on 30 September 2026: the Mac's file said the organization account, the
keychain's token was the personal one. The strip drew the personal account's
figures under the organization's address — identical to the node's line, which was
really the personal account — and told the node it already had the organization's
account, so the node skipped the only tokens that were it: the Claude
application's. A label that can be wrong about which allowance it shows is worse
than no label, and the token cannot be wrong about itself.

**Cost.** One profile request per token, which the application and Claude Code
renew every few hours; nothing per poll.

## D57 · The application's worktree rows are named after their project

**Decided.** A row whose session the Claude application runs inside a linked
worktree reads as the main repository and the worktree, without the worktree's
numeric tail: `Ledger · vigilant-ramanujan`. A name given to the row still wins.
Editor rows are left alone.

**Why.** The application can give each conversation its own worktree, created
under `.claude/worktrees/` with a generated name on a `claude/` branch of the same
name. Named after its folder like every row, the conversation on the `Ledger`
repository read `vigilant-ramanujan-790712` (30 September 2026): a name nobody
chose, saying nothing about the project, and one more of them for every
conversation. The repository name was already known — the card said "a linked
worktree; the name is the main repository's" — it just was not the row's name.
Editor rows keep the folder because their name is the title of the window they
raise, and a row that disagreed with its window would read as a different place.

## D58 · LampMaster notices for free and thinks once an hour

**Decided.** LampBoard gets a director, LampMaster, that reads every session and
suggests at most three things an hour: one session knows what another needs,
something waits or is stuck, two sessions overlap, work is done and can be
closed, a problem was solved before somewhere else. What can be told from data
the panel already has is told by rules, at no cost, and shown at once; a real
model (Opus) reads the whole picture once an hour, through `claude -p` with
everything of the user's own setup switched off. Every suggestion quotes the
picture word for word or is dropped before it is shown. LampMaster proposes; the
user acts.

**Why.** Measured on 4 October 2026 against the sessions of the one person using
it, read-only. A plain `claude -p` asked to answer "ok" wrote **268,908 tokens**
to the cache, nearly all of them the user's MCP connectors; with
`--tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands`,
hooks disabled and no session persistence, the same call costs 689. A whole
round over eight conversations was then about 7,000 tokens and 17 seconds with
Opus, and it found what no single session can see: a build waiting for an
"install" for 106 minutes, while another session showed the old version still
running and a third had merged work the build had to contain. Sonnet found the
first and missed the connection. Without the hooks switched off the round would
have shown up as a session in the panel itself.

The validator is there because the prototype's best property — it invented
nothing — was a hope; here it is a check.

## D59 · The round reads its frame from standard input, and skips for free

**Decided.** The round's frame goes to `claude -p` on standard input; the command
line holds only what is the same for every user. Before any token is spent the
round is skipped when LampMaster is switched off, when no session is worth a
look, when the frame says what it said at the last round, and when the day's
200,000 tokens are spent — in that order. A round that failed counts as a run.

**Why.** The frame carries pieces of the user's conversations, and the arguments
of a process can be read by any other process on the Mac with `ps`; standard
input cannot. The prototype passed the frame as an argument, which was fine for
one person reading their own sessions and is not for an application. Measured on
4 October 2026 on the test Mac, the exact arguments of `LampMasterCommand` with
the frame piped in: answer in the schema, 1.9 s, 1,483 tokens, two turns.

The digest that decides "unchanged" leaves out the minutes since each session's
last activity: they change every minute and say nothing new until a threshold is
crossed, and then a signal appears, which the digest does include. Without that,
a quiet evening would buy twelve identical answers. A failed round counts as a
run because otherwise a broken `claude` — logged out, an unknown flag — would be
called again at every tick of the timer.

## D60 · LampMaster is off until it is switched on

**Decided.** LampMaster's round does not run until the user switches it on. Once
on, it looks at this Mac's Claude Code conversations — the panel's rows and the
transcripts closed in the last week — every hour, and at nothing else until the
nodes' stage. Its state and a request for a round are on the local server, behind
the token; the request answers at once and the round runs on its own, one at a
time.

**Why.** A round sends pieces of the user's conversations to Anthropic and spends
their allowance. The allowance strip set the rule for that kind of feature: a
thing that reaches the network on the user's behalf is a choice made once, with
the sentence that says what it does, not a default discovered on a bill. The one
person using LampBoard today asked for LampMaster at once, and switching it on is
one click.

The request answers 202 rather than waiting because a round may take two minutes,
and a connection held that long is one more way to tie up the server that the
hooks post to. The fake `claude` of the end-to-end suite is looked for only in the
fake home: a test that forgot to write it must fail, not spend the real one.

Two rounds asked for in so many words are at least two minutes apart, and a
request while a round runs is refused with a 409: anything holding the token
could otherwise ask in a loop and, while the sessions kept changing, spend the
day's ceiling in a minute. A second "too soon" in a row is not even written down.

`claude` is looked for first in `~/.local/bin`, a folder the user can write,
because that is where Claude Code's own installer puts it. A security review
asked for a signature check before handing it the frame; it is not done, because
the installation through npm is a script with no signature to check, and because
a process able to plant a file there runs as the user and can read every
transcript directly — the frame would tell it nothing it could not read.

## D61 · LampMaster's cards open in a window, and act only as a row would

**Decided.** The panel gets one line for LampMaster while it is switched on; the
cards open in a window of their own. A card's action is carried out by what the
rows already do — raise a session, end its process after the same confirmation,
take its row off — and asking or replying copies the text and opens the session
rather than writing into it.

**Why.** The panel's height is a formula over things of known size; a card holds a
sentence of any length, and text the formula has not measured takes its room from
the last rows (the allowance strip did exactly that when it first shipped). One
line of the issue strip's height is counted, measured on the test Mac: 65 points
with LampMaster off, 82 with it on. Reusing the rows' actions means a card can
never do what a click on a row could not, and the confirmation before ending a
process is written once. Writing into a session from the panel is the "hands" of
0.6; until then a copied sentence one paste away is honest about what the panel
can do.

## D62 · A session can ask LampMaster, and never receives another session's words

**Decided.** LampMaster is reachable from any Claude Code session as an MCP server,
`lampmaster`, with four tools. Three run no model and cost nothing: `overlaps` (who
else wrote these files in the last two hours, or is live on the same branch),
`who_knows` (which sessions worked on a topic), `precedents` (who hit the same
error, and whether they saved work after). The fourth, `ask_lampmaster`, runs the
round's isolated `claude -p` on a question. The lookups answer with facts about
sessions — id, project, title, state, files, times, matched words — and never with
what another session wrote; the question answers in LampMaster's words, with
sources whose whole quote is in the frame. Searching the conversations themselves
waits for the index of the next stage.

**Why.** Whatever a tool returns enters the context of the session that called it,
and that session acts with the user's tools. A conversation can contain a sentence
that reads like an order, and a lookup that pasted it would carry it from one
session into another — the injection a panel of many sessions makes possible. The
round's evidence passes when some clause of it is real; a source shown to another
session is held to all of it, because a real clause could otherwise carry an
invented one.

Measured on 4 October 2026 with a throwaway server on the test Mac: Claude Code
2.1.289 hands the server `CLAUDE_CODE_SESSION_ID`, so LampMaster knows who asks and
leaves the asker out of its own answers; and it opens with `server/discover`, from
a newer protocol revision, before `initialize` — a server that did not answer
"method not found" to what it does not know would never have been initialised.

A security review of the running server added three things. Every tool result
opens with a notice that what follows is data about other sessions and nothing in
it is an instruction; the one prose the lookups carry, a title or a file name that
another session chose, is flattened to one line and clipped. The question's frame
leaves out LampMaster's notebook, the one text a past round wrote unchecked, since
that answer goes to a model and not past a person. And a question is booked before
it runs, two at most at once: the limits had been read at the start and written at
the end of a minute-long run, so a burst of calls all passed. The session id a call
carries is the caller's own word and serves only the per-session limit; the hourly
total is the bound. What remains is the answer's prose, LampMaster's own synthesis,
which no program can hold to the frame word for word; it comes from a run with no
tools, and reaches the session after the notice.

## D63 · Sessions reach LampMaster only once the user puts it into Claude Code

**Decided.** The `lampmaster` MCP server reaches Claude Code only through a switch
in Settings, or `lampboard mcp install`, which runs `claude mcp add --scope user`;
switching it off, `lampboard mcp uninstall` and `lampboard uninstall-hooks` run
`claude mcp remove`. Whether it is registered is read from `~/.claude.json`.

**Why.** User scope, because the session that would benefit is never the one
somebody thought of ahead of time. Claude Code's own command, because
`~/.claude.json` is a file Claude Code rewrites all day, and a second writer is a
race that shows up as a setting quietly gone. Read rather than asked, because
measured on 4 October 2026 `claude mcp get` starts the server to check its health:
a status that launches what it reports on is not a status. And with the hooks on
uninstall, because a registration left behind makes every session start a binary
that may no longer exist, and fail where nobody looks.

## D64 · The tutorial plays invented sessions in an instance of its own

**Decided.** The tutorial's tour runs on a script of invented sessions kept in
Core, in Swift and under test; `lampboard tour --json` exports it for the site's
demo and the screenshots. The tour is played by a second instance of the app, with
a temporary home and a port of its own, its panel marked as a trial; the script's
beats reach it as hook payloads, through the same server and reducer as real ones.
A step moves on with its gesture, and a step whose feature this version lacks is
not shown.

**Why.** The script is the one thing shown on screens, in screenshots and on the
site, so it is the one place demo data may live, and the check that it holds
nothing real runs with the tests. A second instance is the arrangement
`make-screenshots.sh` already proved: invented sessions cannot mix with real ones,
because they never share a process, a home or a port, and every colour the tour
shows is one the panel really produces. Mixing them in the real panel would have
needed a switch between two stores at the heart of the app, and one forgotten
branch would show a real session in a screenshot meant for the public.

The tour's progress is kept by step id in a domain of its own, apart from the
trial's, because every trial starts on a fresh home and somebody who stopped at step
three should find step three. In a trial, opening a row only marks it seen: an
invented folder has no editor, and reaching for one raised a modal warning that,
measured on the test Mac, also held off the trial's quit.

## D65 · The companion mod reports figures; the colours stay with the hooks

**Decided.** The companion mod (`lampboard@lampboard`) posts to `POST /mod` what
only the session knows: its context as Claude Code counts it, what it has cost,
the account's rate-limit windows, where it draws, and why it ended. It does not
post the turns that move a row's colour; the hooks keep doing that, on every
version and surface, with or without the mod. A context figure the mod reported is
never replaced by one read from the transcript.

**Why.** The hooks are measured on every Claude Code version back to the ones the
nodes still run, on the terminal, the editor and the application; the mod exists
from 2.1.287. With both posting a `Stop`, the panel would receive one fact twice,
from two processes, in either order, and every rule about when a status changes
would have to be proved again against duplicates. Kept apart, a row reads the same
whether its session has the mod or not, and the mod adds only what nobody else
could: the session's own count, against which the transcript's sum is a floor or a
guess at the window.

## D66 · The app carries the mod and installs it from a folder of its own

**Decided.** The companion mod's files are compiled into the app (`ModFiles`),
and `lampboard mod install` writes them to `~/.lampboard/mod-marketplace` and hands
that folder to Claude Code's own `claude plugin marketplace add` and `claude plugin
install --scope user`. `uninstall` and `uninstall-hooks` take out the plugin and
the marketplace both. At launch an installed mod of another version than the one
carried is replaced. The same files sit in the repository, which is therefore a
marketplace as well, and a test holds the two copies to the same bytes.

**Why.** Pointing Claude Code at the repository on GitHub would install whatever
`main` holds that day, not what this panel reads: the two ends of one wire format
would drift apart with every release. A folder written by the app needs no
network, survives the app being moved (Claude Code remembers the path), and is
what a node will be sent over ssh. Claude Code's own commands, because they write
`~/.claude/settings.json` and records of their own, and a second writer of those is
the race D63 refused. Under `LAMPBOARD_HOME`, `claude` is run with that home as its
`HOME`: measured on the test Mac, `claude plugin` honours `HOME`, and a child
inheriting the real one would install into the real Claude Code from a test.

## D67 · The allowance strip draws the mod's windows, with the request as reserve

**Decided.** The rate-limit windows a session reports through the companion mod
draw this Mac's session and week bars, with or without the allowance switch, when
they are newer than the usage service's answer. They are taken only from sessions
on Claude Code's default configuration: the mod (1.1.0) says whether
`CLAUDE_CONFIG_DIR` is set, never its value. The service's answer, when the switch
is on, still names the account and is the only source of a model's own weekly cap.

**Why.** The session's figures come with every response, cost nothing, need no
borrowed credential and never leave the Mac, which is what the switch exists to
guard; installing the mod was the consent. But a session does not say whose account
it is, and a Mac can run several through `CLAUDE_CONFIG_DIR`, so a window from such
a session could belong to an account other than the one the strip names; those are
left out rather than drawn under the wrong name. Measured on the test Mac on 4
October 2026: a throwaway session's measure carried two windows, and the panel,
with the switch off and no row, grew from 65 to 86 points to draw the bar.

## D68 · The local server refuses what a web page could send

**Decided.** Before any route, the server refuses with 403 a request that carries
an `Origin` header, whatever its value, and one whose `Host` is not `127.0.0.1`,
`localhost` or `[::1]`, with or without a port. A missing `Host` passes. Separately,
a session file whose pid is alive but whose process started at another moment than
the file records is a dead session: the pid was handed to another process.

**Why.** The socket is bound to loopback, so the network cannot reach it, but a page
in a browser on the same Mac can: it can post to `127.0.0.1`, and `/signal` still
takes a signal without a token for hooks installed before tokens existed; or it can
rebind a name it owns to `127.0.0.1` and read the answers. Browsers mark both: they
send `Origin` on every cross-site request that is not a plain read and on every
POST, and a rebound name arrives as the `Host`. No client of ours sends either:
measured on the test Mac, a throwaway Claude Code session's native hooks and the
companion mod all went through, none refused, while a POST carrying `Origin` got
403. What a page can still send without `Origin` is a blind `GET`, and the only
route that answers one without the token, `/health`, says only that LampBoard is
there. The pid check keeps what it cannot disprove — no start in the file, a form it
does not read, a process it cannot ask — and allows two seconds, because a wrong
answer here hides a live row.

## D69 · A stuck session is a mark on a yellow row, not a seventh colour

**Decided.** The companion mod (1.2.0) reports when a tool starts and ends, with
its name and its shell line or file path. A working row whose session has sat on one
tool for fifteen minutes shows `⌛` and how long in place of its duration, and its
card names the tool and the line. The colour stays yellow. A turn that stops
working takes its running tool with it.

**Why.** A seventh state would move through the legend, the reducer, the menu bar,
the notifications and every rule about what a click clears, for a fact that is a
suspicion and not a state: a build or a test suite can honestly run for ten
minutes, and only a person can tell it from a command waiting on input. The colours
come from the hooks (D65), and this keeps them there. Fifteen minutes because the
long honest tools measured here finish well within it; the card says how long
either way. The posts are not awaited, so a tool call never waits on the panel —
measured on the test Mac: a three-second `sleep` reported its start and its end
three seconds apart, and the session's own run was unchanged.

A security review shaped the rest. The line is the first one of the command, cut at
120 characters, with what looks like a secret masked (a variable named like a key or
password, a password in a URL, an Authorization header, `--password`) and bidi and
zero-width characters removed: every command now reaches the panel, not only the
ones waiting for a yes, and the card may be on a shared screen. An "end" that
overtakes its "start" leaves a mark so the late start is ignored; a call from before
the row began working is not this turn's; and `Agent`, which runs as long as its
subagent, is not tracked, or it would read as stuck while hiding the inner tool.

## D70 · A watched command is a row of its own kind

**Decided.** `lampboard watch [--name N] -- <command>` runs the command as its child,
with the terminal's own input and output and its exit code returned, and reports its
start and end to `POST /watch`, behind the token. The row belongs to a third harness,
`command`: yellow while it runs, green on 0, red with `exit` and the code otherwise;
no context ring, no window to open, a click only marks it seen. No hook can claim
that harness, and the switch that hides terminal sessions does not hide it.

**Why.** A build or a deploy is waited on like a session, and the panel is where
waiting is looked at. Its own harness, because every rule about a session — a
transcript to read, a context to measure, a window to raise, a permission to wait
for — is false for a command, and `Harness` is where the app says what a row cannot
do. Behind the token, because it is the one route besides `/signal` that creates a
row, and `/signal` is kept open only for hooks older than tokens. On the test Mac a
failing, a succeeding and a running command drew the three rows; the first try
showed none, because the sweep that forgets terminal sessions took them too.

A security review added the bounds: the folder must exist and be a directory, with
no control or bidi character, since its glyph opens it; at most twenty command rows,
the oldest finished one making room; a running command is never pruned; the default
name is the program's, never its arguments; SIGTERM and SIGHUP reach the command and
its end is still reported; and a click on a project row whose most urgent member is
a command goes to the project's first real session.

## D71 · `/lampmaster` answers the person, not the model

**Decided.** The companion mod, from 1.3.0, registers `/lampmaster <question>` in
each session. The question goes to `POST /lampmaster/tool` as an `ask_lampmaster`
call, with the session's id and folder, behind the token; LampBoard answers it with
the same switch, limits, cache and daily ceiling as the MCP tool (D62). The answer
is printed as the command's output and nothing is left in the model's context. The
command is `immediate`: it runs while a turn is still going. With the panel closed
or LampMaster switched off, it prints why, in one line.

**Why.** The MCP server already lets a session's model ask; the command is for the
person, who often wants to know what another session did without spending a turn of
this one on it. One route for both, so a question counts against the same limits
whichever door it came through. Not in the model's context, because the answer is
made of other sessions' work: whether this session should act on it is the person's
call, and a hidden note would carry one session's words into another's prompt. On
the test Mac a throwaway session asked who renamed an endpoint and got the invented
session that did it, with its source, in 6 seconds and 1,911 tokens of LampMaster's
run; the same command with LampMaster off, with no question and with the panel
closed printed the reason, and the session spent no turn on any of them.

A security review asked for the terminal: every field of an answer, the sources'
quotes and the suggested question included, now reaches it flat and without control
characters, since another session's transcript could have put an escape sequence
there; the question to forward is cut to 200 characters and quoted; and the mod
strips control characters again and cuts the answer to 4,000 characters, trusting
nothing that answered on the port.

## D72 · A failure repeated, or a turn stuck, brings LampMaster's round now

**Decided.** Besides the hourly round, LampMaster runs a quick one when its frame
holds an urgent pair — a session and a repeated failure, or a session stuck in a
turn — that the last round to reach `claude` did not see. Ten minutes at least after
any round, six a day at most, inside the same daily ceiling and behind the same
switch. It is looked for after a turn ends, after a tool fails (the `Stop`,
`StopFailure` and `PostToolUseFailure` hooks, and the mod's end of a tool), at most
once a minute, and on the five-minute tick, since a stuck session sends nothing. A
look that finds nothing new writes nothing. The round records the pairs it saw.
The quick round runs Sonnet, whatever the hourly round is set to.

**Why.** A session repeating a failure is spending its owner's time and allowance
now, and the hour is when another session's fix stops mattering; a stuck turn is the
same. The other signals keep: a full context already shows on the row's ring and
its remedy needs no model, overlaps and finished work are as true in an hour.
Sonnet, though the plan said a small model: on the test Mac, on one frame of two
invented sessions, Haiku took 36 to 56 seconds — 5,600 tokens of thinking before its
first word — for 0.020 to 0.037 dollars, and Sonnet 6.5 seconds for 0.016. Each
Haiku answer was right: the session that had fixed the same missing script, offered
as a precedent to the one failing on it. A minute is too late for a quick round.

A code review asked for three things, all done: a look shows LampMaster as running
only once it decides to run, since every turn's end flickered the line and turned
a request away as busy; the one-a-minute allowance is spent only by a look that
starts; and a round written before quick rounds counts as having seen what is urgent
now, so an update does not buy a round. Accepted: each look reads the transcripts,
at most once a minute and on the five-minute tick, tokens never.

## D73 · The panel acts on sessions, and every act is a click

**Decided.** From 0.6 the panel does not only show and raise sessions: it answers
a permission (Allow, Deny), answers a question, sends a message, and puts one
session's question to another. Every one of these is a click by the user on
something the panel shows; nothing writes into a session on its own, LampMaster
included, whose cards copy a question and open the session rather than send it
(D61). Each capability that can start
a turn in the user's name is off until switched on, and says what it does before it
is, as the composer's dialog already does (D15).

**Why now, when N7 said no.** N7 recorded that a running session could not be
written to: the editor's deep link refuses a prompt to an open panel, and that is
still true. Two doors have opened since, both Claude Code's own. Every session of
Claude Code 2.1.224 or later has a message box — a socket named in
`CLAUDE_CODE_MESSAGING_SOCKET`, with its token — which throwaway sessions in tmux
accepted from outside, and through which a question went from one session to
another and its answer came back in 14 seconds (4 October 2026). And mods (2.1.287) can decide a permission before Claude Code
asks for it, through `tool.check`; that one is **not yet tried**, and is measured
before anything is built on it. The composer of D15 stays as the fallback for sessions without
either.

**Why it matters more than it looks.** A click on a session of the Claude
application raises the application, where the conversation is (D36), not the
conversation itself; a link to the exact conversation is still unverified. For those sessions, and for any session on
another machine, acting from the panel is the only way to act without hunting for
the window. Marco approved the direction on 4 October 2026 — "everything else is
great and should be done" — with the standing rule that no message reaches a real
session of his without his yes.

**What stays as it was.** The chat window reads everything whether or not anything
is switched on. A session with its own panel open in an editor is still not typed
into through the editor (N7).

## D74 · What waits for you is a queue, and a card waits 600 ms before it can be answered

**Decided.** Above the rows, the panel will show what needs you as cards in one
queue: permissions, then questions, then turns stuck on one tool, failed turns,
answers to read, and LampMaster's suggestion last — always last and only one, with
a count of the others. Within a kind, the older first. Answers to read stand one
card each up to two; three or more are one card, since a pile of green is one thing
to do. A watched command that succeeded is not something to read. Each card's
buttons are armed 600 ms after it appears. The queue is worked from the keyboard:
`J` and `K`, `O` to open, `E` to mark read what there is to read — never a permission
or a question, which `E` would leave unanswered.

**Why.** The column answers "which session", and with two dozen of them the answer
is a scan. The queue answers "what next", in the order that costs the least waiting:
what stops work before what can wait. The delay is for the one accident a queue
invites — a card that appears under the pointer the instant before a click meant for
something else. The keys that answer a permission, a question or a reply exist from
the start and do nothing until the panel can act in a session (D73), so the layout
the hands learn does not change under them later.

A code review moved two things: the queue reads the state the row **shows**, since
a parent with a subagent alive is blue whatever it said last; and a card is armed
from when the queue first shows it as it is, with an ask's words in its id, since a
second permission in the same turn otherwise inherited the first one's armed
buttons. Only an ask that leaves unanswered by the panel says "resolved elsewhere".

## D75 · The queue takes keys only while the panel holds the keyboard

**Decided.** The queue's keys — `J`, `K`, `O`, `E`, and the ones still inert —
act only while the panel is the key window, which it becomes when it is clicked and
never on its own. A local key monitor reads them then and lets every other key pass.
The selected card is outlined only in that state; it starts on the most urgent card
each time the panel takes the keyboard, stays there as newer cards land until `J`
or `K` moves it, and from then on follows the card that was chosen. A key that will
answer a permission beeps rather than doing nothing in silence.

**Why.** The panel exists beside the editor somebody is typing in, and a panel that
read keys it was not given would put a stray `e` into a session as easily as it
would mark one read. Clicking it is already how it becomes key (it is a
non-activating panel, so the editor's app stays active), so the gesture that says
"I am looking at this now" is the one that hands it the keyboard. An outline drawn
without the keyboard promised that a key would act, and on the test Mac the trial
panel, key from its launch, showed the outline on the last card to arrive rather
than the first. Not verified on screen: the keys themselves, which need a click and
key presses that ssh cannot send on the test Mac; they are held by the tests of
`WaitingQueue.Cursor`.

A code review found the keys acting in the narrow panel, where the queue is not
drawn — an `e` would have marked read an answer nobody could see — so the keys now
need the wide panel as well as the keyboard. It also found the height two points
short when the «more» line shows, a card left looking unarmed after it had armed,
and a resolved card cleared early by an older timer; all fixed. A stuck turn has no
event to announce it, so the queue also looks every thirty seconds.

## D76 · A row says what its session is doing, on a second line

**Decided.** In the wide panel every row has two lines: the name and its time, and
under them one phrase about now — what an amber row asks, the tool a yellow one is
on (and past fifteen minutes on one, that it may be stuck), why a red one died, the
first line of the answer a green one holds, what keeps a blue one waiting, and at
rest only the agent. A session on another machine says the machine first. Rows are
36 points rather than 24 there; the narrow panel is unchanged.

**Why.** The column answered "which session" and left "doing what" to a hover, one
row at a time; with a dozen projects that is a dozen hovers. The phrase is the card's
most useful field, said where the eye already is. It costs height, twelve points a
row, and that is the trade the UX accepted: a panel a third taller that can be read
without touching it. The phrase repeats what a queue card says for the rows that
are in the queue, deliberately — the queue is the order to act in, the column is
where everything is.

A code review asked for the screen reader: the row is one sentence — name, how many
conversations, state, activity, context — with expanded or collapsed as its value,
and what its hidden children did is offered as actions (open, move up and down, show
in Finder). It also found an answer opening with a blank line leaving the line
empty, and a tab gluing two words; both fixed, with `+N` for a project of several.

## D77 · The bar answers ⌘K inside the panel; a global shortcut is the user's to choose

**Decided.** The wide panel gets one box at its top (UX §2) that finds a live
session by name or by what it is doing, runs one of the panel's actions, or puts a
`?question` to LampMaster. Inside the panel, `⌘K` focuses it. A shortcut that
reaches it from any application exists, and is **off** until somebody picks one in
Settings from a short list.

**Why off.** The UX asked for `⌘K` everywhere, and `⌘K` everywhere would take
every chord VS Code begins with it — `⌘K ⌘S`, `⌘K ⌘0` and the rest — from the editor
the panel exists beside, silently, the moment the app is updated. A global
shortcut is a claim on the whole Mac; like the features of D8 that ask for
something, it starts off and is asked for.

**At rest a button, not a field.** The first version drew a text field, and the
test Mac showed why not: a field takes the keyboard by itself the moment the panel
becomes key, so every key the queue answers to would have typed into it instead,
and its results repeated the queue below. So the bar is a button saying `⌘K` until
it is clicked or `⌘K` is pressed, results appear only once something is typed, and
an emptied field closes when it loses the keyboard. The global shortcut is the next
step.

A code review found the panel keeping the results' room after the text was erased,
and a LampMaster answer landing under a bar already closed, or under a question
already changed; the bar now asks the panel to remeasure on every change that can
move its height, and an answer is dropped unless its bar is still open on its
question. `⌘K` in an open bar gives its field the keyboard back, and a session's
title reaches the results as one clean line.

**The shortcut from anywhere, built.** Settings offers off, `⌥⌘K` and `⌃⌘K`, each
registered through Carbon's hot keys, which need no permission — a global key
monitor would need Accessibility and would see every key typed on the Mac. Pressed,
it brings the panel up holding the keyboard with the bar open, without activating
the app. On the test Mac both combinations registered; the press itself was not
tried, since ssh cannot press keys there.

## D78 · The panel is 340 points wide, the column 44, and it grows toward the middle

**Decided.** The wide panel goes from 240 points to 340, and the narrow one from 35
to 44 — the widths the UX settled on for the Panel and the Column (§1). A width
change keeps the edge nearest the side of the screen where it is: a panel kept on
the right half grows to the left, toward the middle, instead of off the screen and
back by the clamp.

**Why.** The second line of a row (D76) and the bar (D77) are sentences, and at
240 points a sentence was three words and an ellipsis; at 340 the answer a session
holds fits whole, as the test Mac's picture shows. It costs a hundred points of
screen beside the editor, which is the trade the UX made for a panel that can be
read without hovering. The Plancia, at 780, is the next step and comes only when
asked for.

## D79 · The Plancia opens a session beside the list, and Esc only closes it

**Decided.** A session opens in the Plancia from its row's menu (*Open in the
Plancia*) or with `⌘⇧L`, which steps through the depths of the UX — column, panel,
the Plancia on the most urgent session, the column again. The panel widens to 780
points toward the middle of the screen and the conversation sits on that side of
the list: the chat window's own view, so the reader, and the composer when sending
is on, are the ones that already exist (D15). It closes with its button, with
`Esc`, or by itself after four seconds with the pointer elsewhere, nothing waiting
and no pin.

**Why `Esc` only closes it.** The UX had `Esc` step down a level each time, panel
to column included. A key people press to dismiss things should not narrow the
panel they keep beside their work, so `Esc` leaves the Plancia and stops there;
`⌘⇧L` is the way down to the column.

**Found while building it.** A LampMaster card names its sessions by their first
eight characters, and every place that opened a session looked them up as whole
ids: opening a LampMaster card from the queue had done nothing since 0.6's queue.
The state now finds a session by those eight characters when they name one only.

A code review found the queue's single keys reading letters typed in the Plancia's
composer — `a` in "ask" would have allowed a waiting permission — and `Esc` there
throwing the draft away: no single key is taken while a text view has the keyboard.
It also found the Plancia staying open on a session that had ended, the side it
opens on able to flip once the panel was wide, and the chat window and the Plancia
taking the same session's mailbox marker from each other; the Plancia now closes
with its session, keeps the side it chose, and the marker goes only when the last
view holding it lets go.

**Its tabs.** Beside Thread, the Plancia has Activity — each tool the session ran
and how long it took, each turn and what it alone cost — and Cost — its context,
the total the mod reported, the recent turns. Both come from the companion mod and
the hooks, folded per session in memory; without the mod they say so rather than
showing zeros.

## D80 · A permission waits 55 seconds for the panel, then goes back to its dialog

**Decided.** When the panel answers permissions (D73, switched on by the user), the
companion mod asks it only about calls Claude Code would put to its dialog — the
engine's own verdict is `ask` — and waits for an answer. The panel has 55 seconds;
past them, and whenever an ask is malformed, one too many (eight waiting at once),
or already being asked, the answer is `ask`, and the session shows the dialog it
would have shown anyway. An answer counts once.

**Why these numbers, and why only `ask`.** Measured on the test Mac with throwaway
sessions (5 October 2026): a mod's `tool.check` may wait on the panel for about a
minute — at 20 seconds its `deny` held, at 65 the command ran on the engine's own
verdict — and a mod answering `ask` in an interactive session brings back the
ordinary "Do you want to proceed?" dialog. A mod can also overturn the engine's
verdict either way, which is why it asks only where the engine would have asked:
the panel answers what the person would have been asked, and nothing else.

**The door, built and tried.** The mod, 1.4.0, adds `tool.check`: for a real call
the engine would put to its dialog, it asks `POST /check` behind the token, and
returns the panel's `allow` or `deny`, the engine's `ask` for anything else. The
panel holds the asking connection on its server's concurrent queue; `GET /check`
lists what waits and `POST /check/answer` answers, behind the token too, the door
the queue's keys and a future `lampboard answer` share. Off — the default — every
ask is `ask` at once. On the test Mac, an interactive throwaway session with the
real mod asked to `touch` two files: the one denied through `/check/answer` was
"blocked by your LampBoard plugin hook", the one allowed was created.

**What a security review changed.** A project's settings can set environment
variables for its sessions, and the mod found the panel from `LAMPBOARD_HOME`
when it was set: a cloned repository could point it at a folder of its own, with a
token and a port of its choosing, and a dev server there answering `allow` would
have allowed every call — whatever the switch said, since the switch is the
panel's. Measured on the test Mac: with a project's settings setting both, the mod
read the attacker's `LAMPBOARD_HOME` and the **real** `HOME`. So the mod now finds
the panel from `HOME` alone, for its reports as well as its asks, and a test runs
its sessions with `HOME` set to its fake home. And the token is never sent for an
ask: the mod sends a nonce and an HMAC-SHA256 of it made with the token —
computed by hand from `crypto.subtle.digest`, the one primitive its runtime offers
— and accepts only an answer the panel signed the same way, so a listener without
the token, on a port the panel left, can neither be asked nor answer. Tried again
on the test Mac with the mod installed by LampBoard into a fake home and a hostile
project pointing `LAMPBOARD_HOME` at a listener that always says `allow`: the ask
reached the real panel, its `deny` held, and the listener heard nothing. Asks are
addressed by session and call, and one booked after its connection gave up is
released at once.

**What a second review changed.** The token was still the wrong secret to prove
with: every hook and every report carries it to whatever answers on the port, and
while the panel is away another account on the Mac could listen there, learn it,
and sign `allow` with it. So the proof and the signature use a key of their own,
`~/.lampboard/check-key` (`0600`, written at launch like the token), which the mod
reads and sends to nobody. The token proves nothing at `/check`, and the E2E
suite asks with it to see so. A call id already waiting under one session no
longer stops the same id from another; and a connection that gave up withdraws
only its own booking, never another's for the same call.

**The panel's side (AD3).** An ask the panel holds is a permission card at the
top of "Waiting for you" (D74), with Allow and Deny on it and on `A` and `D`,
inert for the queue's 600 ms like every card; Always stays a beep, since the mod
can say allow and not always. The session's row stays yellow while the panel
holds the ask — no dialog has been shown, so no hook has said otherwise — and the
card is what says that the session waits. A card that leaves because its ask went
back to the dialog, at 55 seconds or given up on, says "Back to the terminal's
dialog" for its moment; one answered from the panel, by a click, a key or
`/check/answer`, leaves without a word. A review asked for four things, all done:
the ask's line is cut in the middle, never at its tail beside Allow, and whole in a
tooltip; a click on the held card does not also open the session, which `O` still
does; an answer to an ask already gone beeps; and Allow and Deny are VoiceOver
actions on the card. The switch lives under the mod in
Settings, off by default, with what it does said above it (D73); a new
installation answers every ask `ask` at once, which the E2E suite checks. Tried
on the test Mac with the trial's invented sessions: the card drawn with its two
buttons, a Deny through `/check/answer` reaching the asker signed, and an ask
left alone going back after 55 seconds with its line.

**What a third review changed.** `GET /check` and `POST /check/answer` were behind
the token, and the token is in every hook — here and, through the tunnel, on every
node — and readable by any process of the user's: one that held it could list
another session's ask and answer it `allow`, with no click. In a real install the
two routes now answer 404; the panel answers in-process, from a click or a key,
which is what D73 promised. They stay for a fake home only (`LAMPBOARD_HOME`), where
the tests and the test Mac's probes answer through them. Never released: 0.5.0 has
no permission door.

## D81 · The composer writes into Claude Code's own message box

**Decided.** A message from the panel's composer — the chat window's and the
Plancia's, behind the same switch as D15 — goes into the session's own message
box when it has one, and through the mailbox of D15 only when it has not. The
box is Claude Code's (2.1.224 and later): each session listens on a socket named
in its file under `~/.claude/sessions/`, and takes a message from whoever holds
the key Claude Code keeps beside that file, `0600`, for that process.

**Measured on the test Mac** (Claude Code 2.1.289, throwaway sessions in tmux, 5
October 2026). An idle session starts a turn on the message at once — about six
seconds to an answer; a busy one takes it into the running turn
(`absorbed_mid_turn`). The socket answers nothing: the transcript is the receipt,
first as a `queue-operation`, then as a user record with `origin` `peer`, `from`
`lampboard`, or, taken mid-turn, as a `queued_command` attachment with the same
origin. Claude Code wraps the message: another session sent it, "not typed by your
user", to be handled within the session's own permission settings, never as an
approval of a pending prompt. A request sent that way — count the files, with a
tool — was done. And end to end, LampBoard's own composer in the Plancia sent one
on the test Mac: the session counted its files, and the Plancia showed the message
as the user's and the answer below it.

**Why this and not only the mailbox.** The mailbox reaches a session only at the
end of a turn, and a dormant one not at all until something wakes it; the box
reaches it now, busy or idle, with no hook of ours and nothing `@internal`.
Claude Code keeps the box's key next to the session file, `0600`, and records
which process wrote each message (`verifiedPeerPid`): anything running under the
user's account could already write there without LampBoard, so the panel adds no
door. Whatever the route, the session acts on the message with every permission
it has — one that runs without asking runs its tools at once — and the switch's
dialog says so.

**How the panel's words are known again.** Every message starts with one line —
"Typed by the user in LampBoard, the panel on this Mac where they watch their
sessions:" — and says it is `from` `lampboard`; the conversation shows it as the
user's only when both are there. Both are the sender's own word: a security
review asked, and the measure agrees — the probe's own script wrote
`from: lampboard` and Claude Code recorded exactly that. A session talking to
another names itself, so its messages show as "a message from another session";
a process of the user's own could claim both, the same account boundary the
mailbox has (D15), and the conversation only shows what it reads, it acts on
nothing.

**Which box.** Read again for every message, and used only when everything about
it holds: the session file named after its pid, a regular file of this user's and
not a link; the process running, this user's, and started when the file says
(`ProcStart`), so a pid handed on after a session died is never written to; the
key a regular file of this user's that nobody else can read, written for that
very process; the socket a socket of this user's. A write to a box that closes
early fails instead of killing the app (`SO_NOSIGPIPE`, the review's one high
finding). A box gone since the window opened sends through the mailbox; a message
the conversation has not shown in a minute stops being "on its way". A session on
another machine keeps the mailbox: its box is there, not here.

**From the bar (SQ3).** `@name message` in the bar (D77) lists each session the
name finds as "Send to …", and `⏎` opens the Plancia on it and sends through its
composer: the same switch, the same box or mailbox, and the message seen arriving.
Switched off, the result says where to switch it on and sends nothing; a session
on another Mac is said as such and sent nothing; a send refused keeps the text in
the bar; and the selection follows its result, so a list reordered by a status
change never turns `⏎` into a send to another session (a review's findings). Tried on the
test Mac by typing into the bar through `--bar-type` (fake home only): the session
answered and the Plancia showed both.

## D82 · A side question to a live session, answered by its mod with a fork

**Decided.** `@name ?question` in the bar asks a session a question without
disturbing it. The panel puts into the session's box (D81) one line — "LampBoard
asks without disturbing [v1 <nonce> <proof>]:" — and the question; the proof is an
HMAC with the permission key of D80 over the nonce, the session and the question.
The companion mod, 1.5.0, takes any message in that shape in `session.receive`
before the session sees it (`{ consumed }`), proven or not, and only when proven
answers it with `$.model.fork` over the session's conversation and posts the reply
to the panel as an `answer` report. The panel offers the question only to sessions
whose mod said `ask` in its `start` report, on this Mac, with sending on (D15,
D81), and shows the answer where LampMaster's answers show; it waits a minute.

**Measured on the test Mac** (Claude Code 2.1.289, 5 October 2026). With a probe
mod, a box message taken in `session.receive` left nothing in the transcript; the
fork answered "BLUE-HERON." from the conversation in about a second and a half,
idle and mid-turn, reading some 33,000 tokens from cache and adding no turn; a
message without the line passed untouched. With LampBoard's own mod installed by
LampBoard into a fake home, `@Blue-heron ?…` typed into the bar through
`--bar-type` came back in two seconds as "BLUE-HERON.", the session's row
unchanged and the question nowhere in its transcript.

**Why taken even when unproven.** A message that starts with that line is never
the session's to read, whether the rest checks out or not — cut, too long, forged: a forged one should not reach the model as a peer's request, and one the
panel sent with a key since rotated should not turn into a turn. Taken and
answered by nobody, it costs the sender a minute's wait. The key stays a same-account
secret, as D80 says: a session's own tools could read it and forge a proven
question to a sibling, which would cost that sibling a fork's tokens and give the
forger nothing, since the answer goes to the panel and is dropped for a nonce it is
not waiting on. The mod asks the port again whether it is LampBoard before posting
an answer, the first post that carries words of a conversation. Each question costs
the account the conversation read from cache, some 33,000 tokens in the measure (a
security review's findings, with the bound counted in UTF-16 units on both sides).

**What it changes in what the mod reads.** Until now the mod read nothing of the
conversation. A fork reads all of it — that is how it answers — but only for a
question the person typed and the panel proved, and only the answer leaves the
session, to `127.0.0.1`. The Settings text says so beside the mod's switch, and
`claude plugin validate` now lists `session.receive` and `$.model.fork`, which the
mod's card reads out. The mod uses the model for nothing else; a test counts its
calls.

**Why not a switchboard between sessions.** The plan had one: a question from one
session to another relayed by the panel. Claude Code 2.1.289 gives every session
`ListAgents` and `SendMessage` of its own (measured), so two sessions on one Mac
already talk without LampBoard; what the panel adds is the person's side question,
and showing those messages in the conversation as another session's (D81).

## D83 · The companion mod on the nodes, through the tunnel

**Decided.** When the mod is on here (D65) and a node's Claude Code is 2.1.287 or
later, installing the hooks on that node installs the mod there too, with the
node's own `claude plugin`, from LampBoard's files written into
`~/.lampboard/mod-marketplace` there; and writes the three files the mod reads in
`~/.lampboard` there, owner-only: this panel's token, the port of the tunnel that
lands on this panel, and the permission key (D80). The node's sessions then report
through the tunnel (D24), and their permissions come to the queue (D80) like a
local session's. The launch brings a node's mod to this app's version, as it does
the hooks' token (D48); uninstalling the hooks takes the mod out, the three files
with it. A node without the mod is not given one at launch: it goes there when the
person installs the hooks.

**Measured on the test VM** (Lima, Debian arm64, Claude Code 2.1.289, 5 October
2026). First by hand (B0): with the three files there and the mod loaded from a
folder, a session's `start` and `measure` came through the tunnel, its permission
ask reached `/check`, and the panel's `deny` held there. Then by LampBoard (B1):
`remote install` printed "mod 1.5.0 installed … reporting through the tunnel", the
node's `claude plugin list` showed it read from that folder, a session started
without any flag reported and asked the same way, and `remote uninstall` left
neither the mod nor the three files.

**What a review changed.** The files written there are marked as the tunnel's
(`tunnel-mod`): a `~/.lampboard` there with a token or a port and no mark is a
LampBoard panel's own — whatever its port number — and is left alone; uninstalling
takes the three files back only when they are marked ours; a failed install takes
the key back too; a `~/.lampboard` other users can write is refused; the script
runs on one deadline inside the one the Mac gives ssh; and the launch brings a
node's mod up to this app's version, never down. The key is one for the Mac and
every node: whoever holds it on a node can forge an ask, which shows a card and
whose click goes only back to the forger, or sign an answer to a listener that only
that node's own sessions would reach — no way to the Mac or another node, now that
the answer routes are gone (D80). Keys per node would let a card name the machine an
ask came from; left for later. A tunnel on a connection of its own cannot use a
master the person authenticated by hand (2FA, a bastion): such a host needs key
login straight through, as the probes already did with `BatchMode`.

**What it writes there, and what it refuses.** One script in the shape of the
hooks' (D24): the data as one base64 literal inside the Python, no shell, a
`~/.lampboard` that is a link or another user's refused, every file written through
a fresh name opened `O_EXCL | O_NOFOLLOW` at `0600`. The
permission key goes to a machine the person reaches with their own key login, the
same trust the hooks there already carry the token on.

**Two bugs the test VM found in the tunnel.** Lima's ssh config has `ControlMaster
auto` and `ControlPersist yes`, as many people's do: the tunnel's ssh handed its
forward to a shared master and exited 0, the panel read the tunnel as down while
the forward lived on in the master, and the next try found its own port taken. The
tunnel now keeps a connection of its own (`ControlMaster=no`, `ControlPath=none`).
And a host added with `lampboard remote add` from a terminal is a write by another
process, which raises no `UserDefaults` notification here: its tunnel came up only
when the panel happened to write a preference of its own. The list is now also
read on the remote poll's clock.

**From the bar to a node (B3).** `@name message` and `@name ?question` reach a
session on a node too: a script run there over ssh (`RemotePeerScripts`, in the
shape of the hooks' scripts) finds the session's box on the terms the Mac's own
sender uses — the session file named after its pid, the user's and not a link; the
process running, the user's, and started when the file says; the key private and
written for that process; the socket the user's — and writes to it. A side
question's answer comes back through the tunnel like the node's reports. No Plancia
can show a node's conversation, so the bar says where the message went. Tried on
the test VM: `@lbwork ?…` answered in two seconds through the tunnel with the
question nowhere in the node's transcript, and `@lbwork Reply with exactly the word
MANGO.` was answered "MANGO" there. A review asked for two things, both done: the
key is taken only with a start time that matches, as on the Mac; and a box slow to
close after the message went counts as delivered, so a "not sent" never invites a
second copy.

## D84 · A band above every session's prompt says what waits elsewhere

**Decided.** While another session waits for the person — a permission, a
question, a turn stuck on one tool or failed — the companion mod, 1.6.0, draws one
line above the prompt of every other session: "⚑ LampBoard · 1: docs-site: Bash: npm
publish · 2: …", at most three, the most urgent first, never the session's own. A
digit at an empty prompt opens that session in the panel — its Plancia here, the
session itself on a node. Nothing is answered from the band. It shows only while
something waits, in the terminal and in the Claude app (one chat at a time there,
#99265); VS Code draws nothing a mod draws. A switch under the mod in Settings turns
it off; it is on.

**Measured on the test Mac** (Claude Code 2.1.289, 5 October 2026). A probe mod drew
above the prompt with `ui.render` on `AbovePrompt`, from elements built by
`$.ui.resolve(e)` — an element written by hand is refused, "not held by a plugin"
— redrew on `$.ui.invalidate` from a `setInterval`, which the runtime has, and a
`1` at an empty prompt pressed its button. Then with LampBoard's mod in two
throwaway sessions: while A sat on its permission dialog, B's band read "⚑ LampBoard
· 1: a: waiting for your answer", and a `1` in B brought the panel up on A.

**How it knows.** Every few seconds each interactive session's mod asks
`GET /mod/band`, behind the token, naming itself; the panel answers with its queue's
cards as the queue would draw them now (D74), without that session's, and the mod
redraws only when the answer changed. A press posts `POST /mod/band/open`. What the
band shows is drawn on the screen and never put into the conversation: the model of
one session reads nothing of another's.

**Why no Allow or Deny in the band.** The band lives in the mod, and the mod holds
only the token — which any process of the person's can read. A route that let the
band answer a permission would let any of them answer one with no click, the hole
D80's third review closed. So the band brings the person to the panel, where the
click is theirs.

**What a review changed.** A permission's line that came from a hook was not masked
on its way in, and the band goes to every session: each line is now read the way a
permission card reads one (`ModReport.detail`) — secrets masked, no control, format
or separator character, so no bidi override reorders it — and a session on a node is
told who waits and how ("a permission"), never this Mac's command lines. The band
empties when the panel stops answering, instead of keeping its last items; each
session keeps its own clock and state, stopped when it ends, since one process can
hold several; and the labels share the terminal's width. Measured again in the two
throwaway sessions: the band drawn, the digit opening the panel, and the band's text
in neither transcript.

## D85 · LampMaster's cards propose; the person sends

**Decided.** A LampMaster card whose action asks a session something, or answers
one, now opens the Plancia on that session with the proposed text in its composer —
"Open with the question", "Open with the reply" — to be read, changed and sent by
the person; the text is copied too, as before, for a composer that is off or a
session on another machine. Beside it, when that session's mod can answer and
sending is on, *Ask without disturbing* puts the question to the session as a side
question (D82) and shows the answer in the card: the session gets no turn, and the
click costs a fork's tokens, so it is a click every time.

**Why not send it.** D61 and D73 keep LampMaster from writing into a session, and a
card's text is the model's: sent through the composer it would arrive under the
panel's preamble, "Typed by the user" (D81), which it was not. Proposed in the
composer, it becomes the person's when they send it. A side question writes nothing
into the session, so it can be asked from the card.

**What the plan had and no longer needs.** "Ask" was to go through a switchboard,
with the answer brought back into the asking session; Claude Code's own
`SendMessage` between sessions does that now (D82), and the person, through the
composer, can tell a session to ask another. The handoff (*Testimone*) is 0.7's.

**What a review changed.** The card now shows the words a click would propose or
ask, before the click; the answer says it is the session's, from its conversation,
and scrolls past a few lines. A proposal is taken once — it cannot come back when
the Plancia redraws — goes only into the Plancia of the session it is for, and
never replaces or takes the focus from what the person was typing.

## D86 · A question Claude asks is answered from the panel too

**Decided.** With the switch of D80 on — now "Answer permissions and questions from
the panel" — a question Claude puts to the person with `AskUserQuestion` goes to the
panel first, like a permission: one question, one choice, two to four options, what
a card can show. It waits at the top of the queue (D74) as a question card with its
options as buttons and on the digit keys, inert for 600 ms; the option chosen goes
back to the session as the person's answer. Unanswered in 20 seconds, switched off,
or in any other shape — several questions, several choices, a number to type — the
session's own dialog asks it, as it always did.

**Measured on the test Mac** (Claude Code 2.1.289, 5 October 2026). A probe mod's
`tool.call` on `AskUserQuestion` returned `{ result: { questions, answers } }` itself:
Claude Code recorded "User answered Claude's questions: … → Blue" and the model said
"You chose Blue". The hook may wait on the panel over HTTP, but less long than a
permission's: 20 and 25 seconds held, 30, 40 and 55 lost to the dialog (a review
asked for the measure); a `setTimeout` of 15 seconds, time the engine counts, lost it
too. So a question has 20 seconds with the panel, a permission 55. Then
with LampBoard's mod 1.7.0 in a throwaway session: the question waited in the panel
as "work: Which color do you prefer? · 1 Red · 2 Blue", the second option chosen
reached the session, and the model answered "You chose Blue."

**Proven and signed like a permission.** The mod puts the question to
`POST /question` with a nonce and an HMAC of the permission key (D80) under its own
prefix, `question:`, so a permission's proof cannot stand for a question's; the
panel answers `choose <index> <signature>` over `choose:<nonce>:<index>`, or
`ask`, and the mod believes only a signed choice inside the options it sent. Allow
and Deny do not answer a question; a digit chooses. The answer route stays a fake
home's only (D80): in a real install the choice is a click or a key in the panel.

## D87 · A permission card says what the call would do

**Decided.** Beside a permission's Allow, the card says in a few words what the
call would do, when that can be known without running anything: a shell command
that destroys, named by what it does — "deletes recursively", "force-pushes",
"discards changes", "drops data", "runs as root", "runs a downloaded script" and a
few more, in the warning colour; and for an edit or a write, how many lines it
removes and adds, "−3 +5 lines", "writes 40 lines". A command it does not know is
said nothing about — never called safe. The same words go to VoiceOver.

**Where each part comes from.** The shell's is read off the command's one masked
line, which the card already has — from the mod's ask and from a hook's alike, so it
shows with the switch of D80 off too. The lines are counted by the mod, 1.8.0, from
the call's own input (`old_string`, `new_string`, `content`, a `MultiEdit`'s edits)
and sent as two numbers, never the text.

**Why not more.** The plan had a preview of what would change — files touched, a
`git diff --stat` — computed by the mod. The mod runs nothing (D65), and what a
command would change cannot be known without running it; a guess presented as a
preview is worse than none. Tried on the test Mac with the trial's sessions: the card
read "deletes recursively" beside Deny and Allow for `rm -rf build`.

**What a review changed.** The card reads one line of a command, its first, at most
120 characters: a command that goes on past it — a second line, a long chain — is
now said to ("more lines unseen", from the mod), so a card without a warning never
reads as one checked whole. A secret's mask stops at `;`, `&` or `|`, so it cannot
swallow the next command. The list is a fixed set of spellings, not a guarantee, and
it grew: `git -C … push -f`, `-fu`, `--mirror`, `--delete`; `rm` with its flags
anywhere; `find -delete`; `bash <(curl …)` and `$(curl …)`; `sudo` after `then`,
`xargs` or `env`; `chmod … -R`; `git checkout .`, `git stash clear`, `shred`,
`truncate -s0`. And it lost two false alarms: `git restore --staged` and
`git rm --cached`. A trailing newline no longer counts as a line, and the card gives
the project's name the room before the label.

## D88 · Every conversation of this Mac is searchable, from the bar

**Decided.** LampBoard keeps a search index of this Mac's conversations — what the
person typed and what Claude answered, nothing of context, tool output or other
sessions' messages — in `~/.lampboard/index.sqlite`, owner-only, with the system's
SQLite and its FTS5 (`unicode61 remove_diacritics 2`: "citta" finds "città"). Words
typed in the bar (D77) now also find the conversations that said them, after the
open sessions and the actions; one already a row is that row; one closed copies the
command that resumes it, `cd '<folder>' && claude --resume <id>`, and says so. From a
terminal, `lampboard search <words>` answers the same, panel running or not.

**How it is kept.** From the transcripts, not from the mod: each file is read from
where the last pass stopped, to its last complete line; a file that shrank is read
again from the start; a pass every thirty seconds at utility priority has a budget
of 200 files and 32 MB, newest first, so the first build of a long history spreads
over minutes instead of one heavy one. Only the last ninety days are built. No
token is spent. Settings will have the switch; the preference is `search.off`.

**What the plan had and this leaves.** The plan wanted the index fed in real time by
the mod and a one-line summary of every turn from Haiku. The transcripts are already
the record, read within thirty seconds, and a summary per turn spends tokens on every
turn of every session — the test account sat at 85 % of its week. Both wait.

**Measured on the test Mac.** The system's SQLite (3.54) has FTS5 and folds accents;
a quoted word keeps its hyphen ("aworld-lab" is a word, not a column filter, the
prototype's trap, §9.5) and grouping is done after `bm25()` ordering, not with
`GROUP BY` (the other). The end-to-end suite builds an index from a fake home's
transcripts with the real binary and finds a conversation by its words and by an
unaccented one, never by a reminder; and on the trial's panel, "zanzibar" typed in
the bar found the closed "Zanzibar itinerary" and copied the command to resume it.
`SQLITE_OPEN_NOFOLLOW` refuses a link anywhere in the path — `/var` is one, and so
are some homes — so the index file alone is checked not to be one.

**What a review changed.** The command line and the panel can write at once: each
waits for the other (`busy_timeout`), takes the write lock before reading a file's
offset, and keeps a chunk only whole — its messages and its offset in one
transaction, rolled back on any failure. A transcript is read at most 8 MB a pass,
never whole into memory, and a line longer than that is stepped over; a project
folder that is a link, or a file that is not a regular one, is not read; a new file
deletes nothing, so a first build is not quadratic; the queue is held per file, so a
search waits for one file, never a pass. The folder kept is where a conversation
began, not where a later `cd` took it, since that is where it resumes from; the
command copied takes only an id of a session's shape and a folder without control
characters. A conversation whose transcript Claude Code cleaned up is pruned. The
index is excluded from backups — it is a second copy of every conversation — its
folder is created `0700`, and `lampboard search --reset` takes it away.


## D89 · `who_knows` also remembers, without the words

**Decided.** The `who_knows` lookup a session asks through the `lampmaster` MCP
server (D62) answered only from the cards, which cover the sessions of the last
week. It now also asks the search index (D88), and after the cards it names up to
five earlier conversations that said those words, from the last ninety days: title,
project, how long ago, the first eight characters of the id. A session the cards
already named is not named twice, nor the asker itself.

**What it does not carry.** The index holds what other conversations said; the
answer goes into the asking session's context, which acts with the person's tools
(D62). So the answer names the conversation and never quotes it: no snippet, no
matched sentence. The person can open it from the bar, which shows the words to
them and not to a model.

**Measured on the test Mac.** The end-to-end suite indexes a fake home's transcript
dated twenty days back, whose prompt carries an invented word, and asks `who_knows`
through the real binary: the answer names "Docs build fix in docs" under "Said in
earlier conversations" and never contains the invented word. The lookup is wired
when LampBoard starts, panel on screen or not.

## D90 · The week in a paragraph, from the index, for the person

**Decided.** "This week" in the bar (D77) — or `week`, `weekly`, `summary`, `recap` —
and `lampboard week` in a terminal answer with the last seven calendar days, today
included: how many prompts the person typed, in how many conversations, projects and
days, the busiest day, and per project, the busiest first, its prompts, conversations,
days and the names of up to three conversations. Eight projects at most, the rest
counted. The bar shows it where LampMaster's answers show.

**Where it comes from.** The search index (D88): its `user` messages are the prompts
the person typed, its conversations have their folder and name. No token is spent and
nothing is read that the index does not already hold. Counts and names only: the
summary never quotes a prompt, though it is shown to the person alone — the bar and
the terminal, never a session.

**What the plan had and this leaves.** The plan saw the summary as prose about the
work done. That needs a model reading the week, which is the per-turn summary D88
left waiting for the quota. Counts and names are what the index knows for certain.

**Measured on the test Mac.** The end-to-end suite builds a fake home's index with
two conversations, one ten days old, and `lampboard week` counts the recent one's two
prompts, names it and leaves the old one out; on the trial's panel with three invented
conversations, "week" typed in the bar showed the same paragraph the terminal printed.

**What a review changed.** A project is a folder, not a name: two folders called
`api` are two projects, named with the folder above. The bar reads the week once at a
time and never while a message is on its way. Only conversations active in the week
are scanned for its prompts.

## D91 · The baton: one session writes, the person hands it over

**Decided.** `/handoff @from @to` in the bar asks the first session, as a side
question (D82) — no turn, nothing added to its conversation — for the handoff the
second will read: what it understood, what it decided and why, what is left, the
files it touched, thirty lines at most and no secret values. The answer, headed
"Handoff from <name>, through LampBoard", is put in the second session's Plancia
composer and waits there to be read, changed and sent: LampBoard proposes, the
person sends (D85). It is never sent by itself.

**Where it cannot wait.** A session on another machine has no Plancia here: the
handoff is copied and the bar says so. The same when the second session went away
while the first wrote, or its Plancia did not open. An answer that is not the
session's — no answer within the minute, nothing to answer from yet, a mod that
cannot answer — is said in the bar and never proposed as a handoff.

**What the plan had and this leaves.** The plan also wanted `/handoff @x` typed
inside a session, through the mod, and a new session opened already briefed. The
first is the next step (T2); the second waits for a way to start a session that
the panel can see and write into from its first second.

**Measured on the test Mac.** Two throwaway Haiku sessions in a fake home, one told
that the slots endpoint was renamed and the tests are left; `/handoff` typed in the
bar: the handoff came back four seconds later, 770 characters, and waited in the
other session's composer. Neither transcript gained a turn. A session that has
not answered anything yet says "nothing to answer from" and nothing is proposed.

**What a review changed.** A composer with the person's own words is not
overwritten and does not swallow the handoff: it is copied, and the bar says so. A
handoff called off — the bar closed or retyped while the first session wrote —
opens nothing and takes no clipboard. An empty answer is no handoff. `/h` keeps
finding the action it found before, the handoff's hint after it.

**From inside a session (T2).** The companion mod, from 1.9.0, registers
`/handoff <name>`: typed in a session, the mod asks the same question of a fork over
its own conversation — no turn — and posts the text to `POST /handoff`. The panel
finds the session by that name, as `@name` does — the one called exactly that, or
the only one the name finds; two or more and it asks for the exact name — and
proposes the handoff in its composer, as from the bar. The session prints where it
went; nothing of it enters the model's context (D71).

**What a security review changed.** The route takes the token and a proof: an HMAC
with the permission key (D80) over a nonce, the session, the name and the text, as
sent. The token travels with every hook to whatever answers on the port; with it
alone, anyone could put words in a composer under any session's name. A nonce
counts once. A name that finds no session copies nothing: the clipboard is taken
only for a session that exists and cannot take it. The answer the session prints
loses control and direction-changing characters. What stays as before (D62, D82): a
process that took the port while the panel was away and answers `/health` as
LampBoard would receive the handoff's text, as it would a side question's answer.

**Measured on the test Mac.** `/handoff api` typed in a throwaway Haiku session
told about the slots rename: "Handoff written: it waits in api's composer in
LampBoard", 665 and then, proven, 748 characters in the other session's composer,
unsent; neither transcript gained a turn.

## D92 · LampMaster's precedents: searched first, then judged

**Decided.** The fifth job of LampMaster's round — "a session faces a problem that
another conversation already solved" — no longer rests on the cards alone, which
cover a week. A session card keeps, beside each failure's fingerprint, the names on
the error line that the fingerprint takes out: a path's parts, a module, an endpoint,
four at most, without the words every error says. When a round is due to run, the
failures of the last hour of the sessions in its frame — four at most, the most
recent first, each searched once — are looked up in the search index (D88), and the
conversations that said those words in another project, or in the same one a day or
more before, enter the frame as `precedents`: three per failure, with project, day
and the words around the match, three hundred characters at most. No token is spent
finding them; the round judges whether they are worth a suggestion.

**Where they go, and where not.** Only into the hourly round's frame, whose advice
reaches a person. The frame of `ask_lampmaster`, whose answer can reach another
session's context, carries none. The MCP tool `precedents` names the conversations
of the index that said the failure's words, never their words, as `who_knows` does
(D89). The frame drops them first when it is over budget, and they are searched only
once the round is known to run: the digest that decides whether to run is the
sessions', so a precedent alone is no reason to spend a round.

**What the plan had and this leaves.** The plan wanted the round able to search up to
three more times with a tool. The round runs without tools, isolated, and stays so.
It also wanted D3 proven on a real case of the person's: that is theirs to see, on
their Mac; on the test Mac, an invented failure and an invented older conversation.

**Measured on the test Mac.** The end-to-end suite writes a session that failed three
times on "missing script: deploy" and a three-day-old conversation in another project
that fixed it; the round's frame, as the fake `claude` received it, carries that
conversation under `precedents` with its project and the words around the match.

**What a review changed.** The search moved after the decision to run, and to the
sessions the frame kept; a failure two sessions share is searched once and picked for
each, since each has its own project.

## D93 · The round gives way to a tight allowance

**Decided.** LampMaster's round now carries the allowance in its frame — one line
per account the allowance strip shows: the share used of the window most at risk,
the minutes to its reset, and whether it runs out before then — and it gives way: when
the account it spends, this Mac's, would run out of its session or weekly window
before the reset, the round is skipped at no cost and the line says "Allowance tight ·
signals only". A model's own weekly cap is not the round's and does not count.

**The forecast.** The pace so far: a window five hours long, two hours in at 60 %,
ends at 150 %. It needs no history beyond the strip's last reading; before 15 % of a
window has gone it says nothing, since a burst at the start reads as a pace. The
person's sessions and the round draw on the same allowance (§6 of the plan): the
round is the one that waits.

**What it does not cover.** The end-to-end suite runs the app headless, where no
allowance strip exists; the rule is held by the domain suite, the wiring is two
lines. The nodes' sessions in the frame are the next part of the same step.

## D94 · The nodes' sessions in LampMaster's frame

**Decided.** LampMaster's round now sees the Claude Code sessions running on the
nodes, as it sees this Mac's. Once per round, and only while LampMaster is on, the
panel runs one program over ssh on each node with such sessions; it reads each
transcript from where the last read stopped — the tail first, half a megabyte at
most — and the panel builds the same cards from it, marked with the node's name in
the frame. A node that does not answer keeps the cards it had. The lookups the
sessions ask (D62) still read this Mac's cards only.

**What a node is trusted with, and what not.** The program reads only a transcript:
a path a hook reported, checked here (absolute, a `.jsonl` under a projects folder,
no `..`, no control character) and again there — its real path under that machine's
own `~/.claude/projects`, opened without following a link or waiting on a pipe and
checked as opened. The asks reach the program as base64, never as text pasted into
it (D83's lesson). The answer is another machine's and is read so: only the ids
asked for, whole non-negative numbers that add up to the file's size, half a
megabyte a file, ssh stopped past twice what was asked; only whole lines are kept,
so no record and no character is cut in two, and a line longer than a read is
stepped over. ssh waits on a thread of its own, never one of the shared pool's.

**Measured on the test Mac.** The end-to-end suite runs the program with `python3`
in a fake home: the tail first, then only what was added, a file that shrank read
again, a link and a path out of the projects not read. A round with a real node
spends a round's tokens and was not run; the ssh is the allowance strip's (B3).

**What a review changed.** One huge `start` from a node would have overflowed the
offset and stopped the app: the answer is now validated as above. The output cap,
the whole lines, the descriptor-based checks on the node and ssh off the pool are
the same review's.

## D95 · A kind of suggestion passed over switches itself off

**Decided.** A kind of LampMaster suggestion that stays under a fifth accepted for two
weeks switches itself off, as the plan's rule against noise asks: one wrong card spoils
trust more than a missing one, and a kind the person keeps passing over costs them
reading for nothing. The count is local and spends no token: of the cards of that kind
in the last two weeks, the ones taken up against the ones ignored, marked wrong or left
to expire — a card still open, or settled because its sessions left, says nothing. Ten
reactions at least, and two weeks of history: a bad first week is not yet a pattern.

**Where it shows, and how it comes back.** Settings lists it among the kinds not
suggested, with "Switched off by itself: 1 of 12 accepted in two weeks", and "Suggest
again" brings it back. From then its record counts afresh, or the old one would switch
it off again at the next round. A kind the person switched off themselves is left alone.

**Measured on the test Mac.** The end-to-end suite writes two weeks of ignored cards of
one kind into a fake home's record; at the next round the real binary switches that
kind off and writes why.

## D102 · LampMaster's test bench replays its saved rounds

**Decided.** `lampboard lampmaster bench` replays LampMaster's last saved rounds — five,
or `--last N` up to fifty — with the model chosen in Settings or `--model`, through the
round's own isolated `claude` and prompt. Both the old answer and the new are screened
by the round's validator, nothing muted and nothing remembered, so the two are judged
alike; then the suggestions are compared by key with the old ones and with what the
person did with them. The report puts first what decides a change: an accepted
suggestion lost is a regression, an ignored one gone is an improvement, a new one is
listed. This is the plan's bench (§8.3): the frames are the ones the rounds already
keep (the last two hundred), they never leave the Mac, and it runs only when asked —
each frame costs a round's tokens.

**Measured on the test Mac.** The end-to-end suite runs a round against a fake
`claude`, then answers the replay with no suggestion: `lampboard lampmaster bench`
replays the one saved round, names the lost card, does not count the one the validator
had refused, and calls `claude` once for it.

## D103 · A background session is a row of its own

**Decided.** A session started with `claude --bg` — the Agent View's, run by its
daemon with nobody at a terminal — is a row, as the plan's §5.14 asks: a session
working unseen is the one a lamp is worth most for. Its live file says `kind: "bg"`,
which the rule for "someone is in front of it" used to refuse along with every other
kind that is not `interactive`; `bg` is now admitted, the SDK's entrypoints still
are not. Its row comes from that file, its process alive, with terminal sessions
shown or not — it is in no terminal — and its origin is its own, `background`,
whatever editor has its folder open: it is in no window either. Its name is its
conversation's, its second line says "background", and a click opens its Plancia,
where its box takes a message like any session's (D81).

**Measured on the test Mac.** A throwaway `claude --bg` with Haiku in a fake home:
its hooks reached the panel and were dropped before this — "no editor window claims
that folder" — even with terminal sessions on, because the file's `kind` was `bg`.
After it, with terminal sessions off, the panel showed it as a row, named by Claude
Code's own title, "background · OK", green once it answered, its answer in "Waiting
for you". Photographed. The end-to-end suite admits a background file's session in a
folder an editor claims, with terminal sessions off, and lists it `[background]`.

**What waits (AV2).** The Agent View keeps more in `~/.claude/jobs/<id>/state.json`:
the one-line summary it generates (`detail`), what a blocked session needs (`needs`).
Using them, and adopting jobs started before the panel, is the next step.

## D104 · A background row reads its job

**Decided.** For each background session (D103), the Agent View keeps a file:
`~/.claude/jobs/<id>/state.json`. Two of its fields go on the row's second line.
- `needs` says what a blocked session is waiting for. It is shown while `tempo` says
  `blocked`, and only then, because the file keeps the last need after the block is over.
- `detail` is the one-line summary Claude Code writes of what the session has done.
  It replaces the first line of the last answer when the row is ready or at rest.

A question the hooks hold is more precise than `needs` and still comes first. A
failure still says why it failed. A working row still names its tool, unless the job
says the session is blocked. The summary can lag the latest answer by a moment, and
that trade is accepted: the answer is a click away, in the Plancia.

*Superseded in part by D130 (1.2): the row now also opens the session in
LampBoard's own live view. The copy stays, for a terminal of one's own.*

The row's menu copies `claude attach <id>`, which reopens the session in a terminal.
It copies and does not run, the way a closed conversation's `claude --resume` is
copied from the bar, because the panel opens no terminal of its own. The id goes
into a shell, so it must be letters, digits, dashes and underscores, and must start
with a letter or a digit. Anything else is no job, and a folder called `--help` is no job.

**Measured on the test Mac.** A throwaway `claude --bg` with Haiku ran in a fake
home, with terminal sessions off. One id, `ef10f0c0`, appeared in five places:
- the folder under `~/.claude/jobs`;
- `claude agents --json`;
- the live file's `jobId`;
- what `claude --bg` printed for `claude attach`;
- the panel's `jobId`.

The row read "ready · background · user request acknowledged", which is Claude
Code's own summary. A session started before the panel is adopted from its live file
with no hook. The end-to-end suite runs that case through summary, need and job
removal. With the poll's job read taken out, that case fails.

**What a review changed.** The first version listed the whole folder on every poll.
The folder keeps every job ever run, so a poll read hundreds of finished jobs to
find the few that are alive. If two jobs named the same session, the winner depended
on listing order. Now each background row reads one file, the one its live file names:
- a file over 256 KB is not a job file;
- a file that names another session is not this row's job.

Two smaller changes came from the same review:
- an id may no longer start with a dash, so it cannot be read as an option;
- format characters are flattened along with control characters, so a bidi override
  cannot reorder what a session says it needs.

The summary and the need travel in `GET /sessions`, which needs the token and
already carries each session's last answer.

## D105 · A decision pinned for a repository reaches every session in it

**Decided.** Parallel sessions in one repository contradict each other because
each one knows only its own conversation: one settles that timestamps are UTC,
the next writes local times. A decision pinned on the board, from the command line
for now (`lampboard decide <repo> <text>`), reaches every session working in that
repository through the companion mod. On `prompt.submit`, before the prompt enters,
the mod asks the panel for its session's board. If the board has changed since that
session last read it, the mod attaches it as context, a block the model reads and
the person does not see. This is the plan's §5.5.

Repositories are keyed by the name the hook script resolves (`GitIdentity.repo`),
the same in every worktree. A session with no repository has no board.

It is kept small because whatever is pinned enters every conversation of that
repository:
- at most twenty decisions a repository;
- one line each, at most 300 characters;
- the same words twice is refused, whatever the case;
- the board reaches a session once per change, not with every prompt.

When the last decision is taken off, a session that was told about it reads one
sentence saying none applies now. A session that was never told reads nothing.

**The first words the mod puts into a conversation, so proven both ways.** Until
now the mod added nothing to a conversation: the band is drawn and never sent, and
LampMaster's answer is the person's to read (D71, D84). This is different, so it
takes the road a permission takes (D80):
- the request carries the token and an HMAC made with `~/.lampboard/check-key`,
  found from HOME;
- the answer counts only when it is signed with that key, over the nonce, the
  version and the words.

A project can point `LAMPBOARD_HOME` at a folder of its own and listen on a port,
but it cannot set HOME, so it can neither ask for a board nor answer with one.
Nothing pinned, no panel, or no signature: the prompt goes as typed.

**Measured on the test Mac.** A throwaway session ran with Haiku in a git
repository in a fake home, with the mod installed and one decision pinned from the
command line. Asked whether anything was pinned, it quoted the decision word for
word. After `undecide`, asked again, it answered "WITHDRAWN". The transcript holds
two `hook_additional_context` attachments, one for each change, and none for the
prompts in between. The probe is `docs/plans/prototipi/bacheca/board-live.sh`.

The end-to-end suite covers:
- pinning, listing and taking off from the command line, with the file kept 0600;
- `/mod/decisions` answering a proven session with its repository's board, signed;
- nothing answered without the proof, or with the token used as the key;
- nothing for a session with no repository.

**What a review changed.** A repository's name comes from the session's own
project, because the hook script runs `git` there. The first version wrote that name
into the withdrawal sentence, which the panel signs, so a project could get words of
its own in front of a model. The sentence now names no repository. A name nobody
could have pinned under, such as one with control characters, counts as no
repository at all.

The rest of the review's fixes:
- A session is recorded as told only once its prompt has entered with the board.
  A dropped prompt does not count.
- A compaction or a restart forgets what a session was told, so the board reaches
  it again.
- The version covers the repository's name as well as the words.
- If the panel cannot say which repository a session is in, it answers nothing. A
  timeout must not read as "nothing pinned" and withdraw what the session was told.
- A prompt waits at most 1.5 seconds on the panel.
- `--port` counts only first or last on the command line, so a decision that
  mentions a port keeps all its words.
- An unreadable board file is set aside, not overwritten by the next pin.

**Limits, said rather than hidden.**
- Pinning needs the token. A process of yours that can read `~/.lampboard/token`
  can pin, but it can also read the key beside it and edit Claude Code's own
  settings. The key keeps out a project that redirects `LAMPBOARD_HOME`, which is
  the threat it is there for.
- Two repositories with the same name share a board. A clone named like another
  project reads that project's decisions. They are your own decisions, and nothing
  more is sent anywhere.
- `undecide` takes off by the number the listing shows, so list first.

**From the panel (B2).** A local row whose session reports a repository has two
items in its menu:
- "Pin a decision for “repo”…" asks for the line, and shows what is already pinned;
- "Pinned decisions (N)" lists them, and one taken off from there is confirmed
  first.

The panel uses the same service the command line reaches through the server, so
the two never disagree. A remote row has neither item, because its sessions would
read the board of the panel over there. The items sit in the menu, the simplest
place there is; where the board shows itself otherwise follows the interface
realignment that opens 0.8 (Marco's answer to question 17). They were not
photographed: a context menu needs a right click, which ssh cannot give.

## D96 · LampMaster's Plancia shows what it did, saw and cost

**Decided.** LampMaster's Plancia (D97) keeps its cards and has three sheets beside
them, as the plan's Plancia of LampMaster asks: *Today*, the day's suggestions with
what became of each; *Frame*, what the last round was given — each session with its
project, machine, state, signals and the precedents found for it, and the allowance
as the round saw it — so a suggestion can be trusted or a wrong one understood;
*Cost*, the day's rounds that ran, were skipped or failed, the tokens against the
ceiling and the cost, the last ten rounds with their model, and each kind of
suggestion on or off with how many were taken up over two weeks and, for one that
switched itself off, why (D95).

**Where it comes from.** The files LampMaster already keeps — its rounds, its
suggestions with their outcomes, the last two hundred frames — read when a sheet is
drawn. Nothing new is recorded, nothing is spent, nothing leaves the Mac.

**Measured on the test Mac.** After one round against a fake `claude` on two
invented conversations each sheet was opened with `--lampmaster today`, `frame` and
`cost` and photographed: the open suggestion, the two sessions, one round of 5,632
tokens and the five kinds on. Released in 0.7.0 in LampMaster's own window; D97 moves
it into the panel.

## D106 · Releases are signed on the test Mac, in a keychain of their own

**Decided.** Marco travels, and the MacBook that held the Developer ID identities
is often off, so he moved signing to the test Mac's `marco` account: «Sposta tutto
tu sei autorizzato» (question 20). The two identities (Application and Installer)
and the notarytool profile `lampboard` live there in
`~/Library/Keychains/lampboard-release.keychain-db`. That keychain is not the login
keychain, because nobody logs into that account. Its password sits in a file only
`marco` can read, and `release.sh` unlocks it in its own session, as an ssh session
needs.

`release.sh` and `make-pkg.sh` take the keychain from `LAMPBOARD_NOTARY_KEYCHAIN`
and pass it to notarytool, which otherwise looks only in the login keychain.
`Scripts/release-remote.sh vX.Y.Z`, run from the machine the loop works on:
- sends the tag to the mirror;
- runs the release on that account over ssh;
- brings the four files back for `gh release create`.

Nothing secret crosses that connection.

**How the identities got there.** Exported once from the MacBook's keychain by
Marco. Over ssh that keychain refuses to export a private key ("User interaction
is not allowed"). The export file and its password were copied machine to machine
and never through a conversation, then deleted from both Macs once imported.

The Application certificate is issued by Apple's "Developer ID Certification
Authority" G2. The test Mac had only the older intermediate, so the identity stayed
"not trusted" until G2, downloaded from apple.com, went into the same keychain.

**Measured.** A probe binary was signed with the hardened runtime and a timestamp,
verified strictly, and submitted to Apple through the profile in that keychain:
`Accepted`.

**What the first real release taught (0.7.0).** Two things broke, and both are fixed.
- The test Mac dropped off the network twice in an hour, and the first
  `release-remote.sh` held one ssh open for the whole release, so it hung with the
  connection. The release now runs detached on the signing account, writes its exit
  status beside its log, and is asked after every half minute. Each step that has to
  reach the Mac is tried for ten minutes before it gives up.
- The package would not sign from a detached process. `pkgbuild` was given no
  keychain, so it went to the login keychain, which is locked when nobody logs in;
  and the Installer key did not list `pkgbuild` among the programs it trusts, so asking
  it meant a dialog nobody could see. `make-pkg.sh` now names the release keychain, and
  the identities are imported trusting `codesign`, `productsign`, `pkgbuild`,
  `productbuild` and `security`.

0.7.0's package was rebuilt that way from the tag's own signed app, with the corrected
`make-pkg.sh`: the same binary, packaged by a script one commit newer than the tag.
`make-cask.sh` also stopped using the BSD-only form of `mktemp`, since the releases
are now driven from Linux.

## D107 · A click opens that conversation in the Claude app

**Decided.** A row for a conversation in the Claude app's Code tab used to raise
the app and nothing more, whatever conversation the app was showing. The app files
each Code conversation in
`~/Library/Application Support/Claude/claude-code-sessions/<organisation>/<account>/local_<id>.json`.
That index names two ids:
- its own, `local_<id>`;
- the transcript's, `cliSessionId`, the session id every hook carries.

The app's code (2.19675) has a link that opens a conversation by its own id:
`claude://code/continue?session=local_<id>`, accepted only in the shape
`^local_[A-Za-z0-9-]{1,64}$`. A click now finds the index whose `cliSessionId` is
the row's session and opens that link. It looks first for the file named after the
session, which is the name a conversation brought over from a terminal keeps. A
conversation the app does not file that way still raises the app, as before.

The id is read at the click and never on a timer, because a person is waiting. The
link is built only from an id in the shape the app itself accepts, so nothing read
from the disk can add a parameter to it.

**Also found.** A row for one of these conversations can carry the origin
"terminal": its session file is admitted like any terminal session's when terminal
sessions are on. Its click went looking for a terminal tab there is none of. The
app's branch now comes before the terminal's.

**Measured on the test Mac**, on Marco's account with his yes (question 23). Two
throwaway conversations, ALPHA and BETA, were made with `claude -p` and Haiku in two
empty folders, then brought into the Code tab with `claude://resume?session=<id>`.
With the app on BETA, `lampboard open 1` on the ALPHA row brought ALPHA up. Only the
conversation pane was photographed, with the sidebar of real sessions cut away, and
the photographs were deleted afterwards. The probe is
`docs/plans/prototipi/desktop/desk-click.sh`.

The first run found no index, for a reason worth keeping: a directory listing does
not follow a symbolic link, and the probe's home links the app's folder. The folder
is now resolved before it is listed.

**Not done.** `claude://code/new?q=…&folder=…` starts a conversation, but it stops on
the app's trust dialog for the folder, and nothing outside the app can answer that
dialog, so the panel does not use it.

## D97 · LampMaster is the panel's first row, with a Plancia of its own

**Decided.** As the interface plan asks — more in the panel, no separate windows —
LampMaster is the first row of the wide panel, fixed, with its teal star where a lamp
would be and what the last round found on its second line; it never blinks. A click
opens its Plancia beside the list, like a session's: its cards, Today, Frame and Cost
(D96), pinned or closing by itself like any Plancia. The window of its own (D61) is
gone; the narrow panel keeps its one line. `--lampmaster <sheet>` opens that Plancia.

**What changes from D61.** D61 put the cards in a window because a sentence of any
length cannot live in a panel whose height is a formula. The Plancia has a height of
its own and scrolls, so that reason holds there no longer; the row itself is a
measured height, counted with the gap under it.

**Measured on the test Mac.** On the trial's panel: LampMaster the first row under
"Waiting for you", one suggestion counted, the last row still whole above the
allowance; its Plancia open on Suggestions with the card, its evidence and actions,
and on Today. Photographed, invented sessions only. Marco chose to finish 0.7
first and realign after it (question 17, answer (b)); this opens 0.8.

## D98 · The Plancia says which session it is, where, and what can be done

**Decided.** Above every tab of a session's Plancia, as the interface plan's §5 asks:
its lamp, its name, and on one line what a person wants to know before acting on it —
the machine, the surface and the agent, the model by its name ("Opus 5.5", not an id),
how full its context is ("121k of 1.0M"), what it has cost. What is not known is left
out, never guessed. Under it, what can be done from here, each the row's own action:
*Go* raises its window, *Hand over* opens the bar on `/handoff @this @` for the person to
name who takes over (D91), *Mute* silences its project's notifications. The thread's
own title is not repeated under it. *Resume* waits for closed conversations in the
Plancia, *Focus* for the governor (0.8).

**Measured on the test Mac.** On the trial's panel, the Plancia open on "events":
"this Mac · editor · Claude Code · Opus 5.5 · 121k of 1.0M" and the three buttons.
Photographed, invented sessions only. Like D97, it waits for Marco's question 17.

## D99 · Two sessions on one file show it on their rows

**Decided.** When two live sessions have written the same file of the same checkout
in the last two hours, both rows carry a red ⚠ beside the name, and its tooltip says
which file and which session: "Two sessions on the same file: routes.ts also written
by events". Today that is found at the merge; the interface plan's row (§4) wants it
while it happens. It comes from what the companion mods already report — each
`Edit`, `Write`, `MultiEdit` or `NotebookEdit` with its absolute path — so a session
without the mod is not seen, and two worktrees of one repository are two checkouts,
not a conflict. Nothing is stopped: the ⚠ says; the preventive radar that holds the
second write is 0.8's (§4.4).

**What waits.** The plan's other badges need data the panel does not have yet: the
prompt cache's remaining minutes want a measurement of its lifetime on the test Mac,
not a guess (R3b); unread messages in a session's thread need a count kept per
session (R3c). The row's second line already says the machine and what the session
is doing; the agent is the letter in its ring.

**Measured on the test Mac.** On the trial's panel, two invented sessions reported
an `Edit` of the same path through `/mod` as their mods would: both rows showed the
⚠, the others none. Photographed. Like D97, it waits for Marco's question 17.

## D100 · A waiting row says how long its prompt cache stays warm

**Decided.** While a session waits for the person — an answer to read, a question, a
failed turn, an idle prompt — its row shows the prompt cache's minutes, "⟳43m": answered
before they run out, the next reply reads the conversation back cheaply; after, it is
written again in full and the account pays for it. Nothing is guessed: each reply's
usage in the transcript says how its cache was written, `ephemeral_1h` or
`ephemeral_5m`, and a reply that only read it keeps that lifetime, refreshed; the clock
starts at the last reply. Where no write is in sight, or once it has gone cold, nothing
is shown. A count the mod reported (D65) is still not replaced by the transcript's, but
takes its cache clock.

**Measured.** This machine's own transcripts write the cache for an hour
(`ephemeral_1h_input_tokens`), the reason the plan's measurement was not needed. On the
trial's panel, whose transcripts now carry the same field, the waiting rows showed
"⟳60m" and the working ones nothing. Writing the test found that the context reader
could not parse Claude Code's millisecond timestamps (traps): fixed with it.

## D101 · A session's Plancia carries its waiting card at the top

**Decided.** When the session in a Plancia is waiting for something — a permission, a
question, an answer to read — its card from "Waiting for you" is pinned under the
header, as the interface plan's §5 asks: the same card, with the same buttons armed
after the same delay, answered from here as from the queue. A session that waits for
nothing shows nothing there.

**Measured on the test Mac.** On the trial's panel, its Plancia opened on the session
waiting for an answer through the band's own door (`/mod/band/open`, D84), the card
showed under the header. Photographed, invented sessions only. Like D97, it waits for
Marco's question 17.

## D108 · A row counts the answers nobody has read

**Decided.** The interface plan gives a row a teal ✉n for unread messages (§4). A
row already turns green when there is an answer to read; what green cannot say is
how many. A session can answer, be woken by its own background work or by another
session's message, and answer again, all while nobody reads. Each `SessionState`
now counts the turns that ended with something to read since the person last
looked. Clicking the row clears the count, and so does a prompt, because the person
was there to type it. A turn that failed, or that ended still waiting on work, adds
nothing. "Mark as unread" brings back one answer, never more.

The mark appears from two on, because one is what green already says. A project row
sums the green conversations it holds. `GET /sessions` publishes `unreadAnswers`,
optional on the wire, so an older panel's answer still decodes.

**Measured on the test Mac.** On the trial panel (invented sessions), a resting
session was sent two turns with no prompt, through `/signal`. Its row read
`docs-site ⟳60m ✉3`: the trial's own answer plus the two new ones. The end-to-end
suite drives the real binary through two wakings, then a prompt, and checks the
count goes to 2 and then to 0.

The photograph needed the test Mac's display awake: `screencapture -l` fails on a
sleeping display ("could not create image from window"), and `caffeinate -u` wakes
it for the moment needed. Noted in the traps.

## D109 · The week in tiles, with the time sessions waited on you

**Decided.** The interface plan draws the week as tiles, with the hours spent
waiting on you (§7). "This week" in the bar now opens on six tiles: prompts,
conversations, projects, active days, the busiest day, and the time sessions
waited on you. The projects follow as before, in the same scrolling space.
`lampboard week` stays a paragraph, with the waiting as one more sentence.

**How the waiting is counted.** It comes from the search index, which already holds
when each prompt was typed and when each answer was written; no new record is kept
and only times are read, never words. For every prompt of the week, the wait is the
time since the last answer that came after the prompt before it, in the same
conversation. A gap over four hours counts as nothing, because that is you away,
not a session waiting on you. Answers from the four hours before the week are read
too, since one of them may be what the week's first prompt answered.

**Measured on the test Mac.** Four invented conversations over five days, each
answer twelve minutes after its prompt, gave "11 prompts in 4 conversations,
3 projects, 5 days. Busiest: Sunday, 4 prompts. Sessions waited on you 3h 50m."
The trial panel with `--bar-type "this week"` showed the six tiles and was
photographed. The end-to-end suite runs `lampboard week` on one answer and the
prompt 25 minutes after it, and checks for "waited on you 25m".

## D110 · One session in focus, the others wait

**Decided.** The plan's §5.3: one session in the foreground, the others served after
it. *Focus on this session*, in the row's menu or as a button in its Plancia header,
puts the session there and marks its row with a teal pin. Choosing it again takes
it off. While a session is in focus, `SessionNotifier` holds the notifications of
every other session: a permission, a failure and, for those who asked for them,
finished turns. The rows still change colour, so the panel says everything and only
the interruptions wait.

When the focus is taken off, or its session ends, one notification says what
waited, the most urgent kind first, with the names: "While you were focused: 1
waiting for you (api), 1 failed (billing), 2 answers (docs-site, search)." A session
is counted once per kind, so one that failed three times is one failure in the line.
The choice is kept across launches, and a focus on a session that is gone counts as
no focus.

The summary says only what is still so when the focus comes off. A session answered
or gone in the meantime is left out, as is a project muted since, and nothing sounds
while all notifications are silenced. Once the focused session has been seen and
ends, the focus is cleared, so it does not come back if that id is ever resumed.
A code review asked for these.

The governor (G2, G3) will treat the session in focus as the one to protect: it keeps
its model when the others are lowered.

**Measured on the test Mac.** The trial panel with `focus.session` set to the
invented `events` session showed the pin beside its name. The hold and its summary
are covered by the domain suite. Notifications cannot be sent from the test suites,
which do not run as a bundle.

## D111 · The strip says when the window runs out, at this pace

**Decided.** The plan's §5.2 begins with a sentence only this panel can say,
because only it sees every session of an account at once: "at this pace you run
out at 11:40, and the window resets at 13:10". `AllowanceMonitor` keeps each
account's session-window readings for two hours. `AllowanceForecast` draws a
straight line through the readings of the last hour since the last reset, using
least squares, and finds where the line reaches a hundred. A reading lower than the
one before it marks a reset and starts the history again.

The pace is read over an hour: long enough to smooth one busy turn, short enough to
notice that three sessions have just started. A forecast needs at least ten minutes
of readings on a line that climbs; anything less is no forecast, never a guess.

The strip changes only when the forecast matters, which is when the window would run
out before it resets. The time it runs out then takes the reset's place at the end
of the line, in the warning orange, and hovering it gives the whole sentence. A
forecast past the reset changes nothing and is not shown.

**Not photographed.** It needs an hour of real readings, and the trial's allowance
line is one invented figure. The domain suite covers it:
- the pace and the time it runs out;
- too little to fit: one reading, five minutes, a flat line;
- a reset starting the history again;
- the sentence only when the window would run out before it resets.

Who is burning the most, and what to do about it, is the next step (G3).

## D112 · A session lowered one model until the window resets

**Decided.** The plan's §5.2 asks the panel, which alone sees every session of an
account, to lower the model of the sessions that matter less when the window is
running out. The person chooses, from a row's menu: *Use Sonnet until the window
resets (13:10)* lowers an Opus session one step, and Haiku is offered for a Sonnet
one. The session in focus is never offered. The rule:
- one step down, never further, and only on a click;
- until the session window resets; after the reset the session is back on its own
  model with nobody having to undo anything;
- choosing the item again gives the model back sooner.

**How it reaches the session.** The plan is kept in `~/.lampboard/governor.json`
(0600) and read again whenever the file changes. The companion mod (1.11.0) asks
`/mod/governor` once per turn, at `turn.start`. Like the decision board (D105), the
request carries the token and a proof made with the permission key, and the answer
counts only when signed with it, because choosing a model means spending. Every
`turn.step` of that turn then names the lowered model; a subagent's steps keep the
model they were given.

**Measured on the test Mac.** Two steps.
- A throwaway probe mod rewriting `turn.step`'s model showed that the engine obeys:
  a session started on Sonnet answered as `claude-haiku-4-5`.
- Then the whole chain: LampBoard's own mod, a session on Sonnet, and the panel's
  plan lowering it. Its answers in the transcript came from `claude-haiku-4-5`.

The end-to-end suite runs `/mod/governor`. It answers a proven session with its
lowered model, signed; another session with "its own"; and nothing without the
proof.

**Two traps on the way, now behind a gate.** Claude Code checks a mod's module
before it runs any of it, and one broken rule drops the whole module from every
session, without a word. Both of these did it:
- a `turn.step` hook written as an ordinary `async` function, when a streaming
  event needs an async generator;
- a variable named `model`, the name of a function the module hands `$` to.

`Scripts/check-mod.sh` now asks `claude plugin validate`, as part of the gate, and
`bite.sh` breaks the hook on purpose to prove the check bites.

**What a review changed.**
- The mod now asks before the turn goes on, and every step waits for that answer.
  The first version asked afterwards, so the first step of a turn could still run
  on the old model.
- The reset used is the nearest one still ahead. With two accounts, a session's own
  account is not known here, and the nearer reset cannot lower a session for longer
  than its window.
- A session put in focus after it was lowered goes back to its own model at its next
  turn.
- A session on a million-token window is not offered a step down, because the
  smaller model's window may not hold its conversation.
- A write that fails leaves the plan to be read again from the disk.

Left as they are, and said here: the mod fails open, so with the panel closed or
slow a lowered session runs on its own model; and a turn that runs past the reset
stays lowered until it ends.

**Left out on purpose.** "Pause until the reset", which would mean holding a
session's prompts. So is the sheet of sessions ranked by consumption: the menu item
sits on the row a person is already looking at, and the strip's forecast (D111) says
when it is worth using.

## D113 · The radar: a file another session just wrote is asked about first

**Decided.** The row's ⚠ (D99) says two sessions wrote the same file after they
both did. The plan's radar (§4.4) says it before the second one writes. In
`tool.check`, when the engine would let an Edit, Write, MultiEdit or NotebookEdit go
ahead on its own, the companion mod (1.12.0) asks `/mod/radar` whether another live
session wrote that file in the last two hours. If one did:
- the edit becomes a question to the person;
- a line at the session's foot names the file, the other session and when.

The edit dialog itself does not show a hook's reason, so the line carries it. The
request and the answer are proven both ways with the permission key, like every
sentence the panel puts in front of a session (D80, D105). The other session's name
is flattened to one line, its control and format characters gone.

Only what would have gone ahead is turned into a question. An edit the engine would
already ask about is left to the permission path as before, and nothing is ever
denied. In auto mode a question goes to the mode's own judge, not to the person, so
there the line at the foot is the whole warning. That is said in the README rather
than worked around.

**What a review changed.**
- The path is compared in the form the activity log keeps: masked, flattened and
  cut at 120 characters. A long path used never to match. Two long paths that agree
  up to the cut now read as one, and the most that can cost is a question.
- A notebook's path is recorded too.
- The wait on every write the engine would allow is 0.6 seconds at most, and the
  timer is cleared on a failed request as well.
- The file name in the sentence is cleaned like the session's name.
- The cleaning itself was sharpened. Bidi marks become a space, a joiner stays so
  that emoji and scripts keep their shape, and other invisible characters go.
  Foundation counts format characters among the control characters, so they are
  sorted first.

**Also changed.** The mod's tool reports now reach the activity log with or without a
panel on screen. The radar answers from that log, and a headless panel, the way the
end-to-end suite runs, heard nothing before.

**Measured on the test Mac.** Two throwaway Haiku sessions in one folder, with
LampBoard's mod, both in `acceptEdits`. A wrote `notes.txt`. Asked to change it, B
stopped on "Do you want to make this edit to notes.txt?" instead of editing, and
its foot read "LampBoard · notes.txt was written by …". The file still said
"hello". The end-to-end suite runs the route:
- another session's reported write is answered with the signed sentence;
- a session's own write is "clear";
- nothing is answered without the proof.

## D114 · I'm away: nothing interrupts, one line on return

**Decided.** The plan's §5.8. Being away is said from the panel's menu, *I'm away:
hold alerts, sum up when I'm back*, and kept across a relaunch. A screen locked for
three minutes says it too: long enough that locking to fetch a coffee is not an
absence. While the person is away, `SessionNotifier` sends nothing, and an
`AwayLedger` counts from the moment they left:
- each turn that ended with an answer, per session;
- each session whose turn failed;
- what every session's cost rose by, as the mod reports it.

The counting happens as things happen, so a session that answered and was closed
in the meantime still answered. On return one line says it all, with what is still
waiting for an answer read from the column at that moment: "While you were away
(1h 20m): 3 answers (api, docs-site), 1 waiting for you (api), 1 failed (billing),
$2.10 spent." An absence where nothing happened says so. The line arrives as one
notification and stays at the foot of the panel, in the place and height of the
issue strip, until it is clicked away. A fault to fix takes that place first.

**Not yet.** The plan also has the mod hold risky commands while the person is
away, so they do not wait on a dialog nobody sees. That is the next step (A2). With
Remote Control on, a session's own approvals already reach a phone.

**Measured on the test Mac.** The trial panel started away and was brought back
twenty-five seconds later by turning the preference off from outside. Its foot read
"While you were away (0m): 1 answer (docs-site), 1 waiting for you …" and was
photographed. Since then, an absence under a minute reads "under a minute". The
ledger is covered by the domain suite. Notifications cannot be sent from the test
suites, which do not run as a bundle.

## D115 · The light's shape: dashed when stuck, hollow without the mod

**Decided.** Marco's answer to question 25 kept the panel always dark. The colours
and the glow were already the prototype's, so what was left of the visual pass (R4)
was the two shapes the interface plan gives the light (§4, and §11: never colour
alone):
- **Dashed**, in the working yellow, while a session is working but has sat on one
  tool past a quarter of an hour (the same rule as the `⌛` on its card).
- **Hollow**, for a local Claude Code session the companion mod does not speak for.
  Only while some other session's mod is heard from: without the mod at all, every
  light would be hollow and none would stand out. Only after the session has had two
  minutes to be heard.

Both are drawn inside the light's own eleven points, so a row's layout does not
move. The legend explains them and counts the dashed ones.

**Measured on the test Mac.** The legend, opened with a new launch option
`--legend`, was photographed with both shapes. The trial panel's lights stayed
solid, as they should: its invented sessions are new and none is stuck. The rule is
covered by the domain suite.

## D116 · Away, a destructive command waits for the person

**Decided.** The second half of the plan's §5.8. While the person is away (D114), a
shell command that the engine would run on its own and that the impact rules (D87)
name as destructive is put to them instead. It then waits for their return rather
than running unseen. The destructive commands are the ones that delete recursively,
force-push, discard changes, run a downloaded script, drop data, overwrite a disk,
change permissions recursively, or run as root.

Before such a command the companion mod (1.13.0) asks `/mod/hold` with the whole
command, every line, proven with the permission key, and takes only a signed answer.
A command longer than 4,000 characters is sent cut there, and the proof says so.
The panel says "hold" only when it is away and some line is destructive, judged as
written: the masking that keeps secrets off a card could swallow the very words
that make a command destructive. While away, a command too long to read whole is
held unread. Anything else goes as it would have: the person here, a harmless
command, a command the engine would already ask about, or no answer in 1.5 seconds.
Away is read from a locked flag, not from the main thread, so a busy panel still
answers in time. The session's foot shows the sentence, and so does Claude Code's
own dialog: "Held while you are away: this command deletes recursively. It waits
for you." Since the held command waits on a permission, the summary on return counts
it among what is waiting for you.

The rules are D87's fixed set of spellings, not a reading of the shell. A
destructive command they do not name goes: `rsync --delete`, `find -delete`,
`docker system prune`, `kubectl delete`, `git clean`, a `DROP` inside a script
file, an alias, or a command assembled from variables. The hold is a seatbelt
for the common slips of a session left alone. It is not a sandbox, and the
permission settings remain the person's real boundary.

The radar (D113) and the hold share one question in the mod, `signedVerdict`: a
verdict and a sentence, signed over both.

**Measured on the test Mac.** A panel set to away, and a throwaway Haiku session
whose settings allow `rm` without asking (`--allowedTools 'Bash(rm:*)'`), asked to
run `rm -rf build`. It stopped on "Do you want to proceed?" under "Held while you
are away: this command deletes recursively. It waits for you. [plugin:lampboard]",
and the folder was still there. The same happened when the deletion was the second
line of a command whose first line was `echo ok`. The end-to-end suite runs the route on a headless
instance, where nobody is away: "go", and nothing without the proof.

## D117 · A session waiting, said aloud to someone away from the keys

**Decided.** The plan's §5.9, marked there as cheap and to be tried. A notification
is a banner, and a banner reaches only someone looking at the screen. Someone
across the room, with the Mac open on the desk, hears a sentence. With *Say it
aloud when I'm away from the keys* on, the notification for a session waiting for
you is also spoken: "docs-site is waiting for you." It is off by default, because
a Mac that talks is a surprise to opt into.

It speaks when three things hold. Nobody has touched the keyboard or the mouse for
a minute; someone typing already has the banner. The screen is unlocked, since a
locked screen is an empty room, or an absence that D114 is about to count. And the
notification for that wait was handed to macOS. So every silence that holds a
notification (away, muted, a muted project, a session in focus) holds the voice too,
and a bare binary (a test panel, a `swift run`) never speaks. The voice adds no gate
of its own and no second memory: one wait, one sentence. A banner macOS then refuses
to show is still spoken, which makes the voice the only way that wait is said. The
single line that sums up what waited during a focus is not spoken. A new sentence
cuts the one still being said, so a burst says its last, not a queue that goes on
after the person is back. Idleness is read once, when the sentence starts, and a
sentence already under way is not cut when a key is pressed.

**The panel speaks, not the mod.** The plan named the mod's `$.audio.speak`. The
panel's own synthesizer (`AVSpeechSynthesizer`) says the same with nothing
installed in Claude Code. It covers Codex and every session without the mod, and
it keeps one voice, rather than one per session process, in the place that already
knows about the silences, the focus and the idle time. Answering aloud needs
nothing new: the panel's dictation (D18) is already there.

`SpokenAlert` decides and words it. The name is the row's, flattened, with no
control or bidi character, and cut at forty characters, since past that a name is
a path. A row without a name is "A session".

**Measured on the test Mac.** A test panel with notifications and the voice on, and
a session that started waiting for a permission. The screen was locked, and the log
said "not spoken (idle 17177 s, locked)". That run came before the voice was tied to
the banner; a test panel now stays silent before it gets that far. The synthesizer renders the sentence on
that Mac, since `say -o` writes it to a file. Playback could not be heard there:
the test Mac is a laptop with its lid closed, and every sound hangs, `afplay`
included. An utterance with no way out is simply never finished. The synthesizer
does not hold the main thread, so a Mac without a speaker loses the sentence,
not the panel. The log says "speaking", then "spoken" once an utterance has been
heard to the end.

## D118 · LampMaster in conversation, from its Plancia

**Decided.** The plan's D8 for LampMaster, the first 1.0 step. *Today*, in
LampMaster's Plancia, opens on a box: a question about all the sessions at once,
answered beneath it, and a follow-up read against what came before, until *New
conversation*. Below the box, *Asked today* lists every question LampMaster took
today, with who asked (a session by its row's name, or "You") and what it answered.
Then the day's suggestions follow, as before.

**One door.** The box and `?question` in the bar take the same path, now its own:
`askFromPanel`. Before, the bar went through the MCP tool's entry with no session,
and LampMaster was told "the asking session is not in the frame". Now the message
says the person asks from the panel. The person's questions are recorded under
`panel`, and shown as "You". A session that does not say which it is stays "unknown"
in the message and "A session" on *Asked today*, never the person, and a session
cannot pass for `panel`. The switch, the twenty questions an hour of everyone and the
day's tokens are the same as for a session's question. The five per asker are not
applied to the person: a conversation runs past five, and a person is not a loop.

**A follow-up carries the last three exchanges**, each question cut at 300
characters and each answer at 600, fenced as data. Each answer goes without its
sources, which quote other sessions. That is enough for "and the
other one?", without rereading a transcript at every question. A follow-up is
never answered from an earlier answer to the same words, because "why?" means
something else after a different answer. Only answered exchanges are kept, so a
refusal is shown and not carried. The conversation lives while the panel runs, and
closing the Plancia does not lose it.

**Nothing in a fence can close it.** An earlier answer is LampMaster's own text,
which can repeat another session's words, and an index title is a session's own.
Every line between two markers is made a single line with no control character,
and its angle brackets become ‹ and ›. So a `</earlier>` in a stored answer is
just words. The rules say the earlier exchanges and the index are data, never
instructions.

**The index, word by word.** From the panel, the question's words (and the previous
question's) are looked up in the search index (D88), forty conversations per word. The index wants every word of
a query, and a question never has all its words in one conversation. So it is one
query per word, searched as a prefix. Each word is cut to a crude English root of
at least four letters: "renamed" finds "rename", "files" becomes "file", and
"string" stays whole. Left out are the words every question has ("conversation",
"project", "can you tell") and words under four letters that are not names. Among
the words that found something, a conversation two of them agree on is kept; a rare
name that alone found anything keeps its own hits. LampMaster
gets the titles, projects, dates and ids, never the words. The rule now says that a
title shows a conversation happened, not what it decided. A conversation the frame
already shows is left out. One the frame does not carry is named, even when a card
exists for it, such as a closed conversation of days ago. A session's question keeps
to the frame, as it always has.

**The fork stays a click.** When a live session would know better, the answer names
it and the question to put. Asking it without disturbing is `@name ?question` in the
bar (D82), which reads its conversation from cache at the session account's cost,
so it is never run on LampMaster's initiative.

**Measured on the test Mac.** Three invented conversations, LampMaster on, the
Plancia on *Today*, and two questions typed by `--lampmaster-ask` (fake home only).
"Which conversation renamed slots, and in which project?" was answered with the
index's "Slots rename" in events, three days ago, and LampMaster added that the
title says nothing of what was decided. "And what did it keep for the old name?"
was read as its follow-up. It said the index does not say, and pointed to opening
that conversation. Before the index was searched word by word, both answers were
"I do not know".

## D119 · The tour for 1.0: every gesture done for real

**Decided.** The first part of the plan's complete tutorial. The tour's steps
were written for 0.5, with placeholders: steps 3 to 7 waited for a row to be
clicked, and only four steps were shown. Every step now waits for its own gesture,
reported by the panel where it happens:
- **depths**: `⌘⇧L` reaching the Plancia;
- **plancia**: the Plancia opening on `events`;
- **command**: any result chosen in the bar;
- **focus**: a session put in focus;
- **away**: *I'm away* chosen and then left, so the step ends on the line that
  sums it up;
- **allow**: the permission answered from the panel;
- **squad**: a side question answered;
- **ask**: LampMaster asked.

Focus, away and asking LampMaster are new steps, for 0.7, 0.8 and D118.

The trial shows nine of the twelve. Answering a permission, a side question and a
question to LampMaster all need an answer the trial does not have: no mod holds
the demo permission, no fork answers for an invented session, and LampMaster
would run a real model. Those three steps stay hidden until the trial scripts
their answers. A step the trial cannot complete would stop the tour there.

Every sentence fits the band's two lines in the narrow panel, a hundred characters
at most, and a test holds it there. The first photograph cut "away" at its second
line.

`--tour-step <id>` opens the tour on one step, against a fake home only, for
photographs and the site's screenshots. A step shown that way is never saved, so
it cannot replace the person's own place in the tour.

The review found that the plancia step said "press Space", which nothing in the
panel answers. It now says to right-click events and choose *Open in the
Plancia*, the gesture that is really there.

**Measured on the test Mac.** A trial with `--tour-step depths --plancia`: `⌘⇧L`
opened the Plancia and the band moved to "plancia", 4 of 9. With `--tour-step
command --bar-type "@ev"`, the bar's choice moved it to "allowance", 6 of 9.

## D120 · The trial plays the answers no mod or model gives there

**Decided.** The second part of the complete tutorial. Three of D119's twelve
steps waited on answers the trial could not give, so they were hidden. They are now
played from the script, and the tour shows all twelve.
- **Allow from the panel.** No mod holds the demo's permission. So once `api` is
  amber, the trial books the script's own ask on the permission desk: "Bash: npm
  publish", the same request a mod would put, with nobody waiting on its
  connection. It is booked only while the tour stands on "allow", where answering
  it counts; before that an answer would do nothing. The card has Allow and Deny
  like a real one, and answering it moves the tour on. If its 55 seconds run out
  unanswered, it is booked again a few seconds later, without the notice that it
  went back to a dialog, since there is none. A tour skipped on that step and
  resumed gets its card back; past the step, or finished, never again
  (`Tour.trialPermission`, tested).
- **A side question.** `@events ?…` is answered with the script's line about the
  calendar still calling `/api/v2/slots`. Every invented session is askable from
  the bar in the trial. Asking any other one gets a plain sentence that only events answers
  there.
- **A question to LampMaster.** The bar and the Plancia's box get the script's
  reply. That reply ends by saying that in the trial LampMaster's answers are
  written in advance. A trial never runs a model: the script's answer stands in
  for the run, and the question is recorded under `panel` like a real one, shown as
"You".

The trial switches on, in its own preferences only, answering from the panel and
sending to sessions. The real panel's switches stay as they are. The answers are
checked by the same rule as the rest of the script: nothing real.

**Measured on the test Mac.** With `--tour-step allow`, the api card appeared with
Deny and Allow, and an Allow through the fake-home test route moved the band to
depths, 4 of 12. `@events ?what changed in the calendar` showed the script's answer
and moved the band from squad to allowance. `?who renamed the slots endpoint`
showed LampMaster's scripted reply, and the tour ended on "Done". The probe's
`--bar-type` now also chooses a question to LampMaster.

## D121 · A ring around what the step speaks of

**Decided.** The last piece of the tour that T1.3 left for later. While a step is
on screen, what it speaks of is ringed in LampMaster's teal: the row of the session
it names (docs-site, api, events), the bar, the allowance, LampMaster's row or
strip, or the ⋯ that opens the panel's menu. The ring sits a point outside the
element and breathes slowly. With *Reduce motion* it holds still. The breath belongs
to the stroke, which is born and gone with the ring, so a ring that comes back on
the same element (events at plancia and at focus, the bar at command and at ask)
breathes again: the review found it would otherwise come back still.

It never takes a click and VoiceOver does not read it, because the band already
says it in words. Outside a trial there is no tour, and the modifier draws nothing.
Every step's anchor is checked against the script's sessions by a test, so a step
cannot point at a row that is not there.

**Photographed on the test Mac.** On step 1 the docs-site row was ringed, and on
"away" the ⋯ in the footer was.

## D122 · Getting started says what 1.0 does

**Decided.** The last part of the complete tutorial's app side. *Getting started*
was written for 0.5 and had fallen behind in three ways.

- **The mod's description was no longer true.** It said the mod reads no
  conversation and runs nothing. The item now says what the mod can change. It
  never runs a tool or writes a file itself. It can make Claude Code ask first:
  before an edit to a file another session just wrote (D113), and, while the person
  is away, before a destructive command (D116). It answers a side question or a
  handoff from the session's conversation, read again from cache (D82, D91). And it
  lowers a session's model when the panel is asked to (D112).
- **Two switches were missing.** Writing to a session from the panel needs the
  hooks (D81), not the mod; only its side question does. Answering permissions from
  the panel needs the mod. Each is set up from here, explained before its button,
  and ticked only when it can work, so the switch alone is not enough. Its button
  says what to set up first if that is missing. A permission waits 55 seconds with
  Allow and Deny; a question waits 20 with its options. Writing goes through the
  panel's own switch, which explains what it opens before it opens it. That button,
  like the one for notifications, only ever turns its switch on, whatever the list
  last read.
- **A first step was missing.** Asking LampMaster about all the sessions, from the
  bar or the Plancia's box. It is ticked by a question recorded under `panel`
  (D118), told apart from a session's question, which ticks its own step. It is
  optional while LampMaster is off.

The setup's order follows dependency: hooks, Accessibility, writing (which needs
the hooks), the mod, answering (which needs the mod), then the optional rest. The
tour is no longer "three minutes". It has twelve steps, each done by doing it. The
review found the first version claiming that writing needed the mod and a button
that could turn sending off, and both are fixed.

**Photographed on the test Mac**, on a fake home: the new items with their buttons,
and Accessibility already ticked.

## D123 · The card beside the panel, and the defects that outlive 1.1

**Decided.** The first step of the 1.1 review (U1): what was broken in 1.0 and
stays in 1.1. Five experts tried the product from scratch on 7 October 2026.

- **The card went under the panel.** It was placed below and to the right of the
  pointer, and the pointer is always inside the panel: when the card turned left it
  landed on the panel's rows. In the menu bar the panel sits at `.popUpMenu`, above
  the card's `.floating`, so the card was drawn under it and came out cut. It is now
  one level above the window it explains, and anchored to that window's edge: right
  when it fits, else left, else under, else above. Only its height follows the
  pointer (`TooltipPlacement`). Measured on the test Mac: card at x 758–1076, panel
  from 1084, one layer above.
- **The card vanished after about seven seconds.** SwiftUI reports a hover exit when
  it rebuilds the view under a still pointer. An exit with the pointer where it was
  when the card appeared is ignored, as long as the window it explains is still on
  screen under the pointer (checked every second, so a panel put away under a still
  pointer takes its card with it). When rows reorder, arrive or leave, the card is
  taken away, because another row may be under the pointer now. Measured: the card stays 13 seconds
  and more with the pointer still.
- **Two accounts called the same.** The line kept the part before the @, so two
  addresses became «marco» and «marco». It now keeps the domain when the local parts
  collide, and the whole address when nothing shorter tells them apart.
- **«0% —»**, a window that has not started, is no longer a line. A spent weekly
  limit still is: it stops the work whatever the session window says.
- **The two last columns were 44 and 34 points wide.** One width now.
- **Remove the hooks and Clear the list asked nothing.** Both confirm first.
- **LampBoard is spelt LampBoard** in every window title, alert and menu entry; the
  command stays `lampboard`. LampMaster's two token figures are formatted the same
  way.

What 1.1 removes is not fixed here: the queue's names and cut texts go with the
queue (U2), the stacked trials and their missing exit with the trial (U4).

## D124 · The panel without its copies

**Decided.** The second step of the 1.1 review (U2), on the rule *the row is the
notification*: something appears outside its row only when it can do there what
the row cannot.

- **The queue above the rows is gone.** Every card repeated a row underneath it,
  with its name and its second line — the «notification of the notification» the
  review found. The one thing in it no row could do was answer an ask the panel
  holds, so that moved under its own row: one line with the call, a red ⚠ when it
  is dangerous, Deny and Allow or the question's options, inert for 0.6 seconds
  as before (`InlineAskView`). The model behind the queue stayed (D74): `J` and
  `K` now move a ring down the rows that wait, `A` and `D` answer, `O` opens. On a
  row both amber and held, `A` answers the held ask of that same session.
- **The bar counts instead**: «1 needs you · 2 to read · 1 stopped», by session.
  A click shows only those rows; another shows them all.
- **LampMaster is a star at the end of the bar**, dim with nothing to say, lit
  with its number when it has suggestions; a click opens its view beside the list.
  Its row, thirty-eight points that mostly said «Nothing to report», is gone. The
  narrow panel keeps its line, having no bar.
- **At rest is a grey ring, «resting».** It was the failure's red at 45%, and on
  dark glass it read as a broken session; reading a green answer turned the row
  «red». Red is now only a turn that failed.
- **Twelve hours at rest folds a row** into one line at the foot of the column,
  «Resting · 3 — legacy-import, billing-worker, checkout-api», in the user's order.
  A click lists them under it, one line each. A project with any session not at
  rest never folds; a bound key still finds a folded row. The window is
  remeasured every thirty seconds, since a row folds by time alone.
- **The line said on return says only what the rows no longer show**: earlier
  answers (a session answered and moved on, or closed), earlier failures, the cost.
  What waits is amber on its row and is not repeated. With nothing else to say
  there is no line — never «nothing happened». It goes at the first click on the
  panel.

Measured on the test Mac, in the trial: the panel went from 551 to 371 points for
the same six sessions; a held permission opened under its row, Allow answered it
and the panel shrank back.

## D125 · One place for every switch

**Decided.** The third step of the 1.1 review (U3), on the rule *a place for every
thing*. In 1.0 the switches were in four places — the panel's ⋯, the Settings
window, Getting started and a row's menu —, the ⋯ had twenty-three to twenty-five
entries in no order, one switch had three names («Live in the menu bar», «Put the
panel in the menu bar» and a tooltip's), «Let the panel answer your sessions» meant
writing to them, and an error message turned up as a menu entry.

- **Settings is a window of nine sections**, like Sancho's: Panel, Clicks & keys,
  Alerts, Claude Code & Codex, Acting from the panel, LampMaster, Other Macs,
  Privacy & data, About & help; 880 by 560, the sections down the side. Every
  setting has a name and a line under it saying what it does. The two sections
  that act on the sessions or send something off the Mac carry an orange edge.
  The names and lines live in Core (`SettingsCatalog`); the window draws them.
- **The ⋯ has seven entries**: the conversations, what the lights mean, *Show only
  what's waiting*, *Mute alerts for an hour* (or *Resume alerts*, with the time),
  *I'm away*, *Settings…* with ⌘, — which also works in the panel — and *Quit
  LampBoard*; an eighth, *Show 3 hidden projects*, while some are.
- **A row's menu has eight**: Open, Read the conversation, Open in Session view,
  New conversation here, Rename…, Hide, *Quiet ▸* (Don't alert me, Don't blink,
  Focus) and *More ▸* (the rest: without marking as read, mark as unread, move,
  Finder, decisions, the attach command, a lighter model).
- **The lamp's menu** says what waits and what works, then the panel, the
  conversations, the two ways of keeping quiet, where the panel lives — *Put the
  panel in its own window* is the way back if the drop-down ever cannot be opened
  —, Settings and Quit. Hiding the lamp moved to Settings, and so did Getting
  started and the tour, which left both menus for About & help.
- **One name per switch**: a menu that offers a switch takes the name Settings
  gives it; writing to sessions is *Send messages to sessions*, answering their
  prompts *Answer permission prompts and questions*. The search index, which had
  no switch anywhere but a preference, is in Privacy & data; the safety catch while
  away (D116) has a switch of its own, on by default. The menus are built in Core
  (`Menus`), where a test counts them.

## D126 · The first minute, on your own sessions

**Decided.** The fourth step of the 1.1 review (U4), on the rule *learn when it
matters*. In 1.0 Getting started opened by itself only when the hooks were
installed from the first launch's alert; the README said to install them from the
terminal, so for most people it never opened, and neither did the tour. The tour
then played in a second copy of the app, in the same corner as the real panel and
nearly identical to it; each *Take the tour…* stacked another, and after *Skip*
the only way out was the last of twenty-five menu entries, named like the real
app's Quit.

- **A welcome window opens at the first launch, always**, connected or not: seven
  screens, one idea and one button each — connect Claude Code (and Codex where it
  is installed), the first lamp, three colours, the click and its Accessibility
  permission, answering from the panel and the helper it takes, ⌘K, alerts. The
  button does what is missing and says *Next* once it is done, read from the Mac
  every second (`Welcome`). It replaces the alerts «One last step» and «Done» and
  Getting started; Settings › About & help opens it again.
- **Practice with samples**: three invented rows at the top of the real panel,
  under a band that says *Samples* with *Remove*. api works, then answers, then
  asks; a click reads a sample. They are added to what the column draws and to
  what sizes the window, never to the store, so no notification, count, search
  or LampMaster round sees them (`Samples`, `SampleStage`).
- **The empty panel says what to do**: «No lamps yet» with *Connect Claude Code*,
  or, connected, «Start or restart a Claude Code session» with the samples.
- **The second app and the twelve-step tour are gone.** The demo stage stays for
  the screenshots and the end-to-end suite, behind `--trial` on a fake home only,
  with a band that says *DEMO* so a picture taken there never passes for real.
  `lampboard tour` became `lampboard demo-script`, which only prints the script.
- **The README installs with one line less**: the app connects itself from its
  welcome; `install-hooks` stays for scripts that set up many Macs.

Measured on the test Mac, with the screen locked, so through launch options rather
than clicks: the welcome on a new home opens on «See every agent at a glance» with
*Connect Claude Code*; the empty panel says «No lamps yet»; `--samples` puts the
three rows in, and twenty seconds later api is amber with «Bash: npm publish».

## D127 · Learning when it matters

**Decided.** The fifth step of the 1.1 review (U5). In 1.0 the strong features were
behind switches and commands people never met, and what there was to learn was
taught up front, in a twelve-step tour on invented sessions.

- **A tip the first time something is on the panel**, at the top, two lines and
  *Got it*: a session asking («click it, or answer from here with the helper»),
  a turn stopping, four fifths of the five-hour window used, six rows or more, a
  row folding under *Resting*. The most urgent first, each once, one a day at most
  (`Tips`); never in the demo. Offered only while the panel is on screen and
  nobody is typing in the bar, and taken away by itself once its thing is over —
  a «session waits» line after the answer would be the stale copy U2 removed. The
  band is remeasured, not rebuilt, so a tip never takes the bar's focus. Being
  away has no tip: it can only begin with the screen locked, where nobody reads.
- **«What LampBoard can do»**, from the panel's ⋯ (which has eight entries now),
  Settings › About & help and the bar: every capability by what a person wants —
  answer sooner, stay out of trouble, spend less, work across sessions, step
  away, look back and far —, each in a sentence, marked when it needs the helper.
  *Try* does the gesture in the real panel (the bar opened on `@`, `?`, `week`,
  `/handoff`; the legend); *Turn on…* opens its switch in Settings, installing the
  helper first when it is the helper's; a gesture that is not a switch says where
  it is (`Capabilities`).

Measured on the test Mac: a turn failing on a new home put «A red lamp: that turn
stopped before its answer» at the top of the panel within two seconds, the bar
saying «1 stopped», and the window grew by the band's two lines.

## D128 · Words a newcomer understands

**Decided.** The sixth step of the 1.1 review (U6): the glossary the review
proposed, applied to the interface and the README.

- **The six states** are named for what they mean to the person: *needs you*,
  *done*, *stopped*, *working*, *paused*, *resting* (`awaiting`, `ready`, `failed`,
  `working`, `waiting`, `idle` stay the names in the code, the HTTP API and the
  tests' payloads). The legend capitalises them; a row's second line, the card and
  the menu bar's tooltip use them.
- **The Plancia is the Session view** wherever a person reads it: menus, tooltips,
  VoiceOver, messages. The word stays in the code (`PlanciaView`) and the code map.
- **The companion mod is the helper** in the interface and the README; the command
  stays `lampboard mod`, and the files stay under `mod/`.
- **Hooks become the connection** in the interface: *Connect…*, *Disconnected*,
  «connected» for another Mac. The CLI and the technical documents keep *hooks*.
- **Allowance becomes usage left**, **side question quick question**, **pinned
  decisions project rules** (*Add a project rule for “repo”…*, *Project rules*).
- **LampMaster keeps its name**, with «the reviewer» beside it where it is
  introduced: its star's tooltip, Settings and the catalogue.


## D129 · A terminal of our own, vendored

**Decided.** The live view of 1.2 (D130) puts a session's real Claude Code
interface inside LampBoard, and that needs a terminal emulator. It is
**SwiftTerm 1.20.0**, MIT, copied into `Vendor/SwiftTerm` and built as a target
of this package. It is the first code in the repository that was not written for
it, and the README, `NOTICE` and the code map now say so.

**Why a real terminal rather than a chat of our own.** Measured on the always-on
Linux box, 8 October 2026, with throwaway sessions:
- `claude attach <id>` gives the whole interface of a background session (dialogs,
  slash commands, plan mode, mods), and only through a terminal: it draws a
  full-screen interface, it does not stream text.
- Background sessions refuse a second writer by themselves: a headless
  `--resume` is refused, and a plain `claude --resume` turns into an `attach`.
  The same headless resume of a session open in tmux was accepted silently and
  forked its conversation in two.
- A chat rebuilt from `stream-json` loses dialogs and commands, and cannot reach
  a session that is already running. The chat of 1.0 felt incomplete for exactly
  that reason: it reads the transcript and waits for the turn to end.

**Why SwiftTerm.** It is the one mature terminal view written in Swift, for the
Mac and the iPhone alike, and already used under Claude Code by other apps. It
speaks what Claude Code's interface uses: truecolor, mouse reporting, bracketed
paste, synchronized output, the kitty keyboard protocol, OSC 8 links.
- **libghostty** is faster, but its embedding API says in its own header that it
  is internal and not for other programs, it builds with Zig, and the Swift wrapper
  most apps use has a documented three-thread deadlock.
- **xterm.js in a web view** brings a second runtime, and it has open bugs in the
  kitty keyboard protocol and in synchronized output, which Claude Code relies on
  for every frame.
- **Writing one** is 36,000 lines of somebody else's careful work, redone.

**Why vendored rather than fetched.** The build stays offline and identical on
every Mac. Upstream's manifest compiles a Metal shader that the test Mac's Xcode
cannot build. The Core Text renderer, SwiftTerm's default, is what the live view
uses, so the shader is left out instead. And what ships is what a reviewer reads.
`VENDORED.md` records the upstream commit, the folders left out (the iOS views,
the documentation, the shader) and every local patch. Each patch is marked
`Vendored patch <n>` in the source. There is one: a debug helper that wrote into
upstream's author's home folder now writes to the temporary directory, because
the gate refuses real home directories in any tracked file. That gate read the
vendored sources and found it before anything was committed.

**Warnings.** Our targets still build with every warning as an error under
`Scripts/test.sh` and CI. The flag moved from the command line
(`-Xswiftc -warnings-as-errors`, which reaches every target) into the manifest,
for our five targets alone, switched on by `LAMPBOARD_STRICT=1`. SwiftTerm builds
with its warnings suppressed: they are upstream's, and the first gate run turned
two of them into errors.

**What the gates learned.** The map of the code covers `Vendor/`: every folder
there must have a row, and `bite.sh` renames that row to prove the check sees it.
The figures of the code map still count `Sources/` alone.

## D130 · The live view

**Decided.** A background session opens in a window of LampBoard's own: its real
Claude Code interface, run as `claude attach <id>` in the vendored terminal
(D129), inside a frame that does not look like a terminal. It is the first step of
1.2, and it changes D104's rule that the panel opens no terminal: the row still
copies the command, and now also opens it.

- **Open here**, in a background session's row, opens it; a second Open here
  brings the window forward instead of attaching twice. **New conversation in
  LampBoard**, under More ▸, starts `claude --bg` in the row's folder and opens it
  once Claude Code prints its id. **Open background sessions here**, in Settings ›
  Clicks & keys, makes the live view what a click on such a row does. It is off by
  default: the jump stays what a click does.
- **Closing detaches.** The session goes on under Claude Code's supervisor, and
  quitting LampBoard detaches every window, waiting until each attach is gone,
  since a timer set at quit never fires. The attach ends with SIGHUP to its
  process group, then SIGTERM and SIGKILL, because SwiftTerm's own `terminate()`
  closes the pty and can leave the child running. Every signal is preceded by
  the same question: is this pid still the process started at that time? An
  attach that had already ended was reaped, and its pid may be a stranger's.
- **A ledger per LampBoard.** Each instance keeps the pid and start time of its
  attaches in a file named after itself (`live/live-<pid>-<start>.json`). The
  launch after a crash ends what a LampBoard that is gone left running, and
  leaves alone the ledger of one that still runs: a relaunch during an update,
  or a build beside the installed app, does not hang up the other's windows.
- **The frame takes the theme, the terminal keeps its colours.** Four presets
  (Night, Lagoon, Ember, Paper) colour the backdrop, the card and the default text,
  and the card is the terminal's background so the bands Claude Code paints for
  itself sit on the colour they were chosen against. The sixteen ANSI colours stay
  the terminal's: Claude Code draws its syntax and diffs with them.
- **What reaches the session is a list.** `TERM=xterm-256color`,
  `COLORTERM=truecolor`, the person's language, a `PATH` that starts with the
  folder `claude` is in (a `claude` that is a script finds its `node`), and what a
  session needs to reach Anthropic from where the person is: `CLAUDE_CONFIG_DIR`,
  proxies, a company's certificates, a cloud provider. Not an API key: one in
  LampBoard's environment was put there for something else. LampBoard's `TMUX`,
  `TERM_PROGRAM` and `CLAUDECODE` would make Claude Code believe it runs inside
  tmux or an editor.
- **A citation is a paste.** Text sent into a session goes in bracketed-paste
  marks once the program has asked for them, so `@path` never arrives as an
  Enter. The marks themselves and every control character but a tab or a line
  break are taken out of the text first, so nothing inside can end the paste
  early; without the marks, a line break becomes a space.
- **Only on this Mac.** A background session on another machine is not offered
  here: an attach reaches this Mac's supervisor only.
  Option types characters, as it does everywhere on a Mac: on an Italian keyboard
  @ and # are Option keys.

**Why only background sessions.** Measured on the always-on Linux box, 8 October
2026: a background session refuses a second writer by itself, and a plain
`claude --resume` of one turns into an attach. A session open in an editor or a
terminal has no such guard: a headless resume of it was accepted silently and
forked its conversation in two, the copy in tmux never learning what the other
had said. Two attaches of the same background session share one screen, and
garble it when their sizes differ, hence one window per session.

**How it is checked.** The end-to-end suite opens a session against a fake
`claude` that prints the terminal it finds itself in and records every byte it is
sent, in raw mode:
- the command is `attach <id>`, `TERM` and `COLORTERM` are set, and LampBoard's own
  `TMUX` and `TERM_PROGRAM` do not get through;
- a citation arrives inside bracketed-paste marks, with no Enter;
- an id that is not a job's runs nothing;
- a start runs `--bg` in the row's folder and then attaches to the printed id;
- an attach left by a crash, which ignores SIGHUP, is ended by the next launch.

The crash case also plants the ledger of a LampBoard that is gone, naming the pid
of a live stranger with another start time, and the stranger survives. Each case
was shown to bite: with the ledger's reaping, the bracketed paste, and both
start-time checks taken out, their cases turned red. `GET /live`, behind the
token, says which windows are open; against a fake home it also gives what they
show, because the suite cannot look at a screen, and nowhere else, because the
token is also held by other machines' hooks;
`--live <id>` opens one at launch, and against a fake home `--live-paste`,
`--live-start` and `--live-snapshot` drive it.

**What the review changed.** It found one high and eight medium issues, all
fixed here:
- the stale pid was signalled after an ended attach;
- the ledger was shared between instances;
- quit forgot attaches before they were gone;
- the reattach lost the terminal's margins;
- remote rows offered Open here;
- `/live` gave the screen's text in every build;
- the environment was too narrow for a proxy or another config folder;
- the fake `claude` of the suite outlived its terminal.

That last one had left ten orphan loops on the test Mac, killed before the next run.

**Measured on the test Mac.** A real Claude Code session, recorded on the Linux box
and replayed into the live view, drew its prompts, a worktree, a coloured diff and
its answer inside the Night frame. Taking that picture taught one thing: drawn
into the window's bitmap in one pass, the terminal's text came out missing while
its cell backgrounds stayed. The snapshot now draws the frame and the terminal
separately and composes them.

## D131 · Every lamp beside the conversation

**Decided.** The helper (1.14.0) adds `/lamps`: a pane beside the conversation
with every session the panel shows, the ones that want something first, each in
the panel's colour and the 1.1 glossary's word for its state. A digit or a click
on a session brings it forward, through the same `/mod/band/open` the band's
digits use. The pane is opened only by the command, never by itself: one that
opens unasked takes the width of somebody's work. It asks the panel's
`GET /sessions` every three seconds while open, and nothing once it is closed.

**Why a pane, and why now.** The band (D84) says what waits elsewhere in one line;
it cannot say what the other sessions are doing. Inside the live view (D130) the
pane makes the whole board visible without leaving the session, and outside it,
in any terminal where Claude Code runs full-screen, it does the same. Mods draw a
pane only in that layout, which a background session's attach always uses.

**What was learned writing it.** Claude Code's check of a mod follows `$` only into
functions declared in the same file: a module that hands `$` to an imported
function, or registers a second `session.start` without a matcher, is refused
whole. So `lamps.js` finds the panel with its own copy of `register.js`'s lookup
(HOME only, the token, the port, `/health` answering as LampBoard), and `/lamps`
is registered in `register.js`'s one `session.start`. `claude plugin validate`
names both refusals in a sentence, which is how they were found.

**A defect it found.** The helper registered its commands in one `try`. On a
machine with claude-mem, whose `handoff` skill holds that name, the helper's
`/handoff` was refused, and every command after it went with it, `/lamps`
included, while `/lampmaster` before it survived. Each command is now registered
on its own. Measured on the always-on Linux box, where claude-mem is installed.

**What a review changed.** The first version kept one state and one clock for
every session of the hooks worker, started its clock before the pane was open
and waited on the panel without a limit. Now each session has its own pane state,
ended with the session; the clock starts only once the pane is open, a refresh
never overlaps another, and no call to the panel waits more than two seconds.
Rows the panel no longer confirms are cleared, so a closed panel says so instead of
leaving buttons that do nothing. What a session calls itself is cleaned of control,
bidi and invisible characters before it reaches the terminal, and a session id
must look like one. The pane is registered last and on its own, so a Claude Code
without panes keeps the rest of the helper.

**Measured.** In a session against a fake panel of five invented sessions, `/lamps`
drew them in order (needs you, stopped, done, working, resting) with their digits,
and a digit posted `/mod/band/open` for that session. With the fake panel stopped,
the pane said within one refresh that LampBoard was closed; started again, it
filled itself. The 1.14.0 helper
passes `claude plugin validate`, which the gate runs (`Scripts/check-mod.sh`). The app carries the new file compiled in
(`ModFilesLamps.swift`), and `ModFilesSuite` holds it to the bytes of
`mod/hooks/lamps.js`.

## D132 · Sessions in tmux, here and on other machines

**Decided.** The live view also opens a session that runs inside tmux, on this
Mac or on any machine added under Settings › Other Macs. Its row offers **Open
here**, and the window runs `tmux attach-session -t =<session>:<window>.<pane>`:
with this Mac's own tmux, or over ssh for another machine
(`ssh -t <host> tmux attach-session …`, with the same hardening every ssh of
LampBoard carries, now in `SSHHardening`). Nothing names a machine: a host is
whatever the person added, and a tmux session is found wherever Claude runs in one.

**Why it is safe.** tmux keeps one process however many clients attach, so the
live view is one more screen on the same session, never a second writer. The
person's own terminal, an iPhone through Remote Control and the live view can all
look at it at once. A session in an editor still has no such guard and still
jumps.

**How a session is placed.** On another machine the probe that already reads its
sessions also asks `tmux list-panes -a` once and walks each session's process up
its parents to a pane's shell, through `/proc` on Linux or `ps` on a Mac. On this
Mac a small service does the same every ten seconds (`LocalTmuxPlaces`), so that a
row's menu never runs a command while it is drawn. Both read tmux's default
server, and both answer nothing when tmux is missing or not running. A tmux
session name is offered only when tmux can take it back as one name (letters,
digits, dashes, underscores); the target is tmux's exact-name form, so `awe`
never attaches to `awevents`.

**What changed around it.**
- The setting is now **Open here when LampBoard can**: a click on any session the
  live view can open, in the background or in tmux, opens it there.
- The row's More ▸ copies whichever command opens it in a terminal of one's own:
  `claude attach <id>`, `tmux attach -t …` or `ssh -t … tmux attach -t …`.
- A window's header names the machine when the session is on another one.

**Measured.**
- On the always-on Linux box the probe placed every session that runs in tmux in
  its own tmux session, and placed nothing for a helper process outside tmux.
- The end-to-end suite puts a fake `tmux` in the fake home, with one pane whose
  shell is a session's own process. The session was placed and opened with
  `tmux attach-session -t =work:0.0`, with `TMUX` absent from its environment.
- The first run of that case failed: the window controller never handed the path
  of `tmux` to the launch, so a placed session opened nothing. That was caught by
  the case.

**What a review changed.** It found two high issues and seven medium ones, all fixed:
- **zsh.** zsh, a Mac's default shell, expands a word that begins with `=` into a
  command's path, so `=work:0.0` never reached tmux on another Mac, and the copied
  command failed when pasted. The target now crosses every shell in single quotes,
  as one remote command string. Over ssh from the Linux box to itself, that string
  attached to a throwaway tmux session.
- **An editor started from a pane.** Such an editor hosts its sessions under that
  pane, and they were being placed in it, losing their jump. Only a terminal's
  session is placed now: entrypoint `cli`, or none.
- **Keys and lookups.** A window is keyed by session, window and pane, so two panes
  of one tmux session are two windows. A machine named `local` cannot collide with
  this Mac. A remote place is looked up on its own machine only.
- **The probe on a Mac.** Where there is no `/proc`, the probe takes one snapshot of
  the process table instead of running `ps` for every step of every walk. It finds
  Homebrew's tmux, which a non-interactive ssh does not have on its PATH, and the
  attach adds Homebrew's folders to PATH for the same reason.
- **Time and noise.** The attach gives up connecting after ten seconds. When tmux
  does not answer, this Mac keeps the places it had, so Open here does not blink
  out of a menu.

**Not yet.** zellij sessions, a background session on another machine
(`ssh -t <host> claude attach <id>`), and tmux servers on sockets other than the
default.

## D133 · A new session from LampBoard

**Decided.** **New session…** in the panel's ⋯ (⌘N) opens a small window with three
fields: where (this Mac, or any machine under Settings › Other Macs), a folder,
and a name. The folders offered are the ones that machine's sessions worked in,
the most recent first, and any absolute path can be typed; on this Mac **Choose…**
opens a folder picker. Start opens the session in the live view.
- **On this Mac** it is `claude --bg` in that folder, as New conversation in
  LampBoard already did (D130).
- **On another machine** it is a tmux session there. `ssh -t <host>` runs a
  short script under `sh`, so that a login shell of fish or csh reads it too. The
  script checks the folder, then runs `tmux new-session` there with the person's
  own shell, interactive so that its startup files put `claude` on PATH. Claude
  Code runs in that shell, and the shell stays when it ends. The session outlives
  the window and the ssh. The person's own terminal can attach to it, and Remote
  Control reaches it when that machine has it on. At the probe's next pass its row
  appears, placed in that pane, and Open here attaches to it (D132).

**New conversation in LampBoard**, a row's More ▸, is now offered on the rows of
other machines too, and does the same in the row's folder.

**Why tmux over there, and not a background session.** Opening a background
session of another machine would need `ssh -t <host> claude attach <id>`, its
supervisor and its id, and is not built yet. tmux needs nothing on that machine
but tmux and Claude Code. The session it gives is one any terminal can reach, so
it is not tied to LampBoard.

**Names.** A tmux name is made from the folder's: letters, digits, dashes and
underscores, at most forty, the only names D132 offers back as a target. The
names LampBoard has seen are avoided, and the remote command picks the first free
one itself (`web`, `web-2`, `web-3`), because LampBoard has not seen every tmux
session of that machine. Everything that crosses ssh is in single quotes, and the
folder may hold spaces or a quote. Homebrew's folders are added to PATH, as for
the attach.

**The tag.** Each session LampBoard starts gets a tmux option there,
`@lampboard`, set to a random tag. Both the probe and this Mac read it back with
the pane. The script looks for that tag before it creates anything, so a
reattach after a dropped ssh returns to the session it started instead of
starting a second one. A window is keyed by the tag, so the row's Open here
brings forward the window that started the session, whatever name or window
numbers it got over there (`base-index 1` included).

**Measured.** Over ssh from the always-on Linux box to itself, with Claude Code
replaced by a shell that prints where it is:
- The script created a tmux session in a folder whose name has a space and a
  quote, and the session started in that folder.
- The interactive shell found `claude` in `~/.local/bin`.
- Run again with the same tag, it attached to the same session without making
  a second one.
- With a folder that does not exist, it said so and stopped.

**What a review changed.** It found two high issues, five medium and four low.
- **High: reattach.** Reattach re-ran the creating command and started a second
  session; it is fixed by the tag.
- **High: shells.** The script assumed a POSIX login shell; it now runs under
  `sh`.
- **Medium:**
  - a login shell does not read `.zshrc` or `.bashrc`, where many people put
    `claude` on PATH;
  - a window's key could name another session;
  - tmux before 3.0 takes one command string;
  - a missing folder silently became the home folder;
  - a local folder that does not exist could be started.
- **Low:**
  - a typed name was overwritten while editing the folder;
  - the window recomputed its folders on every keystroke and lost what was typed
    when asked again;
  - its header could show another session of the same folder while the new one
    was starting.

All of these are fixed. The tag test and the reattach test each fail when the
tag lookup is removed from the code.

## D134 · Claude Code's look

**Decided.** The helper (1.15.0) can draw a conversation the way Claude Code's
VS Code panel does. It changes these parts:
- The person's prompts sit in rounded boxes.
- Each tool call is one row: a status dot, the tool in bold, its file or command,
  and `+a −r` for an edit. Its result is one dim line under it.
- An edit's result is a diff in a rounded frame.
- A todo or task list is a checklist.
- The spinner says in one word what the turn is doing.
- The hint under the prompt ends with the model and how full the context is.

Everything else is Claude Code's own drawing. That includes the permission
dialog, thinking, the header, and the prompt box, which no render hook reaches.

**Where.** Settings › Clicks & keys › **Claude Code's look** has three choices:
- **In LampBoard's windows**, the default: only the sessions open in the live
  view.
- **Everywhere**: every session the helper runs in.
- **Off.**

Before it draws, the helper asks the panel `GET /mod/look` with the panel's token
and its session's id. It draws only on `{"v":1,"on":true}`, keeps the answer five
seconds, and redraws when the answer changes. No panel, a late answer, any other
answer, or a surface other than the terminal leaves Claude Code's drawing
untouched. VS Code's own panel and the phone draw no mod at all.

**Why the live view by default.** A window of LampBoard's is one the person did
not choose a terminal's look for. A session someone keeps in a terminal of their
own keeps that terminal's look unless they ask. The helper's other parts never
depend on it: the look is registered last and on its own, as `/lamps` is.

**Measured.** The look was drawn in a real session, Claude Code full screen as an
attach is, on and off, at 170 columns and at 72 (the frames fit, the hint ends in
`…`). Switched on mid-session, it redrew the transcript already on screen within
five seconds. `/lamps` and the band kept working. Over 1,474 renders, the slowest
render hook took 286 ms, with no refused tree in Claude Code's debug log.
`claude plugin validate` passes.

**What a review changed.** It found no high issues, three medium and four low,
all fixed:
- **Medium: the first answer.** Rows drawn while the first answer was on its way
  stayed in Claude Code's drawing. Every row now waits for that answer, which is
  bounded, and the first "on" redraws.
- **Medium: errors.** No hook guarded its own drawing. Every one now gives the
  row back to Claude Code if anything in it throws.
- **Medium: a busy panel.** A panel too busy to answer within a second said
  "off", and the look flickered. It now answers 503, and the helper keeps its
  last answer for up to three asks.
- **Low.** A diff's `\ No newline` line was counted on both sides of a hunk, and
  four more invisible characters are taken out of what is drawn.

**Not yet.**
- A prompt typed through `claude attach` may carry an origin the look does not
  box; that is not verified.
- On the main screen, rows already in the terminal's scrollback keep the drawing
  they had when the answer changes.
- Bash output is not shown while the command runs; it appears when the call ends.

## D135 · Move to LampBoard

**Decided.** The menu of a row whose conversation is open in VS Code (or Cursor,
or Windsurf, which run the same extension) offers **Move to LampBoard…**. After a
confirmation, the conversation goes on in a LampBoard window as a background
session of this Mac, with everything it remembers. It keeps running when the
window is closed, so VS Code can stay shut. Until someone asks for the move, the
row's click still jumps to the editor, as before: nothing changes for anyone who
does not ask.

**How.**
1. The editor's process is asked to end. This is the `SIGTERM` of End session,
   with the same check that the pid is still the process the session file names.
2. LampBoard waits up to ten seconds for the process to be gone.
3. LampBoard runs `claude --bg --resume <id> --name <the row's name>` in the
   folder of that process.
4. The window opens as soon as Claude Code gives the job's id.

The same session id goes on. On the always-on Linux box a word told to an
interactive session before the move was remembered after it.

**What is checked before anything ends.** A failed check leaves the conversation
where it is.
- **This Mac's session, in the editor extension, not in the background.**
- **Between turns.** A turn under way, or a question waiting for an answer, would
  be cut where it stands; the move says to come back when it has finished.
- **The process is found and is the same one.**
- **The folder is trusted.** `--bg` does not ask, and refuses a folder Claude
  Code was never told to trust. LampBoard reads Claude Code's settings file
  (`$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json`) for the folder or a
  folder above it. Measured: a trusted parent covers a child marked untrusted.

**When the start fails after the end.** What is said depends on what Claude Code
answered, so nobody is told to resume a conversation that may already have a
process:
- **A refusal.** Nothing runs. The line that takes the conversation up in a
  terminal is given and copied: `cd <folder> && claude --resume <id>`.
- **No answer in time, or no job named.** Look for it in the panel or with
  `claude agents` first.
- **A job that started but whose window did not open.** Its `claude attach`
  line is given.

**The tab left in VS Code.** Read from the extension: an ended process is shown
as an error, and nothing restarts it. A message typed there afterwards starts a
headless `--resume` of a session that is now in the background. The supervisor
refuses that second writer (D130), so it cannot fork the conversation. The
confirmation says to close the tab.

**What a review changed.** It found two high issues, four medium and two low:
- **High: a second move.** A second Move of the same conversation, while the
  first was waiting for its process to end, would have started a second
  background session. A conversation being moved is now refused, and its menu
  entry is gone until the move ends.
- **High: the failure advice.** A failure after the end advised resuming by hand
  even when the start had only timed out. It now says one of the three things
  above.
- **Medium: checks after the dialog.** The confirmation can stay open for
  minutes, so every check is made again after it: status, process, folder,
  trust.
- **Medium: a reused pid.** The wait reads a reused pid as the process gone,
  instead of waiting it out.
- **Medium: the folder.** A folder that no longer exists is refused before
  anything ends.
- **Low: trust and links.** The trust check also reads the folder through its
  links: `/tmp` is `/private/tmp` on a Mac.

The extension starting a new process for its tab was not measured with VS Code
itself. What makes it safe was measured: a headless resume of a background
session is refused (D130).

**Not yet.** A conversation in VS Code on another machine, through Remote-SSH,
would need a background session there and `ssh -t <host> claude attach`.

## D136 · The files beside the session

**Decided.** A live window of a session on this Mac has a **Files** button. It
opens the session's folder beside the terminal, on a card of its own:
- **A tree.** Folders first, in Finder's order, read when opened. The folders
  nobody reads and that slow a tree down are left out: `.git`, `node_modules`,
  `.build`, `DerivedData` and the like. Dotfiles stay, because `.github` and
  `.claude` are read and cited.
- **The file the agent is on.** A line at the top names the file a Read, Edit or
  Write is working on, from what the helper already reports. A click opens the
  tree down to it and shows it.
- **A preview.** Text up to a megabyte, read-only: the session is the one that
  edits. When the file changes on disk, the preview reads it again and keeps its
  place, so what it shows is what the agent just wrote.
- **⌘L, or Cite.** The file, or the lines selected in the preview, reaches the
  session's prompt as `@path#La-b`. The path is relative to the session's folder,
  with a space escaped by a backslash: measured, quotes do not work, `\ ` does.
  It arrives as a paste, never with an Enter, so nothing is sent until the person
  sends it.

**Why read-only.** An editor beside an agent that edits the same file is two
writers of one file. The preview shows the agent's work and lets it be pointed
at; changing it is asked of the session.

**Measured.** The end-to-end suite opens a session's window with a `README.md`
in its folder, opens the files with that file in the preview, and reads both
the folder and the file back from `GET /live`. In the window's picture, the tree,
the preview and Cite ⌘L sit on their card beside the terminal.

**What a review changed.** It found five high issues and four medium ones, all
fixed:
- **Reading on the main thread.** A file that is not text, or is over a
  megabyte, was read again every second. A large one was read whole before the
  limit applied. Now only a regular file is opened, at most a megabyte plus a
  byte is read, and a file that changes nothing is not read again.
- **Listing while closed.** The panel listed the folder even while closed.
  Nothing is listed, read or checked until it opens. A folder shows its first
  two thousand entries.
- **A brief gap in the row.** The session's row being read again for a moment
  took the tree away. The window now keeps the folder it had: a window's
  session does not change folders.
- **The selection after a re-read.** The selection was kept by its offsets
  after a re-read, so ⌘L could cite lines nobody chose. A re-read now clears it.
- **Medium.** A folder closed is read again when it opens, with the outline told
  so. The lines of a selection are counted in one pass with no copy. A citation
  escapes only what was measured, the space.

Opening the files of a session working in the home folder lists the home
folder, and macOS may ask LampBoard for access to Documents or Desktop; it
happens only when someone opens the panel.

**Not yet.**
- The files of a session on another machine.
- Editing in the preview.
- Line numbers beside the preview.
- A file name with `#` is cited as it is; whether Claude Code's prompt reads it
  whole is not measured.

## D137 · The sessions resting on other machines

**Decided.** A session on another machine becomes a row as soon as that
machine's probe reports it, not only when it first speaks through the tunnel.
This Mac's sessions have always been found from their files; the other
machines' now follow the same rule, from what their probe sends. The row starts
idle, named as Claude Code names the session there, and the first hook replaces
what it says.

**Why.** Found on 1.3.0, the day it shipped, by its first user. The update
restarted LampBoard, and the three sessions resting in tmux on the always-on
Linux box were missing from the column until each did something. Only the one
at work showed. Open here, the point of 1.3 for those sessions, needs the row,
so it could not reach them.

**Which.** The same as for this Mac:
- a terminal's session (entrypoint `cli`, or none), not one in the background;
- with a conversation in it, so not a helper process such as claude-mem's
  observer: its transcript there holds anything at all;
- only while Settings shows sessions started in a terminal.

An editor's session on another machine still arrives through its own hooks and
windows. A row that already exists is left as it is. One the probe no longer
reports is removed by the rule that already removed them.

**When.** With each fresh answer from that machine, never in the five-second
pass. Between answers the list is up to twenty seconds old, and a session that
has just ended would come back from it as a ghost. Only for a machine still in
Settings.

**What a review changed.** It found one defect and one gap, both fixed:
- **A ghost row.** A session that had just ended came back from the cached
  list for up to twenty seconds; now the adoption runs only on a fresh answer.
- **A missing filter.** The rule that keeps service processes out of the column
  locally (`deservesTrafficLight`) is now applied here too.

**Measured.** On the Mac, after the restart, the panel's rows from the Linux box
were one of four: `/sessions` listed only the session at work. The domain suite
holds the rule. Its cases fail when the conversation check, or the service-process
check, is removed.

**What 1.3.3 changed.** In 1.3.1 "a conversation" was read as "a context can be
read from its transcript's tail". The same evening the Linux box rebooted and
resumed its sessions. Their transcripts then ended in the system records of the
resume, with no reply in the tail the probe sends, so no context could be read.
Five of seven sessions were again missing; only one that had worked since then
showed. The probe now says whether the transcript holds anything, and that is the
rule, as it is for this Mac's sessions. The case for a resumed session fails with
the old rule.

## D138 · Keys and a way back to the live window

**Decided.** LampBoard has a main menu: LampBoard (Hide, Quit by click), Edit
(Undo, Redo, Cut, Copy, Paste, Select All) and Window (Minimize, Close, Bring All
to Front, and the open windows). While a live window is open, LampBoard has a Dock
icon and a place in ⌘Tab, and the menu shows as the menu bar. Clicking the Dock
icon brings every live window forward. With the last live window closed, it is a
menu-bar app again.

**Why.** Reported by the first person to use 1.3 with their hands. Copy and
paste did not work in the live view. A window left behind another app could not
be brought back except by choosing Open here again. Both had one cause: an
accessory app with no main menu.
- **The keys.** AppKit sends ⌘C and ⌘V to the main menu, whose items send
  `copy:` and `paste:` to whatever has the keys. With no menu, they reached
  nobody. The same was true of every text field in LampBoard's other windows.
- **The way back.** With no Dock icon, ⌘Tab and the Dock had nothing to offer.

**No ⌘Q.** A ⌘Q meant for another app, pressed while LampBoard has the keys,
must not quit the panel that holds the lamps. Quit stays in the panel's ⋯ and
in the menu, by click.

**Measured.** The end-to-end suite presses ⌘V in a live window, with a known text
on the pasteboard. The menu took the key. The text reached the session as a
bracketed paste. While the window was open LampBoard had its Dock icon, and the
menu held ⌘C, ⌘V, ⌘A and ⌘W and no ⌘Q. On the test Mac the screen is locked and
no window can be key, so the menu's action was handed to the terminal, where a
key window sends it. With the menu not installed, the case fails.

## D139 · No card for an ask the mode decides

**Decided.** The panel shows Allow and Deny only for an ask a person would have
been asked. Claude Code's `ask` means "put it to the mode's decider": the dialog
in `default`, `acceptEdits` and `plan`, but the classifier in `auto`, and nobody
in `dontAsk` or `bypassPermissions`. A session's hooks report its mode
(`permission_mode`), and the panel keeps the last one each session reported. An
ask from a session in one of the last three modes is answered `ask` at once, so
its own decider decides, and no card appears. A session whose mode has not been
heard yet is treated as before. A subagent's signals count too: a subagent runs
in its session's mode unless its definition says otherwise, and in 1.3.4 a
session whose turn waited on a subagent sent the panel no signal of its own
after a restart, so its mode was never heard (fixed in 1.3.5).

**Why.** Reported by its user the morning after 1.3: a session in Auto showed a
card with Deny and Allow for a Bash call, though the session itself asked
nothing. Worse than the false card, the call waited for the panel up to its 55
seconds before the classifier was even consulted.

**Measured.** The end-to-end suite has a session report `auto` through a hook,
then asks: the answer is `ask`, signed, within three seconds, and nothing is
listed. The domain case for the rule fails when the mode is ignored.

## D140 · A click finds the live window

**Decided.** A click on a row whose session is open in a live window brings that
window forward, before anything else a click does. In a project row the most
urgent member with a window is the one raised. With no window open, the click
does what it did.

**Why.** Reported by its user the morning after 1.3: a session of another
machine opened with Open here and left behind another app could be found again
only by choosing Open here once more. The Dock icon of D138 was there, but a
click on the session's own row is where anyone looks first.

**Measured.** The end-to-end suite runs without the panel, so the rule is a
function of its own (`LiveClick`), held by the domain suite. Its case fails when
the rule finds no window.

## D141 · A session Claude Code says is busy

**Decided.** Claude Code writes in each session's own file whether it is `busy`
or `idle`. A row the panel knows only as idle turns working when that file says
busy: on this Mac from the file, and on another machine from the probe, which now
sends the field. Nothing else changes: a row that waits for a person, has an
answer, failed or is paused keeps what it says, and no row is made from it.

**Why.** Reported by its user the morning after 1.3, on a session in VS Code
"working intensely" while its lamp was off. Its turn had started a subagent and
was waiting on it. The subagent's signals are not the turn's, and the update to
1.3.4 had restarted LampBoard, which adopted the session from its file as idle,
since nothing told it otherwise. From then on, nothing did. Claude Code's own
file said busy all along.

**Measured.** On the Mac, the session's file said `"status":"busy"` from 07:48
while its transcript stopped at 07:52 and a subagent's transcript moved by the
minute. The domain suite holds the reading of the field and the rule. Its case
fails when the rule lights no idle row.

## D142 · VS Code's colours in the live view

**Decided.** Two more themes for the live view, **VS Code Light** and **VS Code
Dark**. Each has a frame like the editor's chat around the session and VS Code's
own sixteen terminal colours, Light+ and Dark+. Beside them in Settings ›
Clicks & keys › The live view:
- **Font**: any fixed-width family on this Mac, or the system's.
- **Line spacing**: from 1.0 to 1.5 times the font's.

**The exception to D130.** The other themes leave the sixteen ANSI colours to
the terminal, because a palette chosen for a frame can make Claude Code's own
colours unreadable. These two bring a whole palette instead: the one Claude Code
already looks right on in VS Code's terminal. Choosing another theme puts the
terminal's palette back.

**What cannot be done.** The editor's chat sets its text in a proportional font
and lays it out as a page. Claude Code in a terminal draws on a grid of cells
(boxes, columns, a spinner), and a proportional font would pull it apart. So
the window can take the chat's colours, any fixed-width font and some air
between lines, but not its typography. A chat view of its own, reading the
conversation and writing to the session, is a larger project, left for later.

## D143 · The helper beside the hooks

**Decided.** At launch, with the helper on here, a machine under Settings ›
Other Macs that has LampBoard's hooks and no helper gets the helper, as one with
an older helper already did (B1). Its sessions then have the band, `/lamps` and
Claude Code's look, reaching this panel through the tunnel the hooks already
use. A machine without the hooks is left alone, as is a newer helper.

**Why.** Its user saw none of 1.3's look in a live window of a session on the
always-on Linux box. The helper runs where the session runs, and that machine
had been connected before the helper could go there (B1 installs it with the
hooks). Nothing would ever have brought it.

**Measured.** The domain suite holds the rule. Its case for a machine without
the hooks fails when the rule installs there.

## D144 · Like my VS Code

**Decided.** A third VS Code look, **Like my VS Code**, reads the colours of the
VS Code on this Mac each time a live window is drawn. It reads:
- the profile in use: the one whose editor background is the one VS Code last
  drew, from `themeBackground` in its own storage;
- the profile's colour customisations, the ones scoped to the theme in use over
  the general ones;
- the colour theme's own file, from VS Code's bundled extensions or the
  installed ones, following its `include` chain.

What it takes from them:
- **The card:** the chat's background, the side bar's, falling back to the
  editor's.
- **The text:** the side bar's foreground.
- **The terminal:** the sixteen terminal colours when all are said.
- **The font:** the fixed-width sibling of the chat's font when this Mac has one
  (`Atkinson Hyperlegible` → `Atkinson Hyperlegible Mono`), unless Font is set.

Without a VS Code to read, VS Code Light stands in.

**Why.** VS Code Light copies VS Code's default Light+ colours, whose background
is white. Its user's VS Code is customised: the chat sits on `#D6CDB8`, and next
to it the live window was nearly white. A preset cannot match every person's
editor; reading it can.

**Measured.** The domain suite parses settings with comments, trailing commas and
a URL in a string. It holds the order: the profile over the theme, a theme-scoped
customisation over a general one. Its case fails when the theme is read before
the profile. On its user's Mac, the same steps written in Python found the right
profile, `#D6CDB8` and `#22201C`, and all sixteen terminal colours.

## D145 · Fixed-width fonts, measured

**Decided.** The live view's Font list holds every family on this Mac that
draws `i`, `W`, `m` and `.` at one width, as well as those that declare
themselves fixed-width. Nothing else changes: a proportional family is still
left out, since Claude Code draws on a grid.

**Why.** Its user installed four reading fonts to replace the terminal-looking
ones: Atkinson Hyperlegible Mono, IBM Plex Mono, Monaspace Neon and Argon, and
iA Writer Mono. iA Writer Mono did not appear. Measured on that Mac: its four
widths are equal (7.20 points at 12), but its files do not carry the flag macOS
lists fixed-width fonts by.

**Measured.** On that Mac, iA Writer Mono and Menlo measured four equal widths,
Helvetica and the proportional Atkinson Hyperlegible did not. Each of the five
families has a real Bold face, which the terminal uses for bold text. The
domain suite holds the rule, and its case fails when unequal widths pass.

## D146 · Letter spacing

**Decided.** Settings › Clicks & keys › The live view › **Letter spacing** sets
the width of a cell from 85% to 100% of the font's own advance, 100% by default.
Below 85%, the wide letters (m, W) touch their neighbours.

**Why.** Its user, comparing the live window with VS Code's chat beside it,
asked for letters spaced more like an ordinary font. A fixed-width font gives
an `i` the room of an `m`, and that room is what reads as a terminal. Two
answers go together:
- **A tighter cell**, this setting.
- **A font that heals its texture:** Monaspace's contextual alternates let a
  narrow letter lend room to a wide neighbour within the grid. SwiftTerm shapes
  its runs with Core Text, which applies them by default.

**How.** SwiftTerm sizes a cell by the advance of `W`. A local patch, `Vendored
patch 2` in `Vendor/SwiftTerm/VENDORED.md`, multiplies that width by a
`characterSpacing` set beside upstream's `lineSpacing` and applied the same way.
At 1 it changes nothing.

**Measured.** The domain suite holds the range, and its case fails when the
floor is lowered. The setting has not been looked at on a screen yet; its user
looks first.

## D147 · The chat

**Decided.** A live window has two views, **Terminal** and **Chat**, switched in
its header. The terminal is the default, and nothing about it changes. The chat
shows the session's conversation the way an editor's chat panel does: the
person's messages in bubbles, the replies as set text with their markdown, each
tool call as a row with its result, a diff as a diff. There is a box at the
bottom to write in. Settings › Clicks & keys › The live view › **Open on the
chat** makes the chat what a window opens on. Off by default.

**How it works.** The chat draws; the terminal stays the session's one writer.
- **Reading.** The chat reads the session's transcript, which Claude Code writes
  line by line. A session of this Mac's is read from its file, polled where it
  was left. One on another machine is read over ssh, with `tail -F` on its
  transcript there: the last 800 lines, then each new one.
- **Writing.** A message from the box goes into the terminal as a paste followed
  by Enter, the same as typing it.
- **Dialogs.** A permission, a question or a menu is the terminal's. While the
  session waits for one, the chat says so and offers the terminal.
- **Looks.** The chat takes the window's colours. Its messages are set in VS
  Code's chat font when this Mac has it, the system's otherwise.

**From Clarc.** The message views and the line decoder are Clarc's (Apache 2.0),
vendored with their licence and five local patches (`Vendor/Clarc/VENDORED.md`).
Every client found starts a `claude` of its own and draws that. None draws a
session already running elsewhere and writes to it without becoming a second
writer, which is what this needed. Clarc's views had already met real
transcripts. Its message list was not taken: it needs macOS 15, and LampBoard
runs from 14.

**Measured.** The end-to-end suite writes a transcript as Claude Code writes it:
ISO dates with fractions, a reply in markdown. It opens the session's window on
the chat and reads both messages back. It sends a message from the chat and finds
it in the terminal, Enter after it. The case fails when the dates are read
Foundation's default way: every line is then dropped. The window's picture showed
the bubbles, the bold and the box, in VS Code Light's colours.

**What a review changed.** It found four high issues, six medium and eight low.
- **High: Send at a dialog or a shell.** Send went out at any moment. At a
  permission dialog its Enter would have approved the dialog's default; with
  Claude gone, it would have run in the shell left behind in a tmux pane. Send is
  now allowed only while the session's row says Claude is there and waits on no
  dialog, and the terminal is still attached. A message that could not go is
  kept in the box.
- **High: a transcript not written yet.** A new session's chat stopped at "not
  there yet" for good. The file is now looked for again until it appears, and
  read again from the start when it shrinks or is replaced.
- **High: opening a remote chat.** The whole transcript was decoded once per piece
  that arrived, on the main thread. Rebuilds are now gathered into one per burst,
  and the line buffer reads its bytes once.
- **High: a dropped connection.** The chat froze without a word. Now it says so,
  connects again less and less often, and connects again when the terminal is
  reattached.
- **Medium.**
  - Quitting stops every chat's ssh, and the remote `tail` ends when the
    connection's input closes.
  - The keys follow the view shown: the chat's box, or the terminal.
  - A link in a reply opens only for `http` and `https`.
  - Autoscroll follows the last message, not the count.
  - The licences travel inside the app, and the notice names Clarc's owner as
    its licence does.
  - Clarc's diff view and its `git` helper were left out: nothing reached them,
    and a path from a transcript is never handed to `git`.
- **Low.** Enter is sent a moment after the paste's closing mark, not in the
  same write. The chat is published only when what the window knows changes.

A second end-to-end case has the session wait on a permission, then sends from
the chat. The chat says the session asks, Send is off, and nothing reaches the
terminal. With the gate removed, the message reached the dialog with its Enter,
and the case failed.

**Not yet.**
- A reply appears line by line as the transcript grows, not letter by letter as
  in the terminal.
- A file named in a tool row is not opened from the chat.
- After `/clear`, the chat stays on the conversation it opened with.
- A message cannot be forked or edited, as Clarc can.
- A theme changed in Settings reaches a chat already open only when its window
  is opened again.

## D148 · Custom colours

**Decided.** Look › **Custom** shows two colour pickers in Settings, Background
and Text. The card is the background picked, and the window behind it is a
shade darker. The theme is dark or light by the background's brightness. The
chat follows both colours; the terminal keeps its own sixteen.

**Why.** Its user asked for a colour picker beside the presets: a preset never
matches every editor, and «Like my VS Code» only matches VS Code.

**Measured.** The domain suite holds what is made of the two colours.
