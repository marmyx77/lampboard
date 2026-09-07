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
`aworld-os-platform` was reading `aworl…latform`. An action taken a few times a
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
