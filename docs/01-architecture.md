# Architecture

## The problem, stated properly

With a dozen VS Code windows open, each holding one or more Claude Code sessions,
finding out **which one is waiting for you** means going through all of them. The
cost is not the time spent looking: it's that you stop looking, and the answers
just sit there.

lampboard answers one question — *which window needs me?* — and supports one
gesture: clicking on it and ending up there.

Everything else in the project follows from that. When a feature doesn't help
answer that question or make that gesture reliable, it doesn't get in.

## The complete flow of an event

```
 ┌─ Claude Code ────────────────────────────────────────────────┐
 │  a turn changes state: starts, finishes, blocks, fails       │
 └──────────────────────────┬───────────────────────────────────┘
                            │ runs the registered hook
                            ▼
 ┌─ ~/.lampboard/hook.sh ─────────────────────────────────────┐
 │  reads the JSON on stdin, adds CLAUDE_CODE_ENTRYPOINT        │
 │  as a header, POSTs to localhost, **always exits 0**         │
 └──────────────────────────┬───────────────────────────────────┘
                            │ HTTP
                            ▼
 ┌─ SignalServer ───────────────────────────────────────────────┐
 │  NWListener bound to 127.0.0.1, minimal HTTP parser          │
 └──────────────────────────┬───────────────────────────────────┘
                            ▼
 ┌─ HookPayloadDecoder ─────────────────────────────────────────┐
 │  validates strictly → HookSignal, or refuses                 │
 └──────────────────────────┬───────────────────────────────────┘
                            ▼
 ┌─ WorkspaceResolver ──────────────────────────────────────────┐
 │  cwd + ~/.claude/ide/*.lock → which window hosts it          │
 └──────────────────────────┬───────────────────────────────────┘
                            ▼
 ┌─ StateReducer ───────────────────────────────────────────────┐
 │  (state, action) → new state. A pure function.               │
 └──────────────────────────┬───────────────────────────────────┘
                            ▼
 ┌─ StateStore (@MainActor) ────────────────────────────────────┐
 │  @Published state  ──┬──→  SwiftUI redraws the column        │
 │                      └──→  SnapshotBox → GET /sessions       │
 └──────────────────────────────────────────────────────────────┘
```

And in parallel, independently, every five seconds:

```
 ┌─ ~/.claude/sessions/<pid>.json ──────────────────────────────┐
 │  one file per live Claude Code process                       │
 └──────────────────────────┬───────────────────────────────────┘
                            │ kill(pid, 0) for each of them
                            ▼
                   reconcile  →  adopt  →  prune
```

## Why two sources and not one

This is the project's structural decision, and it is worth understanding before
anything else.

**The hooks report what *happens*.** They are precise, timely, and they know the
semantics: only a hook can tell "the turn finished" apart from "the turn was cut
down by a rate limit".

**The hooks never report what *disappeared*, nor what was already there.** Close
a Claude panel and no event tells you. Start the app halfway through the day and
the twelve sessions already open are invisible.

With only the first source the column fills with dead rows leading nowhere, and
starts empty every time. With only the second you would know *who exists* but not
*what state they're in*.

The periodic realignment does three things, in this order:

| Action | What it does | Why in this order |
|---|---|---|
| `reconcile(alive:)` | keeps only the sessions with a live process | remove the dead first |
| `adopt(_:)` | inserts the sessions never seen, as `idle` | then add the new… |
| `prune(alive:)` | drops whatever has been silent for 12 hours, unless its process was just confirmed alive | …and finally prune |

`adopt` **never overwrites** an existing row: what the hooks know is always more
precise than a deduction from the filesystem. Without that rule, a ready answer
would turn red on its own five seconds later.

`reconcile` with an **empty set is ignored**. An empty set almost always means
the directory read failed, not that every session vanished at the same instant.
Taking it literally would empty the column at the first I/O error.

## The four layers

### `LampBoardCore` — pure domain

No `import AppKit`, no network, no clock: `now` is always a parameter.
Filesystem access is confined to `Mailbox`, which creates and restricts the
mailbox directory through an injected `FileManager`. Everything that **decides** lives here: how a payload is interpreted,
which window matches a workspace, what color a traffic light takes, how the
column is composed.

It is pure not for elegance but because it is the only part that can be verified
in milliseconds and without opening any windows. Every time a decision slipped
out of here, it became invisible to the tests.

### `LampBoardApp` — the shell

AppKit, SwiftUI, Network.framework, AppleScript, `UserNotifications`.
It does I/O and draws. It **does not decide**: when logic turns up in here, it
belongs in Core.

The practical rule: if a function contains an `if` answering a domain question
("does this session deserve a traffic light?"), it is in the wrong place.

### `LampBoardTests` — domain

717 cases, instantaneous. They verify Core.

### `LampBoardE2E` — the real chain

98 cases. They launch **the production binary** against a fake home and talk to
it over HTTP, the way the hooks do. They go as far as running `hook.sh` with the
payload on stdin: in between sit bash, `curl`, the socket, the parser, the
decoder and the reducer.

They exist because in this project the worst defects have never been inside a
function: they were in the **seams** between a function and the world. See
[07 traps](07-traps.md).

## The state machine

Six states, ordered by urgency — what decides which session a project's row
shows, and which one a click opens; the rows themselves keep the user's order (D23):

| # | State | Meaning | Color |
|---|---|---|---|
| 0 | `awaiting` | blocks the work: a permission or an MCP dialog | blinking amber |
| 1 | `ready` | there is an answer to read | green |
| 2 | `failed` | turn cut short, nothing to read | solid red |
| 3 | `working` | processing | yellow |
| 4 | `waiting` | the turn is over; work Claude started is still running and will wake it | soft blue |
| 5 | `idle` | at rest | dim red |

Three properties govern the behavior, and they live on `SessionStatus`:

- **`urgencyRank`** — which session is a row's face, and what a hidden summary shows
- **`clearsOnFocus`** — whether a click clears it (`awaiting`, `ready`, `failed`)
- **`blocksDowngrade`** — whether it resists a late signal (`awaiting`, `ready`, `waiting`)

`failed` is deliberately outside `blocksDowngrade`: if the turn **resumes**,
yellow is the correct information and red would be a leftover. But a late
`PostToolUse` is not a resumption, and the reducer tells the two cases apart
explicitly — see `StateReducer.shouldKeep`.

### The displayed state is derived

`SessionState` has no `status` field. It has `baseStatus` — what the hooks say —
and it **computes** what you see:

```swift
public var status: SessionStatus {
    guard activeSubagents > 0 else { return baseStatus }
    switch baseStatus {
    case .awaiting: return .awaiting
    case .working: return .working
    case .ready, .idle, .waiting, .failed: return .waiting
    }
}
```

The reason lies with background agents. The real sequence is:

```
SubagentStart ×N → Stop (the parent turn returns control)
                 → … the agents work for tens of minutes …
                 → SubagentStop ×N
```

Taking that `Stop` literally paints **green** — "there is an answer to read" —
onto a session that is still working. Deriving instead of storing also solves the
way back: when the last agent finishes, the green that was set aside resurfaces
on its own, without anyone having to remember it.

The counter resets at the **next prompt**, not at the end of the turn: that is a
certain boundary, and it doubles as a safety net if a `SubagentStop` gets lost
along the way.

## From the column to the rows

`ColumnLayout.render(state, options)` is a pure function turning the state into
what gets drawn. It does four things at once, because they are interdependent:

1. **groups** by project (on by default: 22 sessions across 12 windows)
2. **filters** "only what's waiting", if asked
3. **orders** by the user's arrangement — never by state (D23); a project not yet
   placed follows the known ones, by name
4. **sets aside** the hidden ones into a summary that **lights up** if one of them
   asks for attention

The delicate point is `ColumnRow.sessionIdsToClear`: a click marks as seen **only
the sessions that were in the most urgent state**. Without that limit, opening a
project to answer a permission would erase the ready answer of another session in
the same project — and grouping would become a loss of information instead of a
reduction in noise.

The name a row shows can be the user's own (`RowNames`, D26): keyed by folder,
threaded through `ColumnOptions.names` into `ColumnRow.alias`, shown by every
surface that names a session to a person and believed by nothing that finds a
window or a file.

## Getting back to the window

This is the gesture that justifies the widget, and it is the most fragile part.
Two strategies, in order:

**1. Raise the exact window**, via System Events. Requires Accessibility *and*
Automation. Recognition happens in Swift (`WindowTitleMatcher`, scores
100/50/10), and all AppleScript receives is the **title** to look for:

```applescript
set candidate to (every window whose name is "…")
perform action "AXRaise" of item 1 of candidate
```

By title and **not by index**: reading the titles and raising are two distinct
Apple Events, and between the two the window order changes on its own. See
[07 traps](07-traps.md#the-index-that-moves).

**2. Fallback**: `open -b <bundle>`, with no path. Brings the editor to the front
without being able to create windows. It doesn't raise the right one, but it does
no harm.

The three outcomes (`raised`, `activatedOnly`, `failed`) are an explicit type
rather than an `Error?`, because they deserve different reactions: silence, a
note in the menu, an alert. Flattening them has already produced two defects.

## Other machines

A session on another machine is heard the same way a local one is: its hooks post to a loopback port *there* derived from that user's uid
(`AppConfig.remotePort(forUID:)`, 30000 + uid % 20000) — the far end of a
reverse ssh tunnel this app opens and keeps open (`RemoteTunnel`) back to its
own 9877 — and the script installed there
(`RemoteHookInstaller`, over ssh, with the same merge as the local installer) adds
an `X-LampBoard-Host` header. A signal with a host skips the editor-window lookup: no
lock on this Mac claims `/home/…`, so the session's own folder is its workspace.
The row is named like any other and carries an `R` before the name; which machine
it is on is in its card (`RowSummary.subtitle`), because the host was the same
word on every row of that node and it was eating the names.

The probe (`RemoteProbeScript`) is kept for one question the hooks cannot answer
— *is this pid still alive* — and a remote row is confirmed by it, never created:
a `claude` left in a tmux on the node is real and is not something you opened.
The click raises the **Remote-SSH** window of the folder, found by its `[SSH: …]`
title (`WindowTitleMatcher.bestRemoteMatch`). See
[D24](04-decisions.md#d24--other-machines-are-heard-through-a-tunnel-we-open).

## Sessions in a terminal

A `claude` started in a terminal posts the same hooks; what it lacks is an editor
window claiming its folder, so the resolver answers `nil`. With "Show terminal
sessions" on, the store then looks for the session's **live file** in
`~/.claude/sessions/` and, finding one, makes the file's `cwd` the workspace and
marks the row `origin: .terminal` — the file's folder, not the hook's, because the
hook's follows every `cd` Claude makes. No file, no row: that is what keeps a
forged host header or a foreign path out. The poll adopts such sessions the same
way, and the switch turning off removes them at once (`.forget(origin:)`).

The row is named by its conversation title, read off the main actor from the
head of the transcript (`SessionTitleReader` → `TranscriptTitleScanner`, the rule
`TranscriptTail` already uses) and remembered through `.remember(sessionId:title:)`.
The click resolves the session's **seat** at click time (`SeatResolver`): the
pid from the session file, the `procStart` guard against a reused pid, the
ancestry from the kernel (`ProcessTree`, no `ps`), and a pure classification
(`SeatClassifier`) into a tab of a known terminal (Terminal.app, iTerm2,
Ghostty, WezTerm, kitty) on a tty, a tmux or zellij pane, an editor, some other
application, or unknown. `TerminalFocuser` then asks the
terminal's own dictionary to select the tab on that tty — one of two strings from the process table that enter a script — the other is the
zellij session name in the title fallback — and each only after validation
(`TTYName` for the tty, the session-name pattern for the name).
A tmux seat is two hops — the pane on that tty selected inside tmux, then the
attached client's own chain; a zellij seat pairs the client with its server
through their Unix sockets and follows the client's chain, falling back to the
tab titled by the session name. Ghostty is matched in Swift on what its dictionary lists (title, working
directory) and, when that names more than one surface or none, by a marker title
written to the session's tty (`TerminalTitle`); WezTerm by tty through its CLI,
kitty by pid over its socket (`TerminalListings`). Editor seats go the way editor rows go. See
[D25](04-decisions.md#d25--a-folder-nobody-claims-is-a-place-too).

## Sessions inside the desktop app

Claude Desktop runs a session in one of two places, and only one of them is on
this machine. A **cloud** session runs on Anthropic's servers and leaves nothing
here; a **local** session runs here, as a child of the application, and writes
exactly the files every terminal session writes — a session home with its own
`.claude` inside it, holding `sessions/<pid>.json` and
`projects/<encoded cwd>/<session>.jsonl`. The application says which is which
itself, in `resolvedFolderKinds`, and that answer is taken rather than guessed at.

Two things there are unlike every other row, and both are declared rather than
worked around.

**The colour is derived.** Those sessions run with a `CLAUDE_CONFIG_DIR` of their
own and never read the hooks on this machine, so nothing announces what they are
doing. `TranscriptTurn` reads the end of the transcript and answers *running* or
*answered*; it cannot see a session waiting for a permission, so such a row never
goes amber and never red. See
[D35](04-decisions.md#d35--a-colour-may-be-derived-and-it-says-so).

**The row's life is not the process's.** That process lives one turn: the
application starts it to answer and removes its session file when it exits, so a
row built on it vanished at the moment there was an answer to read. Presence comes
from the index beside each conversation and its transcript, bounded by three gates
that are the application's own answers — a folder resolved as local, not archived,
active within `sessionStaleAfter`. The session file still means one thing, and
only that: a turn running right now. See
[D36](04-decisions.md#d36--presence-is-what-a-conversation-leaves-not-what-a-process-is).

A click raises the application. There is no window per conversation to select and
no deep link into one, so the row promises exactly what it can do.

## Concurrency

Two contexts, and two boundaries to cross:

| Context | Who lives there |
|---|---|
| **main actor** | state, views, everything that touches windows |
| **server queue** (concurrent) | socket, HTTP parsing |
| **`CodexProbe`** (actor) | the Codex scan: `lsof` over every live `codex` pid |

**Server → state, reading**: goes through `SnapshotBox`, a lock-protected box the
store fills on every change. There is no waiting in either direction, so no
deadlock is possible.

**The sweep → the Codex probe**: started, never waited for. The probe spawns a
subprocess, and instrumented on a machine with eighteen live `codex` processes it
was **80 milliseconds of a 150-millisecond pass**, four times a minute, on the
actor that draws. It runs on an actor of its own; what comes back to the main
actor is arithmetic on its answer. Being an actor also serialises it, so a probe
that runs long — `lsof` is documented to pause on a descriptor sitting on an
unreachable mount — cannot have a second started on top of it.

`SweepCost` records where each pass went, under `LAMPBOARD_DEBUG`, because that
is what settled the question in the first place and what would show it moving
again.

**Server → main, writing** (`POST /next`, which has to raise windows): goes
through `AppDelegate.onMain(timeout:)`, which enqueues a `DispatchWorkItem` and
waits at most two seconds, **cancelling it** on expiry. A `main.sync` would work
today and would seize up the day somebody, on the main queue, waits for the
server's queue.

That timeout protects the server's queue, **not** the main actor: if `focus` gets
stuck on an AppleScript to an unresponsive app, the interface freezes anyway. It
is the same risk a click on a row already carries — `/next` doesn't add it, it
only adds a way to trigger it from outside.

## The transport

`POST /signal` — the hooks' entry point. **Without authentication**, and that is
a choice: the script runs as the user and could read the token, but a hook that
fails authentication would block a Claude Code turn for the sake of a decorative
widget. The risk is asymmetric.

`GET /sessions` — the state as JSON. **With a token**, because it exposes the
names and paths of the open projects.

`POST /next` — raises the next waiting session. **With a token**, like the three
slot routes below: they are the routes that act outside the process.

`POST /open`, `POST /new`, `POST /chat` — slot-addressed (the slot number is the
body, 1–9): raise the slot's window, open a new conversation in its project, or
open its chat window. **With a token**, for the same reason as `/next`.

`GET /health` — free, it only tells you whether the app is alive.

The socket is bound to `127.0.0.1` via `requiredLocalEndpoint`. The
`acceptLocalOnly` flag, which looks like it would do the same thing, limits to the
**local network** and not to the machine — see
[07 traps](07-traps.md#the-socket-that-looked-local).
