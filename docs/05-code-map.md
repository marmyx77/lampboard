# Code map

~52,700 lines of Swift across five targets. For each file: what it contains, why
it exists, and **what you would break** by touching it.

```
Sources/
  LampBoardCore/  15,660 lines · 125 files  pure logic, zero AppKit
  LampBoardApp/    19,654 lines · 107 files   shell: AppKit, network, windows
  LampBoardTests/  13,132 lines · 75 files   941 cases, instantaneous
  LampBoardE2E/    3,850 lines · 16 files   130 cases, the real binary
  TestKit/            369 lines ·  4 files   minimal assertions
```

No file exceeds 796 lines. The limit the project sets itself is 800.

---

# LampBoardCore

No `import AppKit`, no I/O, no implicit clock: `now` is always a parameter.
Everything that **decides** lives here.

## `Config/`

### `AppConfig.swift` · 569
Every constant in the project. Port, paths, thresholds, excluded entrypoints.

`homeDirectory` honors `LAMPBOARD_HOME` and is the root of **every** path: it
is what makes the e2e tests possible without touching the real `~/.claude`.

> **Touching here** changes behavior everywhere. `sessionStaleAfter` (12 h) and
> `liveSessionPollInterval` (5 s) are tuned to real use with a dozen sessions:
> lowering the first makes live rows disappear, raising the second leaves dead
> rows clickable.

## `Models/`

### `SessionStatus.swift`
The six states and the three properties governing their behavior:
`urgencyRank`, `clearsOnFocus`, `blocksDowngrade`.

> **Touching `blocksDowngrade`** changes which states resist a late signal.
> `failed` is deliberately outside it: the reducer handles it separately.

### `Harness.swift` · 153
Which coding agent a session belongs to, and — the reason the type exists at all
— **what that agent is unable to say**. One row shape for every harness; what
differs is what a row can promise. `cannotReport` is checked against each
vendor's published event list rather than guessed, and every consumer that would
otherwise infer a state from silence has to consult it first.

The rule it encodes: an absence is declared, never inferred. Codex publishes no
error event of any kind, so a Codex row never turns red and the card says why.

### `PendingAsk.swift` · 102
What a blocked session is asking for, as one line: `Bash: git push origin main`.

The allow-list is the design. `tool_input` is free-form and an `apply_patch`
carries the **contents of the file being written**; only `command`, `file_path`,
`path`, `url` and `description` are ever shown, and only as strings. Adding a key
is a decision about what may appear on a floating panel above a shared screen,
not a formatting tweak.

Exists for Codex and not for Claude Code, and that asymmetry is a finding: the
Claude binary builds its notification as `Claude needs your permission to use
${tool}` and carries no `tool_input` at all.

### `SessionState.swift` · 487
The state of one session. **Immutable**: every transition produces a new instance
through `replacing(…)`, which uses double optionals to tell "leave it alone"
apart from "clear it".

It keeps `baseStatus` and **computes** `status`. Read the comment on `status`
before changing anything here: it is the heart of the subagent correction.

> **Touching the computation of `status`** risks reintroducing green during
> background work. Coverage: `SubagentSuite`.

### `ColumnLayout.swift` · 396
From state to rows: grouping, filtering, slots, hidden summary. A pure function.

`ColumnRow.sessionIdsToClear` is the delicate point — only the sessions in the
most urgent state.

`sorted` is the second one. Rows come out in the **user's order and nothing
else**: no state moves a row, which is what makes `open 3` worth binding to a key
and what keeps a row from sliding under the pointer — see
[D23](04-decisions.md#d23--the-column-does-not-reorder-itself). Urgency still
decides which session is a group's face and which one a click opens.

> **Touching the ordering**, remember two things: the row `id` has to stay stable
> across two computations, or SwiftUI rebuilds the rows and the panel flickers;
> and letting any state into `sorted` would silently break every bound key.

### `RowNames.swift`
The names the user gave to rows, by folder: read, renamed, bounded. A name is
what the panel shows and nothing that finds a window or a file ever believes it
(D26).

### `Codex/LsofOpenFiles.swift`
Which regular files a live process holds open, parsed from `lsof` **field**
output rather than columns, because a path may contain spaces and the column form
has already cost this project an afternoon elsewhere.

This is the evidence a Codex session rests on. A rollout on disk proves a session
existed; a process holding it open proves it is loaded now. An empty result means
"this call saw nothing", never "the session is gone": the caller has to keep those
apart or one slow `lsof` deletes every Codex row.

### `Codex/CodexHolders.swift`
Which process is holding one rollout open, right now. The scanner asks this of
every Codex process at once to draw the column; the click asks it of a single
file, because a Codex session leaves no session file naming its pid and the
descriptor is the only thread from a row back to a process, and from a process up
to the terminal tab it is typed in.

Two processes on one rollout give the **same** answer every time: the order `lsof`
prints in is not a promise, and a click that raised a different tab each time
would be worse than one that raised none.

### `Codex/CodexScanResult.swift`
`CodexEvidence` and `CodexScanResult`: what a probe found, and whether it found
anything. Values, and here rather than beside the scanner that produces them,
because what the panel **decides** about them has to be testable without a disk.

### `Codex/CodexAdmission.swift`
The decision that used to be one line inside the store:

```swift
guard case .observed(let evidence) = result else { return }
```

The right rule — a probe that could not answer is not a session that ended — and
nothing was watching it. Deleting the line left the suite green, because
producing an unavailable probe in a test would have meant making `lsof` genuinely
hang. Now it is a value handed to a function, and the case that covers it simply
says `.unavailable`. `nil` means "we did not get to look"; `.observed([])` means
the conversations are over, and the two must never be spelled the same.

### `SessionProcess.swift`
The process a Claude Code session runs in.

Claude Code writes one file per running session in `~/.claude/sessions`, named
after the process id and carrying the session id beside it. That is the only
place on this machine where the two are stated together: the process holds no
descriptor on its transcript and names nothing in its environment.

It carries the start time because process ids are reused and those files outlive
what they describe — fifteen of them here, several naming processes that had
ended. Ending a pid because a file says so, without checking the pid is still the
same process, is how a panel comes to kill something nobody asked about.

Codex has no equivalent, and that is a fact about Codex: one shared daemon serves
every conversation, so no process belongs to a single one.

### `Codex/CodexApproval.swift`
Who answers when Codex asks for permission.

Codex publishes `PermissionRequest` for a tool call that needs approving, and the
event never says **who** approves it. With a reviewer of `auto_review` the answer
arrives by itself in a few hundred milliseconds and nobody was waiting, while the
row blinked amber for as long as the *command* ran — amber only lifts at
`PostToolUse`. Measured in one audit: 6.0 s, 6.4 s and 31.0 s.

The reviewer is not on the wire but it is in the rollout, whose path the event
carries. It changes during a session, so it is read per request. An unknown value
or a rollout that does not say produce `nil`, which shows the request: a false
amber costs a glance, a swallowed one costs a stopped turn nobody knows about.

### `Codex/CodexTrust.swift`
Whether Codex will actually run the hooks it has registered.

The state this exists for is one a person meets and cannot diagnose: the hooks are
in `hooks.json`, `status` says registered, and the row stays silent. Codex will
not run a hook it has not been approved for, and **when it declines it says
nothing**.

It does record the approval, one entry per event, in `~/.codex/config.toml`. The
key carries the path of our hooks file and the event name in snake_case, so "is
there any record of approval for this event?" can be answered exactly. The hash
beside it cannot: eight plausible inputs were tried against a real entry and none
reproduces it, so a record means the approval **happened**, not that it still
holds. Running the installer twice was measured to produce a byte-identical file,
so a reinstall costs no trust; changing the events, or the hook script's path —
which is what renaming this project did — does.

Three answers, and the third is the one that was missing: **approved**,
**never approved** (this hook will not run, and that is certain), and
**unreadable**, which is never reported as either of the other two. That last
distinction is not theoretical: the installer told a person with no Codex
configuration that everything was already trusted, because the list of events
awaiting approval is empty in both cases.

### `Codex/CodexSessionMeta.swift`
What a Codex rollout says about itself in its first line, and the **only** place a
scanner-found session may take its folder from. This is the replacement for a
security property rather than its removal: the old bound on the unauthenticated
`/signal` route was a Claude Code window lock claiming the folder, which a machine
running only Codex does not have. Reading the folder out of a file a live process
is holding open keeps the bound.

Fails closed at every step. A first record that is not `session_meta`, a relative
`cwd`, an empty id: nothing at all rather than a row pointing somewhere plausible.

### `Codex/CodexSurface.swift`
Which Codex a session runs in, read from the executable behind its pid. Better
evidence than the rollout's own `originator`, which has been seen as four
different strings in one week inside a format its own documentation calls
unstable. Matches on path **segments**, so a folder called `ChatGPT.app` in
somebody's home cannot make a terminal session claim to be the desktop app.

`commandLine` deliberately promises nothing about focus: the same Homebrew binary
runs in Terminal, Ghostty, tmux and VS Code's integrated terminal.

### `PanelMetrics.swift`
How tall the panel has to be to draw what it is drawing, in Core **because it bit
twice**. The window sized itself from one formula while the column laid the rows
out with another, and the two agreed right up until a project could be opened:
then they differed by the padding a block adds, the window came up short, and the
last row was cut in half. The first repair corrected one of the two formulas,
which is how the same defect arrived a second time.

Nothing caps the column here. A ceiling of twelve rows was the first answer and it
was wrong twice over: it hid the rows under an opened project, and there are
people with twenty sessions open. The screen is what bounds it, and that is the
caller's business.

### `ShortSpan.swift`
How long ago, in one number and one letter, and **never more than two digits**.

The ceiling is the design. This field shares a 240 point line with the name and
holds layout priority over it, so every character it takes comes off the name on
that row alone. It replaced a clock time, `14:49`, and a date, `22/07`, and width
was only half the reason: a clock time has to be **computed** against the current
time before it means anything, while `3h` is read.

Minutes run to 99 before the hour takes over, because `90m` and `1h` are the same
fact and the one with the digits says it more precisely. Between one hour and ten
there is a decimal, `1.7h`, since `1h` covers everything from one hour to two, and
on a session you are deciding whether to interrupt that is the difference that
matters. At ten it stops: `10.5h` is three digits.

### `GitIdentity.swift`
What repository and branch a session is working in — one value, because the three
facts only mean anything together: a branch with no repository names nothing, and
the worktree flag is a statement *about* the repository name.

**Resolved by the hook script, never here.** The app must not read under a
session's working directory: macOS gates Desktop, Documents, Downloads and network
volumes as separate grants, so a `<cwd>/.git/HEAD` read from the app pops a
folder-access prompt the first time a session appears under any category not yet
granted, and on a poll it recurs rather than asking once. The script runs in the
user's own shell, under the terminal's grants, and ships three headers.

Read at a session start **and** at the end of each turn. The start alone is not
enough: a brand new session has written no transcript yet, so its start earns no
row (D44) and the identity goes in the bin with it — only a resumed session would
ever show a branch. `Stop` rather than `UserPromptSubmit` for the turn, because
that one sits between the person pressing enter and Claude starting.

### `RowSession.swift`
The conversations inside one row, told apart. A project can hold several sessions
at once, and grouped they were identical in every field the panel draws: same
window label, same entrypoint, same folder, same slot, differing only by a UUID
nobody sees. `members` gives each one a position and a name.

Ordered by **when it was first seen**, never by urgency: the column does not
reorder itself (D23) and neither may the list inside a row, where the lines sit
closer together and a misclick opens the wrong conversation. Ties go to the id,
because sessions adopted in one pass share a timestamp.

### `AccountLimits.swift`
The account's allowance, parsed. Three bars: the five-hour window, the week, and
one model's own weekly cap — on the account this was written against, Fable 5.1.

Reads the `limits` array and **not** the named fields beside it. The same answer
carries `five_hour`, `seven_day` and about ten keys called `amber_gauge`,
`cedar_ember`, `juniper_tide`, `nimbus_quill`: unannounced buckets that will be
renamed without anybody being told. `limits` is the same information already
normalized, and it is what `/usage` itself draws.

The label of the scoped bar is **read** from `scope.model.display_name`, never
written here. A plan change has to move the label with it, or the panel would go
on naming a model the account no longer has.

Claude Code's free on-disk copy, in `~/.claude.json`, is deliberately not used:
measured on 20 September 2026 it said 0% and 6% while the account was at 9% and
15%, fifteen hours out of date. A number nobody can tell is stale is worse than no
number.

### `ClaudeAccount.swift`
Which Claude account a machine is signed in as, read from `~/.claude.json` — an
address and a uuid, neither of them secret.

It exists because the allowance strip was built on the unexamined assumption that
a person has one account. Measured on 20 September 2026 that assumption was wrong
here: this Mac is an organization account on a Team plan, the node the tunnel
reaches is a personal account on a Max plan, and most of the work happens on the
second one. A single unlabelled bar in that situation is not incomplete, it is
wrong (D47).

The uuid, not the address, is what decides two machines are spending the same
allowance. Without one on either side the answer is *no*: drawing a group twice is
a smaller failure than hiding a second account's allowance.

### `AllowanceReport.swift`
One account's allowance and where it was read, plus the rule that collapses two
readings of the same account into one. The local reading is kept, because its age
is the one this app controls.

### `RemoteAllowanceScript.swift`
The Python that reads another machine's allowance, run there over ssh. **The
request is made on the far side** and only the answer crosses the wire: pulling the
token back would put a credential in this app's memory for the sake of three
percentages, and the node already has both the credential and a network. On Linux
the credential is a file at `~/.claude/.credentials.json`; the keychain branch is
there for a node that is itself a Mac. It also reads, on the node, the accounts
the Claude application runs Claude Code as there (`hosted`), and turns a node's
answer into reports.

### `AllowanceThrottle.swift`
What the strip does when Anthropic answers 429: the wait before the next ask
doubles from the ordinary interval up to twenty minutes, and the last reading of
each account stays on screen with its own age for up to half an hour instead of
the strip going empty (D54).

### `HostedCredentials.swift`
The accounts Claude Code is spending without having signed in itself. The Claude
application hands its own account to the Claude Code it starts — on this Mac or
on a node over ssh — as `CLAUDE_CODE_OAUTH_TOKEN` in the environment, and puts it
nowhere else: not in the keychain, not in the credentials file. The running
processes are the only place it can be read. Only Claude Code's processes are
looked at (they carry `CLAUDE_CODE_ENTRYPOINT`), each account once, at most four;
the token is borrowed exactly like the keychain one (D53).

### `ClaudeCredentials.swift`
The access token inside the blob Claude Code keeps in the keychain, and nothing
else. The blob also holds a refresh token; there is deliberately **no function
here that reads it**. Spending it could rotate the pair and sign the person out of
Claude Code, and an absent capability is a stronger guarantee than a comment
asking nobody to use one.

### `UpdateSwap.swift`
The script that finishes an update after the application has quit, as text.

Here, and not beside the installer that runs it, for two reasons. It has to be
**testable**: the swap is the one part of updating that cannot be exercised from
inside the running application, because it starts by waiting for that
application to die. And it must **not be a file**. The first version wrote
`swap.sh` into the same temporary directory as the staged application, and
`install()` deleted that directory the moment it returned — while the script was
still in its wait loop. By the time it reached the move, what it was moving had
been erased: the application quit, the swap rolled back, and nothing changed.
Deterministic, and shipped in `v0.1.0`.

Passing the body through `bash -c` removes the class of problem rather than the
instance: there is no script on disk to delete, and no question about whether
bash had finished reading it, so the script can clean the workspace itself as its
last act. `LampBoardE2E` runs this exact text against two fake bundles and checks
all three endings.

### `ReleaseVersion.swift` · `ReleaseFeed.swift`
The update check as a parser that says no. It reads the **redirect** the stable
download address answers with — the version is in it, and reading it costs no API
call and none of the sixty an hour an office shares (D50) — and keeps the API's
JSON as the fallback for a network that swallows redirects. Versions compare as three integers,
because `"0.10.0"` sorts before `"0.9.0"` and the tenth release would silently
stop being offered. The download URL is **pinned** to this project's own
releases: an answer arriving over HTTPS is still only an answer, and a field that
could name any host would be choosing the code that runs on a Mac where this app
holds the Accessibility permission. Drafts and pre-releases are published without
being offered, which is what they are for.

### `Transcript/TranscriptActivity.swift`
When a conversation last **said** something, which the file's modification date is
not. The comment this replaced claimed the transcript is the only file that moves
when a session does something, and that was measured to be false: three projects
untouched for days all read as active within the hour, because tooling around the
session had appended `last-prompt` and `bridge-session` records carrying no
timestamp at all.

So the answer comes from the last record that carries one. A record with no
timestamp is not a moment, whatever it did to the file, and a row that invents
activity is worse than a row that says nothing.

### `TranscriptPathPolicy.swift`
Which transcript paths the app will open: only those under `~/.claude`, after
`..` has been resolved and with the trailing separator that stops a sibling
directory from passing as a child. `POST /signal` still accepts a request with
no token (D7), and the path it names is opened for reading — measured before this rule existed,
a forged signal naming `/etc/passwd` produced a row holding it within a second.

### `PanelIssue.swift` · `PermissionWait.swift`
A fault the person looking at the panel can fix, as a value rather than a
sentence: which System Settings pane grants it, the line the strip shows, the
paragraph behind the button, and the `tccutil` cure for the records macOS keeps
per signature. `PermissionWait` is the one tick of the wait that follows —
granted, expired, or neither — with the tie resolved in favour of finishing the
click, because a permission granted at the last second was still granted.

### `RowOrder.swift`
The column's order as data: give newcomers a place (`absorbing`), move a row to
where the user dropped it (`placing`, `moving`) — translated from what is visible
into the full list — and read a slot off a position. It lives in Core because
deciding where a row goes is a decision, and decisions in the shell are decisions
no test can see.

### `TrafficLightState.swift`
The session dictionary plus the operations: `upserting`, `removing`, `pruning`,
`ordered`.

`pruning` applies to **every** state, `working` included. The exemption that used
to be there made yellows immortal, because `Stop` doesn't fire when you interrupt
a turn with Esc.

### `HookSignal.swift` · 253
The validated signal. `deservesTrafficLight` and `subagentDelta` are the two
questions the reducer asks it.

### `HookEventKind.swift`
The ten events registered by default, plus one decoded and registered only with `install-hooks --with-tool-events` (`PreToolUse`), and the five
`Notification` subtypes. An unknown event is not an
error: it is ignored, so the app doesn't break when Anthropic adds more.

### `StopFailureReason.swift`
A **closed** set of ten causes. An unexpected value falls back to `unknown`
instead of propagating as a free-form string all the way to the row.

`hasUsableOutput` is true only for `maxOutputTokens`: there the text exists, it
is merely incomplete, so the row is green rather than red.

### `SessionOrigin.swift`
`.editor` or `.terminal`: the kind of place a row lives in, set by whoever
resolves the workspace and read by everything that treats a terminal row
differently (D25). Not on `Workspace`, which is the row's identity.

### `Workspace.swift`
`Workspace` plus `PathNormalizer`. Path comparison is **component by component**,
not by string prefix: without that, `/dev/project-old` would come out as inside
`/dev/project`.

It deliberately does not resolve symlinks: `cwd` and `workspaceFolders` come from
the same source and are already consistent.

### `PanelHome.swift` · 45
Where the panel lives: a window of its own, or under a lamp in the menu bar.

The column is the same column in both, drawn by the same view from the same
rendering; what changes is where the window sits, what it floats above, and
whether looking elsewhere puts it away. That last one is the whole of the
difference: a drop-down closes when you click elsewhere, and that is what makes
it a drop-down rather than a window hanging off an icon.

Whether the lamp is in the menu bar is a **separate** switch, because somebody
who keeps the panel floating all day may still want the lamp for the moments the
panel is behind a full-screen window. Only one direction is forced: a panel that
lives up there needs the lamp, because nothing else could bring it back.

### `NotificationText.swift`
What a notification says (5.6): for a waiting session the command or question, for
a failed turn the reason, for a finished one the first line of the answer without
Markdown's marks, cut at 160 characters where it says so. Never the last message
for a waiting session: a `Notification` payload carries none, and the row still
holds the previous turn's reply. Also the menu bar's `wanting · working` counter.

### `MenuBarSummary.swift` · 123
What the lamp shows, computed from the `ColumnRendering` the panel draws rather
than from the state behind it.

Grouping, the filter and the hidden set all change which rows a person can see,
and a lamp computed from `TrafficLightState` would answer for rows the column is
not showing. Then the two disagree, and the one that is wrong is the one with no
room to explain itself. Hidden rows count, for the reason D4 gives: a hidden
project is not a forgotten one.

It blinks for exactly the three states a click clears — the three that mean
*there is news here nobody has taken in*. Yellow and blue never blink, because a
signal that is on for most of the day is not a signal.

### `MenuBarPlacement.swift` · 68
Whether the lamp the system agreed to show is a lamp anybody can see.

`NSStatusItem` has no way of failing: on a full menu bar it hands out an item,
reports it visible, gives its button a window with a frame, and draws nothing.
Measured — twenty-six items in one process, twenty-six visible, none on screen,
frames marching leftward from the notch to −345. So the question is answered from
geometry: is that frame inside `auxiliaryTopRightArea`, the strip the screen says
status items live in.

Three answers and not two. The frame is `(0, 0, 28, 0)` on the turn the item is
created and settles three tenths of a second later, so *not yet placed* is its own
verdict — read as a refusal it would move everybody's panel out of the menu bar on
every launch. See [D41](04-decisions.md#d41--a-home-you-cannot-be-brought-back-from-is-not-a-home).

### `PanelPlacement.swift`
Where the panel hangs, and why it hangs from the **top**.

A column grows downward as sessions appear, so one of its horizontal edges has to
be the fixed one, and it is the top: the eye goes to a known place to see whether
anything needs it, and a place that moves whenever somebody opens a project is
not a known place. `visibleFrame.maxY` already sits below the menu bar, so
hanging from it is the same thing as hanging from the menu bar.

The defect it closes was a ratchet. The position kept across launches was the
**bottom** left while every resize held the top still: the panel came back 65
points tall at the remembered bottom, grew nearly seven hundred points downward
from there, and saved that. A few launches walked it off the edge of the display,
where the rows that mattered were the ones underneath it.

The frame is clamped whole into the visible area rather than merely checked for
overlap — the old rule asked whether the frame touched a screen at all, which a
panel hanging one pixel over the edge passes.

### `Seat/TerminalTitle.swift`
Setting a terminal's title by writing to the tty a session runs on, which is how
two Ghostty surfaces in one folder are told apart.

Every other host answers this question directly: Terminal.app and iTerm2 expose
the tty, WezTerm does, kitty matches on the pid. Ghostty lists an id, a title and
a folder, and two Codex conversations in `~/Development/turing` share the last
two — measured, and the click could only ever raise the first of them. So the
question is asked the other way round: write a title nobody would choose to that
tty, ask which surface now carries it, put the old one back. The surface that
changed **is** the surface on that tty.

Writing to a slave pty is a **display, never an input** — the bytes travel to the
emulator holding the master, which is how `wall` and `write(1)` work — so nothing
is typed into the program running there. The title written home is stripped of
control characters first: it came out of the terminal, and a program is free to
put anything in its own title.

### `CanonicalPath.swift`
A path as the filesystem itself spells it, through `realpath(3)`.

Two programs can name one folder differently and both be right: the volume is
case-insensitive and case-preserving, so a shell keeps whatever was typed while
everything reading the folder from the kernel keeps what it was created with.
Measured — Ghostty listed a live tab as `…/development/turing` while the session
in it reported `…/Development/turing`, and the click stopped at activating the
application. It settles the links on the way too, `/var` to `/private/var`
included, which Foundation deliberately leaves alone.

A path naming nothing comes back untouched, which is what makes it safe to apply
anywhere.

### `RowSummary.swift` · 244
Everything a row can say about itself, as **fields** rather than as a paragraph:
title, state, subtitle, an ordered grid of label/value/detail, the per-session
list of a group, the last message, the help line. It used to be a `private var`
on a SwiftUI view that appended sentences to an array — untestable by
construction, and, as it turned out, never once displayed. What a row tells you
is domain; only how it looks is drawing.

### `RelativeTime.swift` · `CompactDuration.swift`
The labels for the right-hand slot. `RelativeTime` reasons in **calendar days**:
at 00:30 an event from 23:50 is yesterday — `1d` — and not "40 minutes ago". The
row abbreviates and the tooltip spells it out, which is a trade that only became
available once the panel drew its own tooltips (D32).

### `StringHelpers.swift`
`trimmed`, `nilIfEmpty`, `padded(to:)`. The last one exists because
`String(format:)` **ignores** the width on `%@` placeholders.

## `Desktop/`

The Claude Desktop application, and the one kind of session it runs that this
machine can see anything of.

### `ClaudeDesktop.swift`
The application under both names it goes by — `local-agent` in a local session
file, `claude-desktop` in the hooks and session files of 2.1.281 — asked through
`isEntrypoint`, never compared with `==`: the second spelling, met on a node, sent
the click looking for an editor window.

Where the application keeps a whole Claude Code home per conversation, how a
session home names its index, and `DesktopSessionIndex` — the folder, the title,
the model, the transcript's id and the moment of the last activity.

The index is the surface's **only** durable evidence, and that is measured rather
than chosen. The session file a local session writes is the same one every
terminal session writes, and it exists for exactly as long as the agent process
does, which here is **one turn**: a conversation whose last word landed at
22:44:38 left an empty `.claude/sessions` directory stamped 22:44. A row built on
it appeared while the model worked and vanished at the moment there was something
to read.

`resolvedFolderKinds[].kind == "local"` is the application's own answer to
whether the work is happening on this Mac, and the only thing separating a
session that is readable from a cloud one that leaves nothing here at all.

### `DesktopWorktree.swift`
The name of a row the Claude application runs in a worktree of its own. The
application can give each conversation a linked worktree under
`.claude/worktrees/` with a generated name; such a row reads `Ledger ·
vigilant-ramanujan` — the main repository, then the worktree without its numeric
tail — instead of the generated folder alone. Only the application's rows: an
editor row's name is its window's title (D57).

### `DesktopConversation.swift`
The two judgements a Claude Desktop row rests on, kept away from the disk so they
can be argued with: whether what was found is a row, and what colour it may
honestly be.

Three gates, each the application's own answer: a folder it resolved as local, not
archived, active since the horizon — without which every conversation ever held is
a row, and there are fifty-one of them on this machine going back to April.

The colour carries the moment its evidence is dated, and the two kinds are dated
differently. A colour read off the transcript is dated by the transcript, so a
click is never undone by the next sweep re-reading the same answer. A colour read
off a live process holding the session file is dated **now**, because it is not a
record of anything: it is true at the moment of looking. Dating that one by the
transcript is the bug the end-to-end suite caught — a turn that has just started
has written nothing yet, so a row cleared a moment ago could never go yellow
again.

## `LampMaster/`

LampMaster, the director: once an hour it reads every session and suggests at
most three things — one session knows what another needs, something waits or is
stuck, two sessions overlap, work is done and can be closed, a problem was solved
before somewhere else. This folder is the part that decides; nothing here runs a
model or reads a disk (D58).

### `SessionCard.swift`
What LampMaster knows about one conversation: the last three prompts, the last
answer, the model and context, the files written, the calls that failed, and what
got saved — commits, merges, pushes, pull requests, test runs. Small on purpose:
eight conversations fit in about 2,500 tokens. `lastAnswerAsks` is a heuristic
(a question mark, or a short English list of hand-overs) and is labelled as one;
the round reads the answer itself.

### `SessionCardReader.swift`
Fills the card from transcript chunks, keeping the line a chunk cut in two, like
`TranscriptTail`. Prompts and answers come from `TranscriptDecoder`, so a tool
result is never mistaken for something the user typed. A shell command counts as
a milestone only when its result comes back without an error, and only by the
verb after `git` and its global options: a commit message that says "merge" is
not a merge. Everything it keeps is bounded.

### `FailureFingerprint.swift`
An error with its paths, hashes and numbers taken out, so the same failure twice
reads the same — what "stuck on the same error" and "solved before" are both
matched on. A hash must contain a digit, or `defaced` would be one.

### `LampMasterSignals.swift`
What can be told without any model, with every threshold in one place: waiting on
you, stuck in a turn, the same failure three times in an hour, the same files or
branch as another session, finished, context nearly full. They show at once and
reach the round already worked out, so its tokens go on what only a model can
judge. A session asking through the panel's own amber is not also "waiting".

### `LampMasterFrame.swift`
The frame the round is given, under a 12,000-token budget: sessions with signals
first, then live ones, then the most recent. Over budget it shortens quiet closed
sessions before it drops any. A live session is in as soon as it has done
anything; a closed one for six hours, or a week if it was left asking.

### `LampMasterAdvice.swift`
The round's answer and the validator between it and the panel. A suggestion is
shown only if every session it names is in the frame, it quotes the frame word
for word for at least twenty characters, it was not shown in the last day, its
kind is not muted, its confidence is at least 0.5, and fewer than three were
shown already. A malformed answer is no answer.

### `LampMasterPrompt.swift`
The system prompt, the fenced user message and the JSON Schema for `--json-schema`.
The frame is declared as data: what sessions wrote may read like orders.

### `LampMasterCommand.swift`
The arguments of the isolated `claude -p` and the reading of its JSON envelope.
Every flag is there because of a measurement: without them one call cost 268,908
tokens, with them 689 (D58). The frame is **not** among the arguments — any
process can read those with `ps` — and goes in on standard input (D59). The
envelope's tokens are counted even when the run failed: the ceiling counts what
was spent. Drop a flag and the round shows up as a session in the panel, or
carries the user's connectors into every hour.

### `LampMasterSchedule.swift`
When a round runs and when it is skipped for nothing: switched off, no session to
look at, the frame unchanged since the last round, the day's 200,000 tokens spent.
The digest leaves out the minutes, which change by themselves; a threshold crossed
shows up as a signal, and signals are in it. A failed round counts as a run, or a
broken `claude` would be called every minute.

### `LampMasterLine.swift`
What LampMaster's line and cards say: never a blank line, the reason when there is
nothing ("Today's tokens spent · signals only", "Last round failed: claude was not
found"), the heading and glyph of each kind, and the button of each action. Asking
and replying copy the text and open the session, and the button says so: the panel
cannot write into a session until 0.6.

### `LampMasterMCP.swift`
The `lampmaster` MCP server's side of the conversation, one line in and at most one
out, pure: the tool itself is a closure. Claude Code 2.1.289 opens with
`server/discover`, from a newer revision of the protocol, and only then sends
`initialize` (measured, 4 October 2026); so every method it does not know is
answered "method not found" and the conversation carries on. The tools'
descriptions are written for the calling model, which decides by itself when to
call them.

### `LampMasterLookup.swift`
`overlaps`, `who_knows`, `precedents`: what a session can ask without a model
running. They answer with facts about sessions — id, project, title, state, files,
times, which words matched — and **never with another session's prompts or
replies**, because the answer goes into the asking session's context, which acts
with the user's tools, and a conversation can contain sentences that read like
orders (D62). The one prose they carry — a title, a file name, both chosen by
another session — is flattened to one line, stripped of control characters and
clipped, and every result opens with a notice that what follows is data about
other sessions, never an instruction.

### `LampMasterAsk.swift`
The question that does run a model: its schema, its prompt, the screening of its
sources and the limits. A source survives only when its whole quote is in the
frame — stricter than the round's evidence, because a real clause could otherwise
carry an invented one into another session. Twenty questions an hour, five per
session, and the same question within ten minutes gets the answer already given:
a session's model calls tools on its own, and a loop in one must not spend the day.

### `LampMasterRegistration.swift`
The arguments of `claude mcp add` and `remove` for the `lampmaster` server, and
whether it is registered, read from `~/.claude.json`. Read, not asked: measured on
4 October 2026, `claude mcp get` **starts** the server to check it, and a status
check must not launch anything. The port is named only when it is not the default.

### `LampMasterLedger.swift`
The records of `rounds.jsonl` and `suggestions.jsonl`, and what is read back from
them: the last run, today's tokens, the open suggestions, what the next frame is
told about the last day, when each key was shown. An open suggestion expires after
four hours, and settles by itself when its sessions leave the frame; a late click
on a settled card changes nothing. A line that does not decode costs that line,
not the file.

## `Mod/`

What the companion mod (`lampboard@lampboard`) reports from inside a session, and
what the panel keeps of it (D65). The mod brings what the hooks cannot know; the
colours stay with the hooks.

### `ModReport.swift`
The wire format of `POST /mod`, version 1: `start` (surface, interactive, model),
`measure` (the session's own context count, cost, rate-limit windows) and `end`
(Claude Code's own reason). Every field is bounded on the way in, because the route
takes whatever a process of this user sends: a session id of a UUID's alphabet,
numbers in range, words from a short alphabet, at most eight windows. A reading
from a measure is `reported`, and the reducer never lets a transcript reading
replace it.

> **Touching here** changes what the mod in `mod/` must write: a field renamed on
> one side only is a figure that silently stops arriving. A new version number is
> refused by an older panel, on purpose.

### `ModFiles.swift`
The mod's four files, compiled in (D66): the app installs what it reads, word for
word, with no network. `ModFilesSuite` holds them to the bytes of `mod/` and
`.claude-plugin/` in the repository, the one domain suite that reads a file.

> **Touching here** without bumping `version` leaves installed copies as they were:
> the launch refresh compares versions, not contents.

### `ModRegistration.swift`
The `claude plugin` steps that install and remove the mod, the marketplace with it;
whether `settings.json` has it enabled; the version in Claude Code's records, which
are searched rather than walked because their shape is unannounced; 2.1.287 as the
first release with mods.

### `ModTrust.swift`
What the mod does in sentences, built from `claude plugin validate --strict --json`:
Claude Code's own static reading of the module, not a description of ours (5.10).
The phrases say the capability and no more — which files, which address, is the
claim the text beside the switch makes, not dressed up as Claude Code's. A hook or
call the table has no words for is shown as Claude Code spelled it, and a valid
reading that lists nothing is unreadable rather than reassuring: a changed mod
must look changed.

### `ModAllowance.swift`
This Mac's allowance with the mod's windows in it (D67): `five_hour` and
`seven_day` become the session and week bars when they are newer than the usage
service's answer, which keeps the account's name and a model's own weekly cap; with
no answer at all they stand alone, labelled by the machine. A window with no bar
here, a gateway's spend limit, is left out.

### `ModLedger.swift`
Per session: surface, interactive, model, cost, the last rate-limit windows and
when they were read, why it ended. An empty list of windows keeps the last figures
(it means "no reading", never "every window at zero"); the account's windows are
the newest any session reported. Bounded at 300 sessions, least recently heard
first out.

## `Demo/`

The invented sessions and the tutorial's tour (D64). One place for demo data, so
one place to check that it holds nothing real.

### `DemoScript.swift`
The script the tutorial, the screenshots and the site's demo are played from: four
invented projects, beats in time, each beat a hook payload exactly as the installed
hook would post it, so the trial panel reaches its colours through the same server
and reducer as the real one. `DemoScriptCheck` refuses an account outside
`example.com`/`example.net`, a project outside the invented list, a home path or a
private address: the same rule as the repository's gate, applied to the one file
that is shown on screens.

### `GettingStarted.swift`
The two lists of *Getting started*: the real setup — hooks, the Accessibility
permission, and the switches that send something off the Mac, each explained before
its button — and the first gestures worth trying on one's own sessions. Every tick is
read from state the panel already keeps (row names, row order, LampMaster's answered
cards, the questions sessions asked), so nothing new is recorded about anybody, and
an item is done wherever it was done. Optional ones never count as left to do.

### `Tour.swift`
The tour's steps, every version's, and the ones this version shows: a step whose
feature is not installed yet is not shown. A step moves on with its own gesture —
the row clicked, the card answered — and with nothing else; there is no "Next".
Progress is kept by step id, so a version that adds steps still resumes at the
right one, and never leaves the Mac.

## `Seat/`

Where a session's process lives — what a click on a terminal row has to bring
to the front (D25). Pure: the shell reads the process table, this decides.

### `ProcessAncestor.swift`
One process on the way up, and `TTYName`: tty names come as `ttys003` from the
kernel and `/dev/ttys003` from dictionaries, and only the normalised form —
matched, after any `/dev/` prefix is stripped, against `^ttys[0-9]{1,4}$` and re-prefixed — not escaped — may enter a script.

### `Seat.swift`
`TerminalKind`, a short table like `IDEKind` (Terminal, iTerm2, Ghostty, kitty,
WezTerm, each with how its tabs are raised), and `Seat`: a terminal tab on a tty,
a tmux or zellij pane, an editor, some other application, or nothing known.

### `SeatClassifier.swift`
Chain → seat. Every chain it recognises was measured; `SeatSuite` pins them. The
two VS Code helpers are told apart by bundle name, not by the word "Helper".

### `TerminalScripts.swift`
The AppleScript that selects a tab by tty in Terminal.app and iTerm2, erroring
`-1728` when no tab is on it — the code the editor path already reads as "not
there".

### `MultiplexerListings.swift`
What `lsof` and tmux print, parsed: a Unix socket's own address and peer (the
client–server pairing for zellij) and tmux's panes and clients in the formats
this app asks for. Names that go back to tmux as arguments are validated first.

### `TerminalListings.swift`
What WezTerm's and kitty's CLIs print, parsed, and the Ghostty match: the pane
on a tty, the window running or fronting a pid, the terminal whose title or
folder is the session's. Ghostty's ids are validated before they enter a script.

### `ProcStart.swift`
The session file's `procStart` in its two forms — Linux ticks, macOS ctime **in
UTC** — and whether a process that started at a given moment can be the one the
file names. The guard against a reused pid; `stillHolds` is the live sessions'
version, which keeps what it cannot disprove and allows two seconds, since a wrong
answer there hides a live row.

## `Transcript/`

Reading what was actually **said** in a session. The hooks describe state; this
describes content, and the two never infer each other.

### `TranscriptTurn.swift`
Whether a conversation is in the middle of a turn, read from its transcript. The
one colour in this project that is **derived** rather than reported: a Claude
Desktop session runs with its own `CLAUDE_CONFIG_DIR` and never reads the hooks on
this machine, so there is nowhere to put ours that exists before the session does.

Two phases, because two are all the file can carry honestly. The assistant
speaking in words is the end of a turn; anything else — a tool call, a result
handed back, a fresh prompt — is the middle of one. A message holding both a
sentence and a tool call is **running**: the model routinely says what it is about
to do and then does it, and the tool call is the last thing it did.

What it cannot see is a session stopped waiting for a permission. No record marks
that pause, so it reads as running. It is the state the panel exists for and this
surface cannot give it, which is said rather than guessed at.

### `TranscriptEntry.swift`
`TranscriptEntry` and `Conversation`. Four kinds of line — human, assistant,
activity, note — because a transcript record and a chat line are not the same
thing: one assistant record holds an answer *and* six tool calls.

> **`Conversation` counts what it dropped.** The window keeps a bounded tail, so
> `trimmed(to:)` carries an accumulating `omittedEntries` and the view says
> "N earlier messages not shown". A reader has to be able to tell a short
> conversation from a truncated one.

### `TranscriptDecoder.swift` · 257
Record → entries. The point where a second stream of external data enters the
domain, and it fails **quietly**: an unrecognized record yields nothing rather
than an error, because Claude Code adds record types between releases.

> **Read the comment on `isHuman` before touching it.** A record of type `user` is
> usually *not* a message — the protocol files tool results and injected context
> under the same role. The shortcut "no `toolUseResult` means a person wrote it"
> was measured: it invents 579 user messages against 209 real ones.

### `TranscriptTail.swift`
The half of "follow a file" that can be silently wrong: a chunk almost always ends
mid-object, and parsing the fragment loses one record per read. It lives in Core,
away from the `FileHandle`, precisely so it can be tested.

### `TranscriptTitleScanner.swift`
The conversation title out of a file's head, under `TranscriptTail`'s rule —
one rule for the chat window and the terminal rows.

### `TranscriptWindow.swift`
Where a window opening on a long transcript starts reading: a few megabytes
before the end, on a whole line. A transcript can be half a gigabyte and the
window shows three hundred entries; reading it all was the beachball on ⌘+click.

### `CodexRolloutScanner.swift` · 194
Reads a Codex rollout: how full the window is, and how much of the plan's
allowance is gone.

Codex writes `model_context_window` into the same record as the count, so the
reading is `.declared` — nothing about that percentage rests on a table of ours.
Two rules are inherited from the Claude side because both were paid for there:
`last_token_usage` and never the cumulative total, and backwards **by position**,
never sorted by timestamp.

### `ContextReading.swift` · 223 · `ContextScanner.swift` · 117
How full a session's context is, read backwards from the end of its transcript.

The numerator is the sum of `input_tokens`, `cache_creation_input_tokens` and
`cache_read_input_tokens` — the same sum Claude Code's own status line reports as
`total_input_tokens`, verified against a live payload rather than derived. The
denominator is the model's window, which the transcript does **not** carry: it
records `claude-opus-5` and nothing else, and a session started with
`--model sonnet` and no suffix also resolves to a million. The table lives in
`ContextWindows`, mirrored in `Contracts/required-fields.json`, and
`check-contract.sh` re-reads Claude Code's binary on every run.

Four rules, each from a real file and each one the naive version gets wrong: a
`<synthetic>` record is a refusal with zeros, not a reply — one of them says
*"Prompt is too long"*, so reading the last usage-bearing record prints **0%**
at the moment a session is full; zero at the top level can hide the figure in
`usage.iterations`; the model comes from the same record as the tokens, because
a session switches models mid-flight; and the order in the file is not
chronological, because a resumed session replays its history.

The reading also carries what happened after it. Only assistant records hold a
count, so anything loaded since is invisible: measured across 171 compaction
boundaries the truth was a median of 1.00× and a maximum of **17.67×** the last
reading. Hence `exact`, `floor` and `unknown` — rendered `62%`, `≥62%` and `—`.
The `≥` and the dash are the feature; the bare number is the part that lies.

### `TranscriptLocator.swift`
Where a transcript **would** be, for sessions adopted from the filesystem with no
hook to tell us — after a restart, that is all of them. The rule matched 7065 of
7066 real transcripts; the exception is a git worktree, which is why the result is
a candidate the caller has to find on disk.

## `Chat/`

### `Mailbox.swift` · 264
Where a message waits between the composer and the session it is for, what may be
sent, what may become a filename, `ensureDirectory` — which `lstat`s the path and
refuses anything that is not a real directory of ours — and `MailboxReaper`, the
rule for what survives a restart.

> **The permissions are not decoration.** Dropping a file in the mailbox starts a
> turn that speaks in the user's voice with their tools. `0700`/`0600`, like the
> access token. They stop another account on the machine and stop nothing running
> as the user — which is stated in the doc comment rather than glossed.

> **`isValidSessionId` is an allow-list**, because the value is about to be
> concatenated into a path. A deny-list here is how you get a traversal.

> **`MailboxReaper` is in Core because it is a decision.** The first version of
> that rule lived in the shell, where no test could see it, and it deleted
> undelivered messages on every launch: something the user dictated, that the
> interface accepted, gone without a word. A conversation with a pending message
> now keeps its marker, or nobody would ever collect it.

### `DictationLocale.swift`
Which language to listen in, and what the microphone button is able to do.

> **`choose` returns `nil` rather than falling back to English.** The recognizer
> transcribes everything as the locale it is given, so the wrong one produces
> fluent nonsense that nothing downstream can detect. Silence is the honest
> failure; there is a test named for it.

## `Markdown/`

### `MarkdownBlock.swift` · `MarkdownParser.swift` · 240
Splitting an answer into blocks. Deliberately not a general markdown
implementation: what Claude writes, and anything unrecognized becomes a paragraph
— its own source text, readable — rather than disappearing.

> **Fences are parsed first and greedily.** A `# comment` inside a shell snippet
> is not a heading, and a table divider is what tells a table from a shell
> pipeline written in prose. Both have tests.

> **`plainSummary` strips only `*` and backticks.** The wider sweep that looks
> obvious eats `a > b`, `snake_case` and `#1`.

## `Parsing/`

### `HookPayloadDecoder.swift` · 204
The only point where external data enters the domain. Strict validation: no
required field is ever inferred or filled in with a default.

`ignoredEvent` is not a fault — the hook script forwards everything and the
filter lives here.

## `Reducer/`

### `StateReducer.swift` · 673
`(state, action) → new state`. The densest file in the project.

The order of the checks in `apply`, and it is **not arbitrary**:
1. does it deserve a traffic light? is there a workspace?
2. **is it a subagent lifecycle event?** ← before the rule that discards
3. does it come from a subagent? → discard
4. is it `SessionEnd`? → remove
5. map event → state, or discover a new session
6. protection from late signals (`shouldKeep`)

> **Step 2 before step 3** is the subagent correction. Swapping them undoes it,
> silently.

## `Server/`

### `HTTPRequestParser.swift` · 132
A minimal HTTP/1.1 parser. Deliberately not general-purpose: it accepts only what
the hook script sends.

### `SessionsPayload.swift` · 235
The JSON contract. A type **separate** from `SessionState`, so an internal
refactor doesn't break its consumers. ISO 8601 dates, sorted keys.

### `LoopbackGuard.swift`
What the server refuses before any route (D68): a request carrying `Origin`, which
only a browser sends, and a `Host` that is not `127.0.0.1`, `localhost` or `[::1]`,
which is a rebound name. A page on this Mac could otherwise post a signal — `/signal`
still takes one without a token, for old hooks — or read the answers.

> **Touching here** can turn every real client away: the hooks, the mod, the tunnel
> from a node and `curl` send loopback hosts and no `Origin`, and a new client that
> sends either will be refused, logged only under `LAMPBOARD_DEBUG`.

### `AccessToken.swift`
Generation and **constant-time** comparison. The comment at the top says what the
token protects and what it doesn't: read it before quoting it elsewhere.

## `Setup/`

### `HookConfigMerger.swift` · 440
Adds and removes the hooks in `settings.json` **working on dictionaries**, not on
files: the I/O lives in the shell, so this logic — which modifies an important
user file — stays verifiable. Two questions the launch repair asks are answered
here and nowhere else: `lacksToken` (does one of our native hooks miss the current
token?) and `nativePorts` (which listener are they addressed to?). Both read
through the same structural recogniser the uninstaller uses, so neither can claim
a neighbour's hook.

### `HookRepair.swift` · 98
The one rule behind bringing an installation up to the current token, shared by
the local installer at launch and the node's installer at every check: which
events carry ours — under the current name **and** the previous one — which
listener they are addressed to, whether both halves carry the token, and what
shape to keep. Born from watching a test instance on another port rewrite a
shared installation (D48); its own domain case then caught the repair about to
switch message delivery on for everybody, because `isInstalled` claims native
hooks for any path asked about.

### `NativeHookSupport.swift` · 45
Whether a Claude Code takes `type: "http"` hooks: the release that added them
(2.1.63, per the changelog), the boundary, the parsing of `claude --version`, and
the direction an unreadable version falls — open, in those words (D49).

### `HookScriptBuilder.swift` · 172
Generates `hook.sh`, and is the one place the listener's address is spelled:
`target(port:)` is what the script posts to and what `HookConfigMerger.endpoint`
writes into a native hook, so the two halves cannot name different listeners.
`posts(_:to:)` reads it back off an installed script. See
[02 Claude Code](02-claude-code.md#the-hook-script).

### `RewakeScriptBuilder.swift` · 126
Generates `rewake.sh`, the second `Stop` hook that carries a message into a
running session. Its stdout **is** the message; exit code **2** is the send.

> **A separate file from `hook.sh`, not an option inside it.** The two have
> opposite obligations: the traffic light hook must return in milliseconds or it
> delays every turn, and this one waits for minutes.

> **Three defenses against a process that outlives everything**: it arms only when
> a conversation is selected, it gives up after thirty minutes, and a pid file
> stands a second listener down. Every path out is `exit 0` except the deliberate
> `exit 2` — a failing hook can interrupt a Claude Code turn.

### `RemoteInstallScripts.swift` · 232
The Python that runs on another machine to inspect it, write the hook script and the merged settings, or ask whether the tunnel answers. In Core and under test for the same reason the probe is: a promise to another machine has to be readable in one place. The data travels inside the source as base64 — no shell quoting rule is involved. The inspection hands back the text of our script there under both names, so the token is judged here by `HookRepair` and the node is never told one; a domain case runs the real scripts against a home laid out like the node, inspect to apply and back.

## `System/`

### `Command.swift` · 186
Running an outside tool without being taken hostage by it. The obvious three
lines have two failure modes and both are silence: `waitUntilExit` waits
forever, so a hung `spctl` took the updater with it and nothing was ever going
to appear on screen; and a pipe holds about 64 KB, so a tool that says more
blocks writing while the caller blocks waiting, and neither side is broken and
neither moves. Reading on another thread makes the deadline the only thing that
can end the wait. In Core rather than beside its caller so both failures can be
demonstrated instead of argued about — `CommandSuite` runs a tool that sleeps
and one that writes two hundred kilobytes.

`input` goes to standard input on a thread of its own, for the same reason in
the other direction, and with `F_SETNOSIGPIPE` on the pipe: a tool that exits
without reading would otherwise end this app with `SIGPIPE`. It is how LampMaster
hands `claude` a frame that must not be an argument (D59). `launched` hands the
caller the process id, so an app quitting mid-run can stop what it started.

## `Workspace/`

### `TunnelRefusal.swift` · 88
Which machine is actually at fault when a reverse tunnel cannot bind. ssh says
*"remote port forwarding failed for listen port 31000"*, which reads as an
accusation against the other machine; measured once, the port was held by this
app's own tunnel from a previous run, orphaned by the `pkill` the build script
itself recommends. Reads the local process table, matches on the forward
specification rather than on the word `ssh`, and names the pid with the command
that removes it. Nothing is killed automatically: another running panel is a
legitimate owner of that port.

### `RemoteHostList.swift` · 45
The rules for a remote host's name: `isUsable` is an allow-list because the name
becomes an argument to `ssh` — one starting with a dash would be read as
*options* — and `parse` reads the old `~/.lampboard/remotes` file, imported
once into the preferences on upgrade (D24). The hosts themselves live in the
Settings window.

### `RemoteProbeScript.swift` · 153
The script that runs **on** the other machine, in one piece and under test. It is a
promise made to a machine we do not control, and the shape it prints is what
`RemoteSessionsDecoder` parses — if the two drift, activity silently falls back to
the session file, which is the frozen one.

> **Why the work happens there.** Two of the three facts a row needs are only true
> where the processes are: whether the pid is alive, and when the transcript last
> changed. Deciding here from shipped files would answer both about the wrong
> machine.

### `RemoteWorkspaceResolver.swift` · 58
Which folder a row on another machine belongs to: the node's editor window that
contains the hook's `cwd`, resolved by the same function as a local row; failing
that the session file's folder, written once; failing that the `cwd` itself. Born
from a row called "experiment" whose window was called `simlab` (D51).

### `RemoteSessionsDecoder.swift` · 128
The other machine's answer, entering the domain. Validates like
`HookPayloadDecoder`, with one difference: **a single bad record is skipped, not
thrown**. The output comes from a Claude Code version we do not control, and one
unparsable entry is not a reason to blank a whole host.

### `WorkspaceResolver.swift`
`cwd` + locks → which window. `window(hosting:)` also returns **which editor**,
because Cursor's bundle identifier differs from VS Code's.

### `WindowTitleMatcher.swift` · 137
Scores 100/50/10, plus 1000 for a Remote-SSH window whose label is a name the host is known by. It lives in Swift rather than inside AppleScript precisely so
it can be verified without opening windows.

### `IDEKind.swift`
The table of recognized editors: declared name, bundle, process name.
**Deliberately short** — see [N3](04-decisions.md#n3--jetbrains-and-the-other-ides).

### `IDEWindow.swift` · `LiveSession.swift`
The two parsers for the on-disk files.

### `SessionDeepLink.swift` · `AppleScriptString.swift`
The extension's URI, the policy that sends it only to sessions the extension
hosts (`DeepLinkPolicy`: entrypoint `claude-vscode`, or unknown), and the
escaping of titles inside a script.

---

# LampBoardApp

It does I/O and draws. **It does not decide.**

## Entry point

### `main.swift` · `AppDelegate.swift` · 378
`MainActor.assumeIsolated` in `main.swift` is needed because top-level code isn't
isolated to the main actor, but that is where we are by definition.

The launch settles the token **once**, then repairs the hooks with it, then starts
the server with it — in that order. Each step reading the store for itself is how
the launch that regenerates a burned token would have written the old one into
every hook (D48).

`AppDelegate` wires everything up. `--headless` skips `startInterface()`, and
that is why the E2E suite didn't see the notification crash: it never went
through that branch.

`onMain(timeout:)` is the only writing crossing towards the main actor.

### `CodexProcessScanner.swift`
Finds the Codex sessions running here without being told. Codex inside the
ChatGPT app registers our hooks, marks them trusted, runs a full session, and
sends no signal at all: measured, with eight events configured and not one line
in the log. Anything built on hooks alone is blind to it.

So the evidence runs the other way: a live `codex` process holds its rollout open,
the file says which session and folder, the binary says which surface. Returns
`.unavailable` rather than an empty list when the probe could not answer, because
a probe that timed out is not a session that ended.

### `CommandLineStatus.swift` · 105
`lampboard status`: what this machine can see, and what it cannot. Split out of
`CommandLineInterface` at the 800-line ceiling, along a seam that was already
there — everything else in that file **does** something, and this one only looks
and reports. It is the longest single command because reporting honestly means
naming the difference between "none" and "could not be read" every time it comes
up.

### `CommandLineUsage.swift` · 59
`lampboard usage`: what the allowance strip would draw, asked once and printed for
this Mac and every node, with the reason when there is nothing. The quickest way
to watch the credential being read without a dialog (D52).

### `CommandLineInstall.swift` · 176
The two commands that write into somebody else's configuration file:
`install-hooks` and `uninstall-hooks`. Split out when `CommandLineInterface`
reached the 800-line ceiling, along the seam that was already there — everything
else in that file reads state or raises a window.

Installing reaches every agent on this machine through `HookSetup`, and prints
the sentence about trust where Codex is present: Codex will not run a hook it has
not been told to trust, and says nothing when it declines.

Three exit codes rather than two. `0` when everything that could be installed
was, `1` when nothing worked, and **`2` when one agent was set up and another
failed** — which used to be `0`, telling a script that had half-installed the
hooks that it was finished.

### `CommandLineMCP.swift` · 75
`lampboard mcp`, the `lampmaster` MCP server Claude Code starts for a session. It
holds nothing: each line is answered by `LampMasterMCP`, each tool call is
forwarded to the running panel with the token, as the hooks do, carrying
`CLAUDE_CODE_SESSION_ID` and the working directory Claude Code gives it. Every
failure comes back as a tool error the calling model can read, never a dead server.
`mcp install | uninstall | status` manage its entry in Claude Code (D63).

### `TrialLauncher.swift` · 76
`lampboard tour`: starts the tutorial's trial panel beside the real one, as a second
process of this binary on a temporary home and a free port, so the two never share
anything (D64). `--json` prints the script for the site and the screenshots. The
same start serves the menus' *Take the tour…* and the offer made right after the
hooks are installed; neither appears inside a trial, where a tour would stack
panels.

### `CommandLineInterface.swift` · 795
Thirteen commands: install-hooks, uninstall-hooks, status, selftest, focus, next, open, new, chat, sessions, remote, terminal, rename. `new` and `chat` share `runSlotCommand`; `open` stays separate
because a bare `open` lists the assignments, which is a different command wearing
the same name. `focus --dry-run` diagnoses without moving any windows.

### `SelfTest.swift` · 287
`lampboard selftest`: the whole chain, link by link — the port opens, a signal
crosses HTTP, decodes, resolves to a workspace, the Accessibility permission is
there, the hooks are registered — and it names the link that broke.

## `Runtime/`

| File | Lines | What |
|---|---|---|
| `StateStore.swift` | 793 | `@MainActor`, `@Published`, periodic realignment; the Codex probe is started here and awaited nowhere |
| `StateStoreAdoption.swift` | 221 | the rows nobody announced: the Claude Code sessions already running, Codex from an open rollout, Claude Desktop from its index and transcript. All obey the same two rules — what a probe could not see is never read as gone, and a state nobody reported is never dressed up as one that was |
| `ClaudeDesktopScanner.swift` | 242 | finds the Claude Desktop conversations running here. Presence is the index and the transcript, never the agent process: that process lives one turn, so a row built on it vanished at the moment there was an answer to read |
| `SessionTerminator.swift` | 91 | finds the process behind a row and ends it when asked. Only where the session names its process, only if that process is alive and started when the record says — checked again after the confirmation, because a pid can be reused in those seconds — and `SIGTERM`, never `SIGKILL`. `ps` is asked with `TZ=UTC`: the file records the start in UTC and `ps` answers local, so comparing the two strings never matched and the menu entry would have been invisible for ever |
| `CodexApprovalReader.swift` | 91 | reads the rollout an event names, to learn who will answer its permission request. The tail first, then the whole file when the tail does not say: measured on an audit of a whole codebase, rollouts of 1.8 MB and 3.5 MB whose only `turn_context` sat outside any tail, and reading only the tail put them straight back to blinking amber. In the shell because it touches a file: the reducer receives the answer, never the path. The tail and not the file, so the cost does not grow with the length of a conversation |
| `CodexProbe.swift` | 26 | an `actor` around the Codex scanner. It spawns `lsof`, and instrumented here it was 80 ms of a 150 ms sweep on the thread that draws. Serialising also means a slow probe cannot have a second started on top of it |
| `SweepCost.swift` | 83 | where one realignment pass spent its time, phase by phase, and `SweepLog` keeping the worst and the average across passes. Added because an audit said the sweep was too slow and neither side could settle it by reading |
| `ModReceiver.swift` | 84 | takes in what the companion mod reports: the ledger beside the column, a measure's context to the reducer as `reported` and its cost as `costed`, the default account's windows to the allowance strip. Never makes a row: a measure for a session the hooks have not announced is dropped. Writes `~/.lampboard/port` (`0600`, staged under a fresh name opened exclusively and without following links, then renamed) for the mod, which is one file for every Mac and reads the port where the hooks have it in their script |
| `Preferences.swift` | 502 | `UserDefaults`, separate domain under `LAMPBOARD_HOME`; imports the previous name's domain once, before anything reads a preference |
| `LampMasterService.swift` | 237 | LampMaster's round from the panel's rows to the suggestions on screen: the five-minute tick, the frame, the skip, the run, the validator, the files, the state the server hands out. Every decision is in Core; this reads, runs and keeps. One round at a time, and one daily ceiling shared by the rounds and the questions |
| `LampMasterQuestions.swift` | 122 | what a session asks through the `lampmaster` MCP server: the lookups at once from the cards, a question through the round's isolated `claude` with Sonnet. A question is **booked** in `asks.jsonl` before it runs, so questions arriving during its minute and a half count it; two at most at once. The session id a call carries is the caller's own word, a label for the per-session limit; the hourly total is the bound |
| `LampMasterRunner.swift` | 94 | finds and runs `claude` for a round or a question — only in the fake home under `LAMPBOARD_HOME`, so a test that forgot its fake fails instead of spending the real one; the pids in flight, held only while they run, so quitting stops them; the box the server reads the state from |
| `LampMasterCards.swift` | 128 | a card for every conversation LampMaster may look at: the panel's rows, and the transcripts closed in the last week. Followed by byte offset like the chat window — the tail first, then only what was appended, again from the start if the file shrank. An `actor`, so the reads stay off the thread that draws |
| `LampMasterFiles.swift` | 159 | `~/.lampboard/lampmaster/`: rounds, suggestions with their outcomes, the notebook, the last 200 frames, the last day's questions. The folder is `0700` because the frames quote conversations |
| `TrialStage.swift` | 156 | the trial: an editor lock per invented project, a stand-in process per session, a transcript with a title, LampMaster's demo card, then every beat posted to the app's own `/signal`. **Refused without `LAMPBOARD_HOME`**, where it would put invented sessions into the real `~/.claude`; on quit the stand-ins end and the home goes, but only a home `lampboard tour` named |
| `SupportDirectoryMigration.swift` | 60 | carries `remotes` and `inbox` over from the support directory of the previous name — both unrecoverable elsewhere, both failing silently |
| `SnapshotBox.swift` | 27 | lock-protected copy for the server |
| `TokenStore.swift` | 78 | `0600` token, **regenerated** if the permissions are wide |
| `LocalClient.swift` | 162 | talks to the live instance for `sessions` and `next`, and for the `lampmaster` MCP server, which waits as long as a question may take |
| `SessionNotifier.swift` | 259 | `awaiting` notifications after a delay, `failed` and (asked for) `ready` on the transition only, so what was already so at launch is not news; anti-duplicate memory, gate; the text from `NotificationText` |
| `TranscriptReader.swift` | 112 | follows one transcript by byte offset; opens on its tail, title from its head; resets when the file shrinks |
| `TranscriptPreviewReader.swift` | 98 | the last thing said, from the file's tail, cached on its size |
| `ContextReader.swift` | 98 | how full the context is, from the same tail, cached the same way — an `actor`, so the seek never lands on the thread that draws |
| `SessionTitleReader.swift` | 16 | the first 512 KB of a transcript, handed to the scanner; what names a terminal row |
| `IDEWindowReader.swift` | 54 | reads the locks and **confirms them against the editor's process**, not the file's age |
| `MailboxWriter.swift` | 179 | the panel's end of the mailbox; carries out the reaper's verdict |
| `RemoteSessionReader.swift` | 108 | asks another machine over ssh; `nil` means no answer, `[]` means nothing running |
| `RemoteCommand.swift` | 147 | runs a Python script on another machine over ssh: one shape, one set of timeouts, errors that name the fix |
| `RemoteTunnel.swift` | 283 | the reverse ssh tunnel per host, kept alive with backoff; `ExitOnForwardFailure` makes a taken port a reason, and `TunnelRefusal` says whether that reason is on this Mac |
| `RemoteFleet.swift` | 209 | every configured machine: its tunnel, its hooks, what it last said; follows the preference list live; every check repairs stale hooks over there, and a tunnel coming back up after a failed check asks again |
| `DictationService.swift` | 339 | `SpeechTranscriber` on the device, `AVAudioEngine` capture, macOS 26 only |
| `PresenceFile.swift` | 91 | presence file, deleted on shutdown |
| `LaunchAtLogin.swift` | 106 | blocked when the signature is ad-hoc |
| `LiveSessionReader.swift` | 135 | reads the live sessions; takes activity from the **transcript**, not the session file. A pid that is alive but started at another moment than the file records was handed to another process, and its session is dead (D68) |
| `ConversationIndex.swift` | 120 | whether a session has ever held a conversation, which is what a row stands for. The derived path first, then a search by session id across the project folders, because a session in a git worktree files its transcript where the derivation does not look (D44) |
| `FinderReveal.swift` | 28 | opens a Finder window **inside** the folder, not on it (D33) |
| `AccountLimitsReader.swift` | 340 | asks Anthropic how much of the allowance is gone, signed with the token Claude Code keeps in the keychain, and for every account the Claude application runs Claude Code as on this Mac (D53). **Borrows it, never renews it**: spending the refresh token could sign the person out of Claude Code, so an aged-out token means the strip goes quiet. Read through `/usr/bin/security`, the tool Claude Code writes it with, so macOS asks nothing (D52) |
| `AllowanceMonitor.swift` | 156 | the timer behind that strip. On a 429 it keeps the last readings and waits longer before asking again (D54). No timer and no request while the switch is off: a feature that reaches the network is either off or on. The strip is the service's answers merged with the mod's windows (D67), which need no switch: they never leave the Mac |
| `UpdateChecker.swift` | 107 | asks GitHub for the latest release and compares it with this build: the stable address's redirect first, with redirects not followed, and the API only when no redirect came back (D50) |
| `UpdateInstaller.swift` | 288 | downloads, verifies the signature matches this one, swaps the bundle and relaunches — with a deadline on every step |
| `Diagnostics.swift` | | file log, active only with `LAMPBOARD_DEBUG` |

> **`DictationService`** — the ordering in `start()` is load-bearing and
> commented at length. `SpeechAnalyzer.start(inputSequence:)` is the pump, not the
> ignition: it does not return until the audio ends. Awaiting it left the state
> down, the button idle, `stop()` refusing to act and the **microphone open with
> no way back short of quitting**. Every exit path releases the input device
> first and unconditionally, for that reason.


> **`SessionNotifier`**: the `announced` memory has to be updated **even with the
> feature off**, or flipping the switch with ten blocked sessions fires ten
> alerts at once.

## `Server/`

### `SignalServer.swift` · 478
Ten routes, behind `LoopbackGuard`. A **concurrent** queue: with a serial one, a `/next` waiting on the
main queue would also block reading the hooks' signals.

`/open`, `/new` and `/chat` share `handleSlotRoute`: they differ only in the action, so
method, authentication, validation and the three answers are written once. All three
carry the slot in the **body**, not the path — a router that has to interpret path
segments is a router with a parsing bug waiting in it, and this parser is
deliberately not a general-purpose one.

`/lampmaster` is behind the token both ways: `GET` returns LampMaster's state,
which quotes conversations, and `POST` asks for a round, which spends the user's
allowance. The `POST` answers 202 at once and the round runs on its own; a
connection held for the two minutes a round may take would be one more way to tie
the server up.

`/mod` takes what the companion mod reports (D65). Its token is required, unlike
`/signal`'s: no copy of the mod predates it, so there is no installed base to keep
working.

`/lampmaster/tool` is a session's tool call, forwarded by `lampboard mcp`. Unlike a
round, the caller waits for the answer, which is the tool's result; the wait is
bounded, and two questions at most run at once, so a burst of calls cannot hold
the threads the hooks post on.

`requiredLocalEndpoint` is the line that binds the socket to loopback.
`acceptLocalOnly` does **not** do that.

## `Focus/`

### `PermissionWatcher.swift`
Holds the click a missing permission interrupted, and finishes it when the
permission arrives. Granting a TCC authorization notifies nobody — the only way
to notice is to keep asking — and the point is not the noticing: it is that
making the user click again is how a permission they just granted feels like it
changed nothing.

### `ProcessTree.swift` · `SeatResolver.swift` · `TerminalFocuser.swift`
The click on a terminal row. `ProcessTree` reads parent, tty, start time and
arguments from the kernel (`sysctl`, `proc_pidpath`; no `ps`). `SeatResolver`
goes from a session id to its seat at click time — file, pid, `procStart`
guard, chain, classifier — and caches nothing. `TerminalFocuser` raises the
seat: by tty through the terminal's dictionary, or activates the application
and says where it stopped. Automation is per target application, and a refusal
names the one that refused.

### `VSCodeFocuser.swift` · 418
The most delicate file. Two strategies, three explicit outcomes.

> **To be read in full before touching it.** Every long comment in here
> corresponds to a defect that cost hours: null `stringValue` on lists,
> `activate()` lying, `open` with a path that creates new windows, the index that
> expires.

### `RemoteHostAddresses.swift` · 73
The names a Remote-SSH window may carry for a host — the configured one, what `ssh -G` resolves it to, and their addresses — because VS Code labels the window with whatever the user typed to connect.

## `Setup/`

### `HookSetup.swift` · 179
Both agents' hooks, asked and answered together, because the answer used to
depend on how you asked. The command line installed Claude Code and then Codex;
the first-run offer, the context menu and the state that menu showed each
consulted a single installer and it was always Claude's. Somebody who accepted
the offer at first launch was left with Codex unregistered, and told the hooks
were installed.

Per agent, and `notPresent` is one of the answers: an agent that is not on this
machine has failed at nothing, which is what keeps the exit code and the first-run
offer honest.

### `HookInstaller.swift` · 392
Atomic writes and a dated backup. `availableBackupURL` appends a counter: two
installations in the same second used to fail. The backup is named after the file
it copies, which it was not: both agents share this code and only one of them
writes a `settings.json`, so Codex's backups were called after a file that was
never there.

`repairToken` is the launch repair (D48): both halves of an installation are
rewritten when either lacks the current token — **only** when the hooks are
addressed to this instance's port, and keeping the events and the message listener
they had. The first version reinstalled at its own port with fresh defaults, and a
test instance on another port turned the whole shared installation towards a
process that then exited.

### `ModSetup.swift`
Writes the carried mod into `~/.lampboard/mod-marketplace` (owner-only) and runs
the `claude plugin` steps, one change at a time under an `flock` that the command
line shares, always from a clean slate and taking out again whatever a refused
step left half in; uninstalling is judged by what Claude Code still lists, and the
folder goes only once no marketplace points at it; `lampboard mod install|uninstall|status`; the launch
refresh of a mod of another version; removal by `uninstall-hooks`. Under
`LAMPBOARD_HOME` it gives `claude` that home as `HOME`, as `LampMasterSetup` now
does too: `claude` writes its settings from `HOME`, and a child inheriting the real
one would install into the real Claude Code from inside a test.

### `LampMasterSetup.swift` · 53
Puts the `lampmaster` MCP server into Claude Code with `claude mcp add --scope user`
and takes it out with `remove` — Claude Code's own writer, never a second one on
`~/.claude.json`. Registering again replaces the entry, because the app may have
moved. `claude` gets an empty standard input: otherwise it inherits the caller's,
and could wait on a terminal nobody types in. `uninstall-hooks` removes it too.

### `ClaudeCodeInstallation.swift` · 66
Which Claude Code is installed here, read rather than assumed: the native
installer's `~/.local/bin/claude` link is named after its version, and
`claude --version` is run with a deadline from the places a binary lives when the
link is not there. Feeds `NativeHookSupport`; `install-hooks` and `status` print
what it found.

### `RemoteHookInstaller.swift` · 265
The local installer's merge applied to another machine: inspect over ssh, merge here with `HookConfigMerger`, write there through `RemoteInstallScripts` — dated backup, atomic replace, no shell in the data path. Also asks the node whether the tunnel answers. `repairToken` brings a node's hooks up to the current token by the same rule the launch applies here (D48), previous-name registrations included, and only when they post to that user's tunnel port; the fleet calls it on every check.

## `UI/`

| File | Lines | What |
|---|---|---|
| `PanelController.swift` | 796 | holds everything together; row and panel actions |
| `PanelActivation.swift` | 155 | where a click goes, which is a different question for every surface |
| `PanelAllowance.swift` | 59 | the switch that turns the allowance strip on, and the sentence shown before the first request leaves the Mac |
| `AllowanceCard.swift` | 129 | one account's allowance as a card: every limit, its bar, when it comes back. `TooltipCard`'s grammar but not its type — a `RowSummary` is shaped for a session, and filling in a state and a last message to reuse the view would put a status word on a thing that has no status |
| `AllowanceStrip.swift` | 179 | the account's allowance at the foot of the column: bars, not rings, because the ring already means the context window of one conversation |
| `TrafficLightRow.swift` | 430 | one row: dot, context ring, name, badge, timestamp, folder, handle, menu |
| `DragHandle.swift` | 60 | the handle's grab area, an `NSView` so the drag moves the row and not the panel |
| `TrafficLightColumn.swift` | 505 | the column, the drag in progress, the hidden summary, the filter note |
| `SessionSubRow.swift` | 198 | one conversation inside an opened block, and the grip that names its agent |
| `PanelNaming.swift` | 171 | opening a project, and the three levels of name |
| `PanelRootView.swift` | 472 | the general menu, and the strip under the rows: width on the left, legend and menu on the right |
| `TrafficLightDot.swift` | 73 | the dot, the silenceable blink, and the ring for an open ear |
| `ContextRing.swift` | 77 | the second ring: the arc is the context spent, the letter is the model (D30) |
| `LegendView.swift` | 180 | what the six colours and the two rings mean, counted live (D31) |
| `LegendWindowController.swift` | 57 | owns the legend window |
| `Tooltip.swift` | 243 | the panel's own tooltips: AppKit's need a key window, and this one never is (D32) |
| `TooltipCard.swift` | 149 | draws a `RowSummary`: header, the label/value grid, the context bar, the keys |
| `Blinking.swift` | 39 | the blink as a view that exists only while it blinks |
| `UpdateFlow.swift` | 57 | the update from the menu entry to the app coming back: what was found, what failed, nothing silent |
| `PermissionRequest.swift` | 73 | explains a permission — use, cost of refusing, way back — then opens the pane that grants it |
| `StatusPalette.swift` | 389 | colors and measurements, and the dark appearance the panel is held in whatever the Mac is set to (D43) |
| `FloatingPanel.swift` | 122 | non-activating `NSPanel`; makes itself key before a click, drops the second click of a double-click; adopts one of the two homes |
| `PanelHomes.swift` | 354 | the two homes and the lamp that stands for the panel up there, the rescue when the menu bar had no room for it, and the list of every switch the menus offer |
| `MenuBarLamp.swift` | 239 | one `NSStatusItem`: the column's most urgent state as a drawn lamp, blinking only while something needs a person, and able to say whether it was drawn at all; with the counter switched on, `wanting · working` beside it |
| `MenuAction.swift` | 21 | an `NSMenuItem` target that runs a closure, because target/action is Objective-C dispatch and a Swift class silently answers nothing |
| `ChatWindowController.swift` | 123 | owns the one extended window; opened on request |
| `ChatShell.swift` | 230 | every conversation, the selection, and what each costs |
| `ChatShellView.swift` | 197 | the two columns, and one row of the list |
| `ChatSession.swift` | 245 | one conversation: transcript on disk + status from the hooks + the composer's state |
| `ChatView.swift` | 306 | bubbles, activity lines, the composer |
| `MarkdownView.swift` | 157 | draws the blocks; inline markup goes to `AttributedString` |
| `DictationButton.swift` | 97 | the microphone, and the box that hides the macOS-26 seam |
| `AlertSettings.swift` | 41 | the menu bar counter and the notification for a finished turn, both off until asked for (5.6) |
| `SettingsView.swift` | 168 | the Settings form: LampMaster first, the companion mod, the menu bar and notifications, then remote machines, their state, the buttons; the "Show terminal sessions" switch |
| `SettingsWindowController.swift` | 59 | owns the Settings window; activates the app so it comes up in front |
| `LampMasterSettings.swift` | 105 | LampMaster's section: the switch with the sentence that says what it sends and spends, on screen before it is pressed (D60); the second switch, which lets every session ask it (D63); how often, which model, the kinds switched off |
| `ModSettings.swift` | 92 | the companion mod's switch, what it does said before it is pressed, and on request Claude Code's own reading of the version this app carries (`claude plugin validate`), with the installed version when they differ and a refresh that failed at launch. Re-read every three seconds: Getting started, the command line or the launch refresh can change it while the window is open |
| `GettingStartedWindow.swift` | 169 | *Getting started*, opened after the hooks are installed and from both menus (`--getting-started` opens it at launch, for screenshots and for a Mac nobody is clicking). A window rather than a list in the panel, for the reason of D61; the ticks are read again every two seconds, because the Accessibility permission arrives from System Settings and not from a click here |
| `TourBand.swift` | 113 | the tutorial's band at the top of a trial panel, always there so a screenshot taken there never passes for real sessions: where the tour is, the step's sentence, Skip, Resume, Quit trial. `TourController` keeps the progress by step id in a domain of its own, because every trial starts on a fresh home; a row opened, a quota line pointed at, a card answered move it on. In a trial, opening a row only marks it seen: there is no editor behind an invented folder, and the warning that said so was modal and held off the trial's own quit |
| `LampMasterStrip.swift` | 62 | LampMaster's line under the column, only while it is on: one line of fixed height, counted by `PanelMetrics.height`, never blinking — advice is not a session waiting |
| `LampMasterWindow.swift` | 180 | the cards, in a window of their own (D61): the kind, the sentence, the evidence behind a disclosure, the sessions as buttons, the action, *Ignore*, *Wrong*, *Don't suggest this kind*. Opening it asks for a round if the last is older than fifteen minutes |
| `PanelLampMaster.swift` | 101 | what a card does to the panel, by reusing what a row does: the same raise, the same confirmation before ending a process, the same dismissal. A card can never do something a row could not |
| `Alerts.swift` | | dialogs |

> **`StatusPalette.timeColor`** is `Color.primary.opacity(0.62)` and not
> `.secondary`: over an `NSVisualEffectView` the weak semantic hues get
> attenuated a second time and disappear. The hierarchy comes from the font
> **weight**.

---

# The tests

## `LampBoardTests/` — 941 cases

One suite per domain area, and one file per group of them: `MailboxSuite.swift`
held ten suites and 610 lines, three of which were about dictation and the rewake
script, before it was split. The most important ones:

| Suite | Covers |
|---|---|
| `StateReducerSuite` · `ReducerFixesSuite` | the state machine, including the four semantic corrections |
| `SubagentSuite` | counter and derived state |
| `ColumnLayoutSuite` | grouping, the user's order, filtering, summary |
| `RowNamesSuite` | a name shown over folder and title, stored by folder, blank restores; the label in the payload |
| `RowOrderSuite` · `ColumnSlotSuite` | absorbing, placing and moving; that a slot is a position and survives any change of state |
| `MailboxSuite` · `MailboxPermissionSuite` | hostile session ids, message limits, owner-only permissions |
| `MailboxDirectorySafetySuite` | a symlink where the mailbox should be is refused |
| `RewakeScriptSuite` · `RewakeRegistrationSuite` | the script's promises, and the second `Stop` hook |
| `MarkdownParserSuite` | the constructs, and one whole answer containing all of them |
| `IDELockLivenessSuite` | a running editor is believed however old its lock is |
| `LivePruningSuite` | a session you can see running is never pruned for being quiet |
| `AwaitingReleaseSuite` | a question you have answered stops flashing |
| `WaitingSuite` | a session that has stopped but is not done is blue, and says what it waits on |
| `RemoteSessionsSuite` | another machine's sessions, and what deserves a row |
| `SessionCardSuite` · `LampMasterSignalsSuite` | a transcript read into a card, a line cut between two reads, what counts as saved; every signal on both sides of its threshold |
| `LampMasterFrameSuite` · `LampMasterAdviceSuite` | who enters the frame and in what order, detail given up before sessions; evidence that is not in the frame never reaches the panel |
| `TourSuite` | the script holding nothing real and catching what would be, a beat as the hook's payload, the steps 0.5 shows, a step moving only on its own gesture, skip and resume |
| `LampMasterMCPSuite` | the protocol line by line, `server/discover` refused without ending the conversation, each lookup on invented sessions, no lookup carrying another session's words, sources quoted in full or dropped, the limits |
| `LampMasterRoundSuite` | the flags that keep the round invisible and cheap, the frame kept off the command line, the envelope read even when it failed, every skip and its order, suggestions that expire or settle |
| `BackgroundTaskSuite` | pending work is work; only terminal statuses are not |
| `MailboxReapSuite` | an undelivered message keeps its conversation armed |
| `DictationLocaleSuite` | silence beats confident nonsense |
| `DeliveredMessageSuite` | recognizing our own messages on the way back |
| `TranscriptDecoderSuite` | who spoke — including the 579-against-209 case |
| `TranscriptTailSuite` | the half-written line, split across up to three chunks |
| `TranscriptLocatorSuite` | the naming rule, accents included |
| `SeatSuite` · `MultiplexerSuite` · `TerminalListingSuite` | every measured chain classified; tty names matched not escaped; the scripts; `procStart` as UTC and the zone trap; the `lsof` pairing and tmux listings; WezTerm, kitty and Ghostty listings |
| `ConversationSuite` | unread counts answers, and trimming says how much it dropped |
| `WindowTitleMatcherSuite` | the scores |
| `AppleScriptEscapeSuite` | title escaping, including a hostile title |
| `AccessTokenSuite` | constant-time comparison, prefixes, empty expected value |
| `ContextSuite` | the token sum; a refusal that must not read as 0%; the floor and the dash; the iterations fallback; a dated model id; an unknown model |
| `ModReportSuite` · `ModLedgerSuite` | the mod's reports read and bounded, a hostile id or word refused; the session's own count never replaced by the transcript's; the ledger's cost, windows and bound |
| `ModFilesSuite` | the carried mod equal to the repository's byte for byte; loopback only, nothing written or run; Claude Code's own install and removal steps; enabled, version and a declared marketplace read back |
| `NotificationTextSuite` | what a notification says for a wait, a failure and a finished turn, never the previous answer; the menu bar counter with its zeros |
| `LoopbackGuardSuite` | loopback hosts and no `Origin` pass; any `Origin`, a rebound or malformed `Host` refused |
| `ModAllowanceSuite` | the mod's windows over an older answer, kept from a newer one, alone when the service gave nothing, ignored when none can be drawn; only the default account's windows reach the strip |
| `ModTrustSuite` | the real `validate` output as four sentences; an unknown call shown as spelled; a valid but empty reading refused |
| `RowSummarySuite` | what a row says about itself: the fields and their order, a void reading that must not print its tokens, a help line that promises only what the row can do |
| `CommandSuite` | a tool that hangs is killed at the deadline; 200 KB of output does not deadlock; a refusal keeps its exit code and its reason |

## `TestKit/` — the assertions

Four files: `TestSuite` (a name and its cases), `TestRunner` (runs them, filters
by name, prints the ✓/✗ lines and the final count), `Assertions` (`expect`,
`expectEqual`, `expectNil`, `expectNotNil`, `expectThrows`, `expectNoThrow`,
`fail`) and `Instrument`. It exists because the Command Line Tools without Xcode
ship neither XCTest nor a complete swift-testing (D11).

### `Instrument.swift` · 133
Calibrates the assertions before anything is measured with them, and it is the
reason the number in the heading above means something. Adding one early
`return` to `expect` made every case in this target report success while verifying nothing —
a full green, no warning, no clue. So every assertion is now made to fail on
purpose and must record it, made to pass and must stay silent, and a failing run
must still reach a non-zero exit code; nineteen proofs, none of them written in
the vocabulary they are testing. A blunt instrument ends the process with 70
rather than the 1 of an ordinary failure, because the two mean different things.
`Scripts/bite.sh` attacks it from the outside as well.

## `LampBoardE2E/` — 130 cases

| Suite | Covers |
|---|---|
| `TransportSuite` | **the socket via `lsof`**, token, methods, refusals; a POST with `Origin` and a rebound `Host` refused, through `curl` since URLSession will not send a Host of the caller's choosing |
| `PidReuseE2ESuite` | a live `sleep` named by a session file with the wrong start makes no row, with its own start makes one |
| `LifecycleSuite` | the states walked over HTTP |
| `CoverageSuite` | integrated terminal, terminal rows outside every workspace, a renamed row, a signal from another machine, subagents |
| `ScaleSuite` | adoption, twenty-two sessions, dead process |
| `InstallationSuite` | `install-hooks`, **`hook.sh` actually executed**, both halves carry the token, an old Claude Code kept on the script, non-headless startup |
| `ModE2ESuite` | `mod install`, a reinstall, a refused install that leaves nothing half in, and `uninstall-hooks`, through a fake `claude` that records its home; the carried files on disk; the port file written `0600`, `/mod` refusing a missing or wrong token and a body that is not a report, a measure landing on a hook's row as the session's own count without touching its colour, and making no row of its own |
| `TrialE2ESuite` | the trial playing the script into the four states the reducer really produces, quitting it leaving no home and no process, `tour --json` printing a script that holds nothing real |
| `TokenLifecycleSuite` | reuse, regeneration, corrupted token, **the launch repair** in a home of its own, an installation under the previous name brought forward |
| `LampMasterE2ESuite` | `mcp install` registering through `claude`'s own command and `uninstall-hooks` taking it out; `lampboard mcp` started as Claude Code starts it, answering from the cards without the asker and behind the notice; a question that keeps only the real source and costs nothing the second time; a round against a fake `claude` that writes down its standard input and arguments: the frame on the pipe and never on the command line, the validator dropping an invented quote, the skip when nothing changed, the day's ceiling, the deadline, an answer outside the schema, switched off, the token |

`AppUnderTest` is the harness: it starts the binary against a fake home, knows
how to run the commands and the hook script, and waits with `waitUntil` because
the realignment is asynchronous.

---

# The companion mod

Not Swift: a Claude Code plugin of function hooks (Claude Code 2.1.287 and later),
in this repository because the repository is its marketplace
(`.claude-plugin/marketplace.json`, plugin `lampboard`, installed as
`lampboard@lampboard`).

### `mod/hooks/register.js`
Three hooks, `session.start`, `session.measure` and `session.end`, each passing the
event on first and then posting to `/mod` on `127.0.0.1` with the token. It reads
the home (`LAMPBOARD_HOME`, else `HOME`, absolute only), the token and the port, and
nothing else; it sends nothing until that port answers `/health` as LampBoard, since
a project's settings can set environment variables for its sessions and a cloned
repository could point the mod at a port of its choosing:
no conversation, no file of the project, no command. When the panel is not there,
or answers anything, it does nothing and says nothing. `claude plugin validate
--strict` lists exactly that, and is what the panel will show (5.10).

> **Touching here** changes the wire format `ModReport.swift` reads: version 1 on
> both sides, or the panel refuses it. Anything added to what the mod reads or
> where it posts changes what people agreed to install.

---

# Scripts

| File | What |
|---|---|
| `Scripts/build-app.sh` | bundle into `dist/`, stable signature when available, with a deadline |
| `Scripts/create-signing-identity.sh` | persistent certificate, **idempotent and self-verifying** |
| `Scripts/make-icon.py` | draws the icon at every size macOS asks for and writes `Resources/LampBoard.icns`; `--preview` adds the small-size contact sheet |
| `Scripts/make-screenshots.sh` | the README's images, taken from the tutorial's trial: the real app on a temporary home playing `DemoScript`, the one place demo data lives (D64), with `--trial-fresh` so the band always shows step one and nobody's progress moves; `screencapture -l` reads the window's backing store, which works with the screen locked. `LAMPBOARD_BIN` points it at a build other than the bundle |
| `Scripts/make-cask.sh` | renders the Homebrew cask from a **published** release, taking the checksum from the asset GitHub serves rather than from `dist/` |
| `Scripts/release.sh` | disk image into `dist/`, twice — under the version and under the version-free name the `latest` address serves; signs, notarizes and staples when the keychain allows it, and says which of the three outcomes it reached |
| `Scripts/make-pkg.sh` | the installer package a fleet manager deploys, wrapped around the bundle `release.sh` already stapled: a disk image has no version field and an MDM needs one to read. Refuses to produce an unsigned package, and needs a Developer ID **Installer** certificate, which is not the one that signs the app |
| `Scripts/test.sh` | both suites, then the documentation check |
| `Scripts/run-remote.sh` | the same gate on the test Mac: pushes the branch to a bare repository there, runs `test.sh` in a worktree of its own under a lock and a time limit; where that Mac is lives in the git-ignored `.env.machines` |
| `Scripts/check-contract.sh` | the assumptions about Claude Code, static or `--live`; `--record` re-records the golden baseline |
| `Scripts/smoke-clicks.sh` | does a click still land where the row promises. `--live` raises windows and asks the window server who came forward; without it, recognition only and nothing moves. Writes `docs/smoke-clicks.md` |
| `Scripts/check-docs.sh` | the figures, links, event counts and suite registrations the docs state, and the WORKLOG's status table against the repository |
| `Scripts/bite.sh` | commits twenty-seven violations and demands twenty-seven catches; a gate nobody has seen fail has not been distinguished from a broken one |
| `Scripts/measure-compaction.py` | every auto-compaction in the transcripts, and the value our own reading had reached at each — the measurement that settles the context denominator |
