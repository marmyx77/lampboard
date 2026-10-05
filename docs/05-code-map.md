# Code map

~67,600 lines of Swift across five targets. For each file: what it contains, why
it exists, and **what you would break** by touching it.

```
Sources/
  LampBoardCore/  20,758 lines · 164 files  pure logic, zero AppKit
  LampBoardApp/    25,190 lines · 139 files   shell: AppKit, network, windows
  LampBoardTests/  16,679 lines · 113 files   1190 cases, instantaneous
  LampBoardE2E/    4,689 lines · 20 files   159 cases, the real binary
  TestKit/            369 lines ·  4 files   minimal assertions
```

No file exceeds 795 lines. The limit the project sets itself is 800.

---

# LampBoardCore

No `import AppKit`, no I/O, no implicit clock: `now` is always a parameter.
Everything that **decides** lives here.

## `Config/`

### `AppConfig.swift` · 638
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

### `Harness.swift` · 172
Which coding agent a session belongs to, and — the reason the type exists at all
— **what that agent is unable to say**. One row shape for every harness; what
differs is what a row can promise. `cannotReport` is checked against each
vendor's published event list rather than guessed, and every consumer that would
otherwise infer a state from silence has to consult it first.

The rule it encodes: an absence is declared, never inferred. Codex publishes no
error event of any kind, so a Codex row never turns red and the card says why.

`command` is not an agent but a command run under `lampboard watch` (D70): it can be
neither waited on nor have subagents, has no transcript and no context, and no hook
can claim it — `named` never returns it, so its rows come only through `/watch`.

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

### `SessionState.swift` · 542
The state of one session. **Immutable**: every transition produces a new instance
through `replacing(…)`, which uses double optionals to tell "leave it alone"
apart from "clear it".

It keeps `baseStatus` and **computes** `status`. Read the comment on `status`
before changing anything here: it is the heart of the subagent correction.

> **Touching the computation of `status`** risks reintroducing green during
> background work. Coverage: `SubagentSuite`.

### `ColumnLayout.swift` · 456
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

### `PlanciaHeader.swift` · 36
The Plancia's line of facts (D98): machine, surface and agent, the model by its name,
the context against its window, the cost — what is not known left out.

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

The bar at the top of the wide panel (D77) is counted too: a padding, its field,
and while something is typed its results and LampMaster's answer.

A wide row is taller than a narrow one by its second line (D76), and the block
height uses it wherever the panel is wide.

The queue above the rows (D74) is counted here too, card by card with its «more»
line and the padding above it: drawn above the rows, an uncounted queue would push
the last project off the end.

### `ShortSpan.swift`
How long ago, in one number and one letter, and **never more than two digits**.

The ceiling is the design. This field shares one line with the name (240 points when it was set, 340 since 0.6) and
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

### `GovernorPlan.swift` · 96
The governor (D112): which sessions run one model lower until the window resets —
one step down by family, never the session in focus, expired entries dropped — and
the exchange with the mod, proven with the permission key and answered signed.

### `AllowanceForecast.swift` · 59
When the session window runs out at the last hour's pace (D111): a least-squares line
through the readings since the last reset, at least ten minutes of them and climbing,
or no forecast; the sentence only when it would run out before it resets.

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
`ordered`, and `session(named:)`, which also takes the eight characters LampMaster
names a session with when they name one only — a LampMaster card carries the short
form, and looked up as an id it opened nothing.

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

### `WatchReport.swift`
What `lampboard watch` posts to `/watch`, bounded like the mod's reports, and the row
it leaves: yellow while the command runs, green on 0, red with `exit` and the code in
the message otherwise. Its session id carries its own `watch-` prefix, so it never
meets a real one, and an end whose start the panel missed still makes its row.

### `StopFailureReason.swift`
A **closed** set of ten causes. An unexpected value falls back to `unknown`
instead of propagating as a free-form string all the way to the row.

`hasUsableOutput` is true only for `maxOutputTokens`: there the text exists, it
is merely incomplete, so the row is green rather than red.

### `SessionOrigin.swift`
`.editor`, `.terminal` or `.background` (`claude --bg`, D103): the kind of place a row lives in, set by whoever
resolves the workspace and read by everything that treats a terminal row
differently (D25). Not on `Workspace`, which is the row's identity.

### `BackgroundJob.swift` · 81
What the Agent View keeps of a background session in `~/.claude/jobs/<id>/state.json`
(AV2, D104): its id, the summary Claude Code writes of it (`detail`), and what it
needs, kept only while `tempo` says it is blocked. One line each, control and
format characters turned to spaces, cut at 200. The id goes into `claude attach
<id>`, which the person pastes into a shell: letters, digits, dashes and
underscores, starting with a letter or a digit, or it is no job.

### `AwayLedger.swift` · 50
What happened while the person was away (D114), counted as it happens: answers per
session, failures, what each session's cost rose by; and the one line said on return,
with what still waits read from the column then.

### `FocusHold.swift` · 57
One session in the foreground (§5.3, D110): whether a notification may go out now,
what waits — once per session and kind — and the one line said when the focus comes
off, the most urgent kind first, with only what is still so.

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

### `SpokenAlert.swift` · 26
The voice (D117): whether a waiting session is also said aloud (asked for, the
screen unlocked, a minute without a key) and the sentence, the row's name flat and
cut at forty characters.

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

A change of width keeps the edge nearest the side of the screen (D78): a panel on
the right half grows to the left, toward the middle.

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

### `RowActivity.swift` · 79
The row's second line in the wide panel (D76): what the session is doing now, in
the fewest words — what it asks, the tool it is on and, past fifteen minutes on
one, `stuck 16m on npm install`; why it died; the first line of the answer that
waits; what holds a blue row; at rest only its agent. A remote row says its
machine first, a project of several adds `+N`. A background row says
"background" first and reads its job (D104): what it needs while blocked, unless the
hooks hold a question, and Claude Code's summary when it is ready or at rest. One
line, its control and format characters turned to spaces, cut at eighty characters.

> **Touching here** changes what every row says at a glance. It must stay one
> phrase: the card is where the rest goes.

### `RowSummary.swift` · 251
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

### `DesktopCodeSession.swift` · 65
The Claude app's Code tab as it files a conversation (D107): its index under
`claude-code-sessions` names the app's own id (`local_<id>`) beside the
transcript's, the one every hook carries. Reads the one by the other, with whether it
is archived; between two indexes naming the same transcript prefers the open one,
then the newest; builds `claude://code/continue?session=local_<id>` only from an id
in the shape the app accepts, so nothing on disk adds a parameter.

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

## `Index/`

### `IndexRecords.swift` · 120
What the search index keeps of a transcript (D88): the person's words and Claude's
answers, as `TranscriptDecoder` reads who spoke — never context, notes, tool calls or
another session's message — each cut to 4,000 characters; and what the lines say of
the conversation (folder where it began, title from `custom-title`, `summary` or
`ai-title`, first and last, prompts), a later chunk adding to an earlier one. `IndexQuery` turns what
was typed into an FTS5 query that cannot be misread: every word quoted, the last a
prefix, at most eight.

### `WeekSummary.swift` · 224
The week in a paragraph (D90), and as tiles with the time sessions waited on you (D109): from each
answer to the next prompt in its conversation, a gap over four hours left out as an absence; the prompts of the last seven calendar days, today
included, counted per project — a folder, not a name: two `api` folders are two projects, told
apart by the folder above — conversations, days, the titled conversations busiest
first — and the busiest day, the most recent between equals. Eight projects and three
titles each at most, the rest counted; folders and titles flattened and clipped, since
another session chose them; dates in English whatever the Mac's language.

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
matched on. A hash must contain a digit, or `defaced` would be one. And the names
the fingerprint takes out, four at most and none every error says: what a search for
the same failure elsewhere needs (D92).

### `LampMasterSignals.swift`
What can be told without any model, with every threshold in one place: waiting on
you, stuck in a turn, the same failure three times in an hour, the same files or
branch as another session, finished, context nearly full. They show at once and
reach the round already worked out, so its tokens go on what only a model can
judge. A session asking through the panel's own amber is not also "waiting".

### `LampMasterFrame.swift`
The frame the round is given, under a 12,000-token budget: sessions with signals
first, then live ones, then the most recent. Over budget it shortens quiet closed
sessions before it drops any, and its precedents before that. A live session is in as soon as it has done
anything; a closed one for six hours, or a week if it was left asking.

### `LampMasterPrecedents.swift` · 77
The fifth job's candidates (D92): each recent failure's names searched in the index
once, four failures at most, the most recent first; another project's conversation,
or the same project's from a day before, never the session's own; three each, with
the words around the match in one clean line of three hundred characters.

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

### `LampMasterSheets.swift` · 138
The window's sheets beside the cards (D96): the day's suggestions with their outcome;
the last saved frame read back — sessions, signals, precedents, the allowance; the
day's rounds and spending, the last ten runs, each kind with its acceptance and state.

### `LampMasterSchedule.swift`
When a round runs and when it is skipped for nothing: switched off, no session to
look at, the frame unchanged since the last round, the day's 200,000 tokens spent,
the allowance it spends tight (D93).
The digest leaves out the minutes, which change by themselves; a threshold crossed
shows up as a signal, and signals are in it. A failed round counts as a run, or a
broken `claude` would be called every minute.

### `RemoteTranscriptScript.swift` · 125
A node's transcripts for LampMaster's cards (D94): the paths that may be asked, the
program that reads them there — real path under that machine's projects, opened
without following a link or waiting on a pipe, from the last offset or the tail, half
a megabyte at most — with the asks as base64, and its answer read strictly: only what
was asked, numbers that add up; whole lines only.

### `LampMasterBench.swift` · 81
The test bench (D102): a saved round read back as its frame and answer; two answers'
suggestions compared by key with what the person did with them — accepted ones lost,
ignored ones gone, new ones — and the report that puts the regressions first.

### `LampMasterAutoMute.swift` · 50
The kinds that switch themselves off (D95): under a fifth taken up over two weeks, ten
reactions at least and two weeks of history, a kind asked back counting from then.

### `LampMasterQuota.swift` · 60
The allowance in the round's frame and the rule it gives way to (D93): each account's
window most at risk, and a forecast at the pace so far — none before 15 % of a window
has gone; tight when this Mac's session or weekly window would run out before its
reset, a model's own cap aside.

### `LampMasterQuick.swift`
The quick round (D72): which signals are urgent (a repeated failure, a stuck turn),
one key per session and signal; whether a quick round is due (a pair the last round
did not see, ten minutes after any round, six a day); and its model, Sonnet, chosen
on a measurement that put Haiku at up to 56 seconds.

> **Touching here** changes how often LampMaster spends the allowance without being
> asked. A key that changes every minute would bring a round every ten.

### `LampMasterLine.swift`
What LampMaster's line and cards say: never a blank line, the reason when there is
nothing ("Today's tokens spent · signals only", "Allowance tight · signals only", "Last round failed: claude was not
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
other sessions, never an instruction. `remembered` adds, after the cards, the
earlier conversations the search index found (D89): their names, never their words.

### `LampMasterAsk.swift`
The question that does run a model: its schema, its prompt, the screening of its
sources and the limits. A source survives only when its whole quote is in the
frame — stricter than the round's evidence, because a real clause could otherwise
carry an invented one into another session. Twenty questions an hour, five per
session, and the same question within ten minutes gets the answer already given:
a session's model calls tools on its own, and a loop in one must not spend the day.
The person asks too, from the panel (D118): the message then carries the last three
exchanges and what the search index found, word by word, cut to roots and merged
where two words agree; a follow-up is never answered from an earlier answer.

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
`measure` (the session's own context count, cost, rate-limit windows), `end`
(Claude Code's own reason), `tool` (a call's start or end, its name, and its
line cut to one printable line) and `answer` (a side question's nonce and the
fork's reply, lines kept, controls gone, at most 4,000 characters, or the word for
why there is none, D82); a `start` names what the mod can do (`ask`). Every field is bounded on the way in, because the route
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

### `DecisionBoard.swift` · 147
The decision board (§5.5, D105): one-line decisions pinned per repository, keyed by
`GitIdentity.repo`, at most twenty a repository and 300 characters each, the same
words twice refused whatever the case. Its version, a hash of the repository's name
and its words, tells a session it has something new to read; the block the model
reads, numbered; the withdrawal sentence, which names no repository because a
session's repository name comes from its project. Its file is JSON.

### `DecisionBoardExchange.swift` · 62
What travels to and from the board. The command line's changes (`{"repo","text"}`
pins, `{"repo","remove"}` takes off). The mod's request, proven with the permission
key for its own session. The answer `board <version> <signature>` and the words, signed
over the nonce, the version and the text, because those words enter a conversation.

> **Touching here** changes what `mod/hooks/register.js` signs and checks:
> `ModFilesSuite` holds the two to the same messages.

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
must look changed. It has words for `tool.check`, `command.run`, `session.receive`
`$.model.fork` (a side question over the conversation), `ui.render`, `$.ui.resolve` and `$.ui.invalidate` (the band).

### `ModAllowance.swift`
This Mac's allowance with the mod's windows in it (D67): `five_hour` and
`seven_day` become the session and week bars when they are newer than the usage
service's answer, which keeps the account's name and a model's own weekly cap; with
no answer at all they stand alone, labelled by the machine. A window with no bar
here, a gateway's spend limit, is left out.

### `ModLedger.swift`
Per session: surface, interactive, model, cost, the last rate-limit windows and
when they were read, why it ended, and the tools running now by call id (at most
32, forgotten at the session's end). `RunningTool` says when one has run long enough
to call the session stuck: fifteen minutes (D69). An empty list of windows keeps the last figures
(it means "no reading", never "every window at zero"); the account's windows are
the newest any session reported. Bounded at 300 sessions, least recently heard
first out.

## `Demo/`

The invented sessions and the tutorial's tour (D64). One place for demo data, so
one place to check that it holds nothing real.

### `DemoScript.swift`
The script the tutorial, the screenshots and the site's demo are played from: six
invented projects, beats in time, each beat a hook payload exactly as the installed
hook would post it, so the trial panel reaches its colours through the same server
and reducer as the real one. `DemoScriptCheck` refuses an account outside
`example.com`/`example.net`, a project outside the invented list, a home path or a
private address: the same rule as the repository's gate, applied to the one file
that is shown on screens.
It also holds the answers the trial plays where a mod or a model would answer (D120):
the permission api asks for, events' side answer and LampMaster's reply, checked
by the same rule.

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
the row clicked, `⌘⇧L` reaching the Plancia, a result chosen in the bar, a session
put in focus, *I'm away* left again, the card answered — and with nothing else;
there is no "Next" (D119). Each sentence fits the band's two lines.
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

### `TranscriptDecoder.swift` · 293
Record → entries. The point where a second stream of external data enters the
domain, and it fails **quietly**: an unrecognized record yields nothing rather
than an error, because Claude Code adds record types between releases. A message
through Claude Code's box (D81) — a user record of origin `peer`, or a
`queued_command` attachment when it was taken mid-turn — is the user's words only
when it says it is from `lampboard` and starts with the panel's preamble — both the
sender's own word; any other is "a message from another session".

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

### `ContextReading.swift` · 244 · `ContextScanner.swift` · 138 · `CacheClock.swift` · 16
How full a session's context is, read backwards from the end of its transcript — and
how long its prompt cache lives, from the reply's own account of how it was written
(`ephemeral_1h` or `ephemeral_5m`), for a waiting row's minutes (D100).

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

## `Band/`

### `Band.swift` · 68
The band above every session's prompt (D84): what stops work elsewhere — a
permission, a question, a stuck or failed turn, from the queue's cards in its order
— three at most, never the asking session's own, each a title and a line read as a
permission card reads one (secrets masked, no format character), only the kind of
wait for a session on a node;
and the versioned wire the mod reads.

## `Bar/`

### `CommandBar.swift` · 248
The bar at the top of the wide panel (UX §2, D77), as logic: what was typed — text,
`@name message`, `?question`, `/command` — and what it finds. Sessions by name first
(exact, from the start, from a word, anywhere), then by what they say or are titled,
ties to the more urgent, titles flattened to one clean line; then the panel's actions by their words, then the conversations the index found
that are not rows (D88); `/handoff @from @to`, the best match of each, never a session to itself, a hint when half typed and never above an action a short prefix also names (D91); the sessions a name finds, the exact one alone when there is one; empty, what needs
you. `@name` with words after it makes each session found a "Send to" result, which
says where to switch sending on while it is off, and for a session on another
machine names the machine it goes to (D81, D83). `@name ?question` makes each one an "Ask
… without disturbing it" result, with something to act on only for a session whose
mod can answer, on this Mac (D82). Eight results at most. A question becomes one result for LampMaster, or says
it is switched off.

> **Touching here** changes what a few keystrokes reach. A name typed exactly must
> stay the first result, or the bar stops being faster than the column.

### `BarShortcut.swift` · 35
The bar's shortcut from any application (D77): off, `⌥⌘K` or `⌃⌘K`, with the key code
and Carbon modifier mask each one registers; a stored value nobody recognises is off.
A short list rather than a recorder, because every entry on it leaves `⌘K` to the
editor.

## `Peer/`

### `PeerBox.swift` · 120
Claude Code's own message box (D81), as rules: the box a session file under
`~/.claude/sessions/` names (protocol 1, an absolute `.sock` path short enough for
`sun_path`), the key file `<pid>.<hex>.key` for that pid and no other, its token
only when written for that very process (`procStart`), the two lines a message is
— the key, then the user's words under the panel's preamble, from `lampboard` — and
the words read back out of Claude Code's envelope, or bare when taken mid-turn; and the
same two lines around a content of the panel's own making.

### `PeerAsk.swift` · 34
A side question without disturbing (D82): the line the mod can prove — the head,
the nonce, an HMAC with the permission key over nonce, session and question — then
the question, at most 2,000 characters; the feature a mod announces, and the
minute the panel waits.

### `Handoff.swift` · 59
The baton (D91): the question a session is asked when another takes over — what it
understood, decided, left and touched, thirty lines, no secrets — within a side
question's size, and the brief proposed to the other: whose it is, then the text.
And the request the mod posts from `/handoff <name>` (T2): read strictly — version,
a session's shape, a name, words within the mod's cap counted as it counts them —
and only when its HMAC with the permission key covers the fields as sent.

### `RemotePeerScripts.swift` · 112
A message into the box of a session on another machine (D83, B3): the payload —
the session, the content as it goes in, the sender — and the Python that runs there
over ssh, finds the box on the Mac's own terms (the session file named after its
pid, the user's, not a link; the process alive, the user's, started when the file
says; the key private and written for that very process, start time and all; the
socket the user's), writes the two lines, and says it did, or why not — a box slow
to close after them counting as delivered.

## `Permission/`

### `PermissionGate.swift` · 144
Allow and Deny from the panel (D73, D80), as rules: the ask a session's mod posts —
session, call, tool, and one masked line, read with the mod's own validators and
refused rather than guessed when malformed; the verdict, one of `allow`, `deny`,
`ask`; the book of asks waiting, one per call and eight at most, each answered once,
each sent back to its session's dialog at 55 seconds, a question at 20; the proof an ask must carry
(HMAC-SHA256 of a nonce with the permission key) and the signature its answer goes back
with, so neither side ever sends the token where something else could listen;
answers addressed by session and call.

> **Touching here** changes who decides what a session may run. A refused or
> expired ask must always end as `ask`: the dialog the session would have had.

## `Plancia/`


### `QuestionGate.swift` · 70
A session's question answered from the panel (D86), as rules: the question the mod
puts — one question, two to four options, distinct, each one clean short line —
refused rather than guessed; the proof under its own prefix, so a permission's
cannot stand for it; the choice signed by its index, or `ask`; twenty seconds with the panel, since a
`tool.call` hook is dropped between 25 and 30.

### `HoldExchange.swift` · 65
Away, a destructive command waits (D116): the request proven for a session, its
whole command and whether it was cut; every line judged unmasked, a cut command held
unread, the sentence said only away; the answer `go` or `hold` and the sentence, signed.

### `PermissionImpact.swift` · 71
What a permission would do, beside its Allow (D87): a shell command that destroys,
named by what it does from its one masked line — recursive deletes, force pushes,
discarded changes, overwritten disks, dropped data, recursive permission changes,
root, a downloaded script piped to a shell — or an edit's or a write's lines, from
the mod's counts; "more lines unseen" when the command goes on past its first line.
A fixed set of spellings, compiled once: a command it does not know is said nothing
about.
### `PanelDepth.swift` · 43
How much of the panel is out (UX §1): the column, the panel, the Plancia. `⌘⇧L` goes
one deeper and from the Plancia back to the column, `Esc` one down; the widths are
the UX's, 44, 340 and 780 points; the Plancia closes by itself after four seconds
with the pointer away, nothing waiting and no pin. Used by the panel from P2 on.

### `RadarExchange.swift` · 46
The radar's exchange with the mod (§4.4, D113): the request proven with the
permission key for a session and a file, the sentence naming the other session —
flattened, quoted — and the answer, `clear` or `written` and the sentence, signed.

### `FileConflicts.swift` · 65
Two live sessions writing the same file of the same checkout in the last two hours
(D99): from the writes the mods reported, absolute paths only, each session naming
the others; and, for the radar (D113), the latest other live session to write one file.

### `SessionActivity.swift` · 80
What one session has been doing, for the Plancia's Activity tab: each tool with its
duration once it ends (an end without its start adds nothing), each turn with what
it alone cost from the mod's running total, the newest sixty kept, a tool's detail
one line of at most 120 characters; `record` reads a `ModReport` into it. In memory only: a view of now, not a record.

## `Queue/`

### `WaitingQueue.swift` · 267
"Waiting for you" (UX §3, D74): the cards drawn from the rows — a permission, a
question, a turn stuck on one tool, a failed turn, answers to read (one card each up
to two, then one card for all), LampMaster's first open suggestion last with the
count of the rest — in that order, then by age, read from the state the row shows.
An ask the panel holds (D80) is a permission card of its own, carrying its call; a
held question (D86) is a question card carrying its options, a digit choosing one.
A permission card carries what the call would do (D87), from the mod's ask or a hook's.
A card is armed 600 ms after the queue first shows it as it is (`Arming`): an ask's
words are in its id, so a second permission is a new card. The keys: `J` `K` move and stop at the ends, `O` opens, `E` marks read what
there is to read; `A` and `D` answer an ask the panel holds; `S`, `R` and the digits,
and `A` `D` on any other card, answer *unavailable* until the panel has a hand in the
session (D73). A card that leaves without the panel acting on it, if it was an ask,
was answered in the terminal; a held ask is said only when it went back to its
dialog (`returned`).

> **Touching here** changes what interrupts somebody first. A permission must never
> be something `E` reads away: that is a question left unanswered.

## `Reducer/`

### `StateReducer.swift` · 719
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

### `SessionsPayload.swift` · 258
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

### `RemoteInstallScripts.swift` · 264
The Python that runs on another machine to inspect it, write the hook script and the merged settings, or ask whether the tunnel answers. In Core and under test for the same reason the probe is: a promise to another machine has to be readable in one place. The data travels inside the source as base64 — no shell quoting rule is involved. The inspection hands back the text of our script there under both names, so the token is judged here by `HookRepair` and the node is never told one, and the version of the mod LampBoard put there, if any; a domain case runs the real scripts against a home laid out like the node, inspect to apply and back.

### `RemoteModScripts.swift` · 147
The companion mod written onto another machine (D83): the payload — the carried
files, this panel's token, the tunnel's port, the permission key, Claude Code's
own `claude plugin` steps with the folder left for the far side to name — and the
Python that writes it there through `O_EXCL | O_NOFOLLOW` at `0600`, marked as
the tunnel's, on one deadline; refuses a `~/.lampboard` that is a link, another
user's or writable by others, and stops at a machine whose unmarked token or port
belong to a panel of its own. A failed install takes the key back; taking it out
removes the three files only when they are marked ours.

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
The two parsers for the on-disk files. A live file's `jobId` — a background
session's folder under `~/.claude/jobs/` — is kept only when it is fit for a
shell (AV2).

### `SessionDeepLink.swift` · `AppleScriptString.swift`
The extension's URI, the policy that sends it only to sessions the extension
hosts (`DeepLinkPolicy`: entrypoint `claude-vscode`, or unknown), and the
escaping of titles inside a script.

---

# LampBoardApp

It does I/O and draws. **It does not decide.**

## Entry point

### `main.swift` · `AppDelegate.swift` · 573
`MainActor.assumeIsolated` in `main.swift` is needed because top-level code isn't
isolated to the main actor, but that is where we are by definition.

The launch settles the token **once**, then repairs the hooks with it, then starts
the server with it — in that order. Each step reading the store for itself is how
the launch that regenerates a burned token would have written the old one into
every hook (D48).

`AppDelegate` wires everything up. `--headless` skips `startInterface()`, and
that is why the E2E suite didn't see the notification crash: it never went
through that branch. `--plancia` opens the Plancia on the most urgent session six
seconds in, for a picture taken on a Mac nobody is clicking.

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

### `CommandLineBench.swift` · 54
`lampboard lampmaster bench` (D102): the last saved rounds replayed through the round's
own `claude`, both answers through the round's validator, the comparison printed.
One round's tokens per frame; never on its own.

### `CommandLineDecisions.swift` · 65
`lampboard decide <repo> <text>`, `decisions [repo]`, `undecide <repo> <n>` (D105):
the board changed and read through the running panel, its only writer; `--port`
counts only first or last, so a decision that mentions one keeps its words.

### `CommandLineSearch.swift` · 47
`lampboard search <words>`: the index brought up to date in one go — a person asked
and is waiting — then the conversations that say the words, the best first, each
with its day, its name — printed clean — its id and the words around the match; `--reset`
takes the index away (D88). `lampboard week` arrives here as `search --week` and prints
the week's paragraph (D90).

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

### `CommandLineInterface.swift` · 759
The commands and their dispatch: install-hooks, uninstall-hooks, status, selftest, focus, next, open, new, chat, sessions, remote, terminal, rename, mcp, mod, watch, tour. `--port` is read only before a `--`, so a watched command's own `--port` stays its own. `new` and `chat` share `runSlotCommand`; `open` stays separate
because a bare `open` lists the assignments, which is a different command wearing
the same name. `focus --dry-run` diagnoses without moving any windows.

### `CommandLineHelp.swift`
The text `lampboard help` prints, moved out of the parser when it reached the
800-line ceiling: it grows with every command.

### `CommandLineWatch.swift`
`lampboard watch [--name N] -- <command>` (D70). The command runs as a child with
this terminal's input and output, and its exit code is returned as its own, so the
wrapper can stand in for the command in a script. Ctrl-C reaches the command —
through an empty handler, because an ignored signal is inherited across exec — and
this process lives to report how it ended. A panel that is not there leaves the
command alone, said once on the error stream.

### `SelfTest.swift` · 287
`lampboard selftest`: the whole chain, link by link — the port opens, a signal
crosses HTTP, decodes, resolves to a workspace, the Accessibility permission is
there, the hooks are registered — and it names the link that broke.

## `Runtime/`

| File | Lines | What |
|---|---|---|
| `StateStore.swift` | 795 | `@MainActor`, `@Published`, periodic realignment; the Codex probe is started here and awaited nowhere |
| `StateStoreAdoption.swift` | 247 | where an unclaimed hook belongs — a terminal tab's file, or a background session's, admitted with terminal sessions off and never an editor's (D103) — and the rows nobody announced: the Claude Code sessions already running, Codex from an open rollout, Claude Desktop from its index and transcript. All obey the same two rules — what a probe could not see is never read as gone, and a state nobody reported is never dressed up as one that was |
| `BackgroundJobReader.swift` | 46 | a background row's job file, the one its live file names, read on each poll while a background row exists — never the whole folder, which keeps every job ever run; a file past 256 KB or naming another session is no job, and a job gone clears the row's (D104) |
| `DesktopCodeSessionFinder.swift` | 45 | the Code tab id of a row's conversation, found at the click (D107): every index under `claude-code-sessions`, the folder resolved first because a listing does not follow a link, a file parsed only when its bytes hold the session's id |
| `ClaudeDesktopScanner.swift` | 242 | finds the Claude Desktop conversations running here. Presence is the index and the transcript, never the agent process: that process lives one turn, so a row built on it vanished at the moment there was an answer to read |
| `SessionTerminator.swift` | 91 | finds the process behind a row and ends it when asked. Only where the session names its process, only if that process is alive and started when the record says — checked again after the confirmation, because a pid can be reused in those seconds — and `SIGTERM`, never `SIGKILL`. `ps` is asked with `TZ=UTC`: the file records the start in UTC and `ps` answers local, so comparing the two strings never matched and the menu entry would have been invisible for ever |
| `CodexApprovalReader.swift` | 91 | reads the rollout an event names, to learn who will answer its permission request. The tail first, then the whole file when the tail does not say: measured on an audit of a whole codebase, rollouts of 1.8 MB and 3.5 MB whose only `turn_context` sat outside any tail, and reading only the tail put them straight back to blinking amber. In the shell because it touches a file: the reducer receives the answer, never the path. The tail and not the file, so the cost does not grow with the length of a conversation |
| `CodexProbe.swift` | 26 | an `actor` around the Codex scanner. It spawns `lsof`, and instrumented here it was 80 ms of a 150 ms sweep on the thread that draws. Serialising also means a slow probe cannot have a second started on top of it |
| `SweepCost.swift` | 83 | where one realignment pass spent its time, phase by phase, and `SweepLog` keeping the worst and the average across passes. Added because an audit said the sweep was too slow and neither side could settle it by reading |
| `ModReceiver.swift` | 94 | takes in what the companion mod reports: the ledger beside the column, a measure's context to the reducer as `reported` and its cost as `costed`, the default account's windows to the allowance strip. Never makes a row: a measure for a session the hooks have not announced is dropped. Writes `~/.lampboard/port` (`0600`, staged under a fresh name opened exclusively and without following links, then renamed) for the mod, which is one file for every Mac and reads the port where the hooks have it in their script |
| `Preferences.swift` | 582 | `UserDefaults`, separate domain under `LAMPBOARD_HOME`; imports the previous name's domain once, before anything reads a preference |
| `ActivityRecorder.swift` | 34 | what each session has been doing, for the Plancia's tabs: the mod's reports and the hooks' turn ends folded into a `SessionActivity` per session, in memory, the 64 heard from most recently |
| `AwayMonitor.swift` | 61 | "I'm away" (D114): said from the menu or by the screen locked three minutes; the ledger kept while away, notifications held, and on return the line as a notification and at the panel's foot |
| `PermissionDesk.swift` | 218 | Allow and Deny from the panel (D80): each ask the mod posts to `/check` held on the server's queue until the panel answers or its 55 seconds pass, refused at once (`ask`) while the switch is off; the answer from a click, a key or `/check/answer`, taken once; what waits published for the queue and listed by `GET /check`, and which asks went back to their dialog; a question held the same way and answered by the index of the option chosen, never by Allow or Deny (D86); `stage` books the trial's permission with nobody waiting on it, and `onAnswered` tells the tour (D120) |
| `PlanciaModel.swift` | 65 | the Plancia's state: the open session, or LampMaster's own Plancia and the sheet it opens on (D97), its `ChatSession` with the mailbox opened and released the way the chat window does it and the same sending switch (D15, D81), the pin |
| `CommandBarModel.swift` | 258 | the bar's state: the text, its results, the selection, whether the field is open (the queue's keys stand down while it is), a "Send to" chosen only with sending on and the text kept when it did not go, an "Ask … without disturbing it" answered where LampMaster's answers show, the index asked a quarter-second after typing stops, the selection following its result when the list reorders, LampMaster's answer and whether it is still being asked, a handoff asked once at a time and the bar closed when it waits in the Plancia, "This week" read off the main actor, one at a time, and shown in the same place — dropped if the bar closed or the question changed before it came; the panel asked to remeasure on every change that can move the bar's height |
| `GlobalHotKey.swift` | 49 | one shortcut that works from any application, through Carbon's hot keys: no permission, where a global key monitor would need Accessibility and see every key typed; a combination another app holds is logged, and the panel's own `⌘K` still works |
| `WaitingQueueModel.swift` | 210 | the queue's state between refreshes: the cards, the selection (the most urgent until `J` or `K` moves it, then following its card), when each card was first shown, a redraw when one arms, the asks answered elsewhere for a second; a local key monitor that takes `J K O E`, `A D` for an ask the panel holds, a digit for a held question's option, and answers the rest of `A S D R 1–9` with a beep until the panel can act in a session (D73) |
| `LampMasterService.swift` | 368 | LampMaster's round from the panel's rows to the suggestions on screen: the five-minute tick, the quick round a turn's end or a failed tool looks for (D72), the kinds passed over switched off (D95), the frame with the allowance strip's quota and the nodes' sessions — one ssh per node, on threads of their own, while LampMaster is on (D94) —, the skip — a tight allowance among the reasons (D93) —, the run — its precedents searched in the index only then, off the main actor (D92) —, the validator, the files, the state the server hands out. Every decision is in Core; this reads, runs and keeps. One round at a time, and one daily ceiling shared by the rounds and the questions |
| `LampMasterQuestions.swift` | 195 | what a session asks through the `lampmaster` MCP server: the lookups at once from the cards, `who_knows` and `precedents` naming the index's earlier conversations too (D89, D92), a question through the round's isolated `claude` with Sonnet. A question is **booked** in `asks.jsonl` before it runs, so questions arriving during its minute and a half count it; two at most at once. The session id a call carries is the caller's own word, a label for the per-session limit; the hourly total is the bound |
| `LampMasterRunner.swift` | 94 | finds and runs `claude` for a round or a question — only in the fake home under `LAMPBOARD_HOME`, so a test that forgot its fake fails instead of spending the real one; the pids in flight, held only while they run, so quitting stops them; the box the server reads the state from |
| `LampMasterCards.swift` | 182 | a card for every conversation LampMaster may look at: the panel's rows, and the transcripts closed in the last week. Followed by byte offset like the chat window — the tail first, then only what was appended, again from the start if the file shrank. An `actor`, so the reads stay off the thread that draws. The nodes' transcripts are followed the same way by host and path, from what one ssh per node brought (D94) |
| `DecisionBoardService.swift` | 80 | the decision board on disk, `~/.lampboard/decisions.json` (D105): read at launch, written whole through a `0600` file renamed into place, under a lock because the server's threads reach it; an unreadable file set aside as `.unreadable`, not overwritten by the next pin; `/decisions` answered with the board as it now is, or why not |
| `GovernorService.swift` | 58 | the governor's plan on disk, `~/.lampboard/governor.json` (D112): 0600, renamed into place, read again when the file changes, under a lock because the server's threads ask it |
| `LampMasterFiles.swift` | 181 | `~/.lampboard/lampmaster/`: rounds, suggestions with their outcomes, the notebook, the last 200 frames — read back for the bench (D102) —, the last day's questions. The folder is `0700` because the frames quote conversations |
| `TrialStage.swift` | 199 | the trial: an editor lock per invented project, a stand-in process per session — for the Codex one, the app itself run as `codex trial-hold <rollout>` through a hard link, since a Codex session lives only while a process of that name holds its rollout open — a transcript with a title, LampMaster's demo card, then every beat posted to the app's own `/signal`. **Refused without `LAMPBOARD_HOME`**, where it would put invented sessions into the real `~/.claude`; on quit the stand-ins end and the home goes, but only a home `lampboard tour` named |
| `SupportDirectoryMigration.swift` | 60 | carries `remotes` and `inbox` over from the support directory of the previous name — both unrecoverable elsewhere, both failing silently |
| `SnapshotBox.swift` | 27 | lock-protected copy for the server |
| `TokenStore.swift` | 78 | `0600` token, **regenerated** if the permissions are wide |
| `LocalClient.swift` | 179 | talks to the live instance for `sessions` and `next`, and for the `lampmaster` MCP server, which waits as long as a question may take |
| `SessionNotifier.swift` | 325 | `awaiting` notifications after a delay, `failed` and (asked for) `ready` on the transition only, so what was already so at launch is not news; anti-duplicate memory, gate; the text from `NotificationText`; while a session is in focus the others wait, said in one notification when it comes off (D110) |
| `TranscriptReader.swift` | 112 | follows one transcript by byte offset; opens on its tail, title from its head; resets when the file shrinks |
| `TranscriptPreviewReader.swift` | 98 | the last thing said, from the file's tail, cached on its size |
| `ContextReader.swift` | 110 | how full the context is, from the same tail, cached the same way — an `actor`, so the seek never lands on the thread that draws |
| `SessionTitleReader.swift` | 16 | the first 512 KB of a transcript, handed to the scanner; what names a terminal row |
| `IDEWindowReader.swift` | 54 | reads the locks and **confirms them against the editor's process**, not the file's age |
| `PeerSender.swift` | 130 | the panel's end of Claude Code's message box (D81): the session's file and key under `~/.claude/sessions/`, read again for every message, used only when the process is running, this user's and the one the file was written for, the files regular, this user's and not links, the key private, the socket this user's; the two lines written down the socket, our half closed, and the box's end of file taken as the receipt; no SIGPIPE; a content of the panel's own, for a side question |
| `PeerAskDesk.swift` | 94 | side questions (D82): which sessions can be asked, from their mods' `start` and `end`; a question through the box — over ssh for a session on a node — with the permission key's proof, and the answer report it waits for — registered before it is sent — a minute at most, put in words when there is no text; whether what came back is the session's answer or what went wrong, so a handoff proposes only an answer |
| `RemotePeerSender.swift` | 22 | into the box of a session on another machine, over ssh, with `RemotePeerScripts` (B3) |
| `SearchIndex.swift` | 388 | every conversation of this Mac, searchable (D88): SQLite FTS5 in `~/.lampboard/index.sqlite`, owner-only, the file itself never a link; each transcript read on from its last offset to its last complete line, 8 MB at most a pass, a shrunk one read again, a budgeted pass newest first within ninety days, only regular files in real project folders; a chunk kept whole or not at all, its offset read under the write lock, two writers waiting for each other; conversations whose transcript is gone pruned; excluded from backups, removable (`--reset`); the hits grouped after `bm25()`; the serial queue taken per file; the prompts since a date, only of conversations active since, for the week's summary (D90); the answers' times of the week, never their words, for the waiting (D109) |
| `MailboxWriter.swift` | 206 | the panel's end of the mailbox; carries out the reaper's verdict; counts the views holding a session's marker, so the chat window and the Plancia do not take it from each other |
| `RemoteSessionReader.swift` | 108 | asks another machine over ssh; `nil` means no answer, `[]` means nothing running |
| `RemoteCommand.swift` | 168 | runs a Python script on another machine over ssh: one shape, one set of timeouts, errors that name the fix; an answer longer than asked for stops ssh |
| `RemoteTunnel.swift` | 290 | the reverse ssh tunnel per host, kept alive with backoff, on a connection of its own whatever the user's `ControlMaster` says (D83); `ExitOnForwardFailure` makes a taken port a reason, and `TunnelRefusal` says whether that reason is on this Mac |
| `RemoteFleet.swift` | 229 | every configured machine: its tunnel, its hooks, what it last said; follows the preference list live; every check repairs stale hooks over there, and a tunnel coming back up after a failed check asks again; the list read again on the remote poll's clock, since a host added from a terminal raises no notification here; a node's mod brought to this app's version at the check (D83) |
| `DictationService.swift` | 339 | `SpeechTranscriber` on the device, `AVAudioEngine` capture, macOS 26 only |
| `PresenceFile.swift` | 91 | presence file, deleted on shutdown |
| `LaunchAtLogin.swift` | 106 | blocked when the signature is ad-hoc |
| `LiveSessionReader.swift` | 135 | reads the live sessions; takes activity from the **transcript**, not the session file. A pid that is alive but started at another moment than the file records was handed to another process, and its session is dead (D68) |
| `ConversationIndex.swift` | 120 | whether a session has ever held a conversation, which is what a row stands for. The derived path first, then a search by session id across the project folders, because a session in a git worktree files its transcript where the derivation does not look (D44) |
| `FinderReveal.swift` | 28 | opens a Finder window **inside** the folder, not on it (D33) |
| `AccountLimitsReader.swift` | 340 | asks Anthropic how much of the allowance is gone, signed with the token Claude Code keeps in the keychain, and for every account the Claude application runs Claude Code as on this Mac (D53). **Borrows it, never renews it**: spending the refresh token could sign the person out of Claude Code, so an aged-out token means the strip goes quiet. Read through `/usr/bin/security`, the tool Claude Code writes it with, so macOS asks nothing (D52) |
| `AllowanceMonitor.swift` | 175 | the timer behind that strip. On a 429 it keeps the last readings and waits longer before asking again (D54). No timer and no request while the switch is off: a feature that reaches the network is either off or on. The strip is the service's answers merged with the mod's windows (D67), which need no switch: they never leave the Mac; each account's session-window readings kept two hours, for the forecast (D111) |
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

### `SignalServer.swift` · 715
Seventeen routes, behind `LoopbackGuard`; `/handoff` takes a handoff a session wrote with the mod's `/handoff`, behind the token and proven with the permission key (D91); `/question` takes a session's question proven like an ask (D86); `/mod/band` and `/mod/band/open`, behind the token, are what a session's band shows and the digit that opens one of its items in the panel (D84); `/watch` is the one besides `/signal` that makes a row, and it requires the token. `/check` (an ask from the mod, proven with an HMAC made with the permission key `~/.lampboard/check-key`, which travels nowhere, held until the panel answers or 55 seconds pass and answered signed; `GET` lists what waits, behind the token) and `/check/answer` decide what a session may run, and both require it too (D80); `GET /check` and `/check/answer` exist only on a fake home, for the tests: in a real install the panel answers in-process. A **concurrent** queue: with a serial one, a `/next` waiting on the
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

### `RemoteHookInstaller.swift` · 277
The local installer's merge applied to another machine: inspect over ssh, merge here with `HookConfigMerger`, write there through `RemoteInstallScripts` — dated backup, atomic replace, no shell in the data path. Also asks the node whether the tunnel answers. `repairToken` brings a node's hooks up to the current token by the same rule the launch applies here (D48), previous-name registrations included, and only when they post to that user's tunnel port; the fleet calls it on every check. The inspection carries the version of the mod there.

### `RemoteModInstaller.swift` · 79
The companion mod on a node (D83): installed with the hooks when it is on here and the node's Claude Code can take it, its files and the three it reads written by `RemoteModScripts`; brought up to this app's version at launch when the node has an older one; taken out with the hooks, before them, while the inspection can still find it. A mod that fails is said after the hooks' line and leaves the hooks in place.

## `UI/`

| File | Lines | What |
|---|---|---|
| `PanelController.swift` | 788 | holds everything together; row and panel actions |
| `PanelSwitches.swift` | 101 | the menu's switches that reach outside the panel — presence, terminal sessions, launch at login — and installing and removing the hooks; out of `PanelController` to keep it under 800 lines |
| `PanelQueue.swift` | 71 | "Waiting for you" wired in (D74): its cards from the store, LampMaster's open suggestions and the asks the panel holds, Allow, Deny and a question's choice handed to the permission desk, `O` and a click raising the session as a row does, `E` marking it seen, keys only while the panel is key (D75), the panel remeasured when the queue's lines change |
| `CommandBarView.swift` | 145 | the bar at the top of the wide panel (D77): at rest a button saying `⌘K`, opened a field — a field present at rest would take the keyboard whenever the panel became key, and the queue's keys with it; results under it while something is typed, LampMaster's answer in a fixed, scrolling height; `↑ ↓ ⏎ Esc`; the week as six tiles above its projects (D109) |
| `PanelDecisions.swift` | 49 | the decision board from a row's menu (D105): pin a line for the row's repository, the ones already pinned shown in the question; one taken off from *Pinned decisions*, confirmed first; the same service the command line reaches, an error said in the panel |
| `PanelGovernor.swift` | 59 | the governor from a row's menu (D112): *Use Sonnet until the window resets (13:10)* for a local Claude Code session with a known model, never the one in focus; chosen again, its own model back |
| `PanelPlancia.swift` | 197 | the Plancia wired in (D79): a session opened beside the list from the row's menu or `⌘⇧L`, LampMaster's from its row, asking for a round if the last is stale (D97), the header's buttons wired to the row's own actions (D98), on the side toward the middle of the screen; `⌘⇧L` through the depths, `Esc` closing it and nothing else; closed by itself after four seconds with the pointer away, nothing waiting and no pin; at least 520 points tall, room for a conversation; its side chosen once at opening; closed when its session ends; no single key taken from a text view that has the keyboard; opened from a session's band, the panel brought up with it (D84); `--plancia-send`, on a fake home only, sends through its composer once a row is there, pinned for the picture |
| `PlanciaView.swift` | 270 | LampMaster's Plancia under its own name and star (D97), or a session's under its header — lamp, name, the line of facts, *Go*, *Hand over*, *Mute* (D98), its waiting card pinned under it (D101) — drawn in three tabs: **Thread**, the chat window's own `ChatView`, so the reader and the composer are the same ones (D15); **Activity**, each tool and how long it ran and each turn and what it cost, newest first; **Cost**, the context, the session's total as the mod reported it, the recent turns; a pin and a close button |
| `PanelBar.swift` | 189 | the bar wired in: sessions open as a click on their row does, `@name message` sent through the Plancia's composer opened on that session, or over ssh into the box of a session on a node, the bar saying where it went, `@name ?question` handed to the side-question desk and the list redrawn when a mod says it can answer, what was said looked up in the search index and a closed conversation's resume command copied, `/handoff @from @to` asking the first and handing its answer to `PanelHandoff`, nothing done once the bar has moved on (D91), actions reach the same windows the menus open, a `?question` goes through the MCP tool's own door (D62), `⌘K` opens it while the wide panel holds the keyboard, the shortcut from anywhere (when chosen) brings the panel up key with the bar open, the panel remeasured when its results come and go; `--bar-type`, on a fake home only, types into it and presses `⏎`, waiting up to two minutes for a row that has answered, `{first}` standing for its first word |
| `WaitingQueueSection.swift` | 191 | the queue drawn above the rows, wide panel only: at most four cards, a line for the rest, a card dimmed until it is armed and outlined while selected with the keyboard, an ask answered elsewhere shown for a moment; a held permission's Deny and Allow with what the call would do beside them (D87), a held question's options, inert until it arms, its line cut in the middle and whole in a tooltip, no click-to-open on it, Allow and Deny as VoiceOver actions; VoiceOver reads the kind, the project and the ask |
| `PanelActivation.swift` | 165 | where a click goes, which is a different question for every surface; a background session's to its Plancia (D103) |
| `PanelAllowance.swift` | 59 | the switch that turns the allowance strip on, and the sentence shown before the first request leaves the Mac |
| `AllowanceCard.swift` | 129 | one account's allowance as a card: every limit, its bar, when it comes back. `TooltipCard`'s grammar but not its type — a `RowSummary` is shaped for a session, and filling in a state and a last message to reuse the view would put a status word on a thing that has no status |
| `AllowanceStrip.swift` | 194 | the account's allowance at the foot of the column: bars, not rings, because the ring already means the context window of one conversation; the time the window runs out in place of the reset, in orange, when that is first (D111) |
| `TrafficLightRow.swift` | 596 | one row: dot, context ring, name, badge, the prompt cache's minutes while it waits for you (D100), the ⚠ of two sessions on one file (D99), the teal `✉n` of answers nobody read (D108), timestamp and, in the wide panel, a second line saying what the session is doing (D76); one VoiceOver sentence with the state, the activity and the context (`⌛` and how long on one tool when a working session may be stuck, D69), folder, handle, menu; in its menu, for a local row in a repository, *Pin a decision…* and *Pinned decisions* (D105) |
| `DragHandle.swift` | 60 | the handle's grab area, an `NSView` so the drag moves the row and not the panel |
| `TrafficLightColumn.swift` | 538 | the column, the drag in progress, the hidden summary, the filter note; the ⚠'s sentence for a row, from the conflicts the panel found (D99) |
| `SessionSubRow.swift` | 198 | one conversation inside an opened block, and the grip that names its agent |
| `PanelNaming.swift` | 171 | opening a project, and the three levels of name |
| `PanelRootView.swift` | 549 | LampMaster first, above the rows — its row in the wide panel, its line in the narrow one (D97); the general menu, and the strip under the rows: width on the left, legend and menu on the right |
| `TrafficLightDot.swift` | 90 | the dot, the silenceable blink, and the ring for an open ear; solid, dashed when stuck, hollow without the mod, inside its own eleven points (D115) |
| `ContextRing.swift` | 77 | the second ring: the arc is the context spent, the letter is the model (D30) |
| `LegendView.swift` | 204 | what the six colours and the two rings mean, counted live (D31); the light's two shapes, and `--legend` opens it for a photograph (D115) |
| `LegendWindowController.swift` | 57 | owns the legend window |
| `Tooltip.swift` | 243 | the panel's own tooltips: AppKit's need a key window, and this one never is (D32) |
| `TooltipCard.swift` | 149 | draws a `RowSummary`: header, the label/value grid, the context bar, the keys |
| `Blinking.swift` | 39 | the blink as a view that exists only while it blinks |
| `UpdateFlow.swift` | 57 | the update from the menu entry to the app coming back: what was found, what failed, nothing silent |
| `PermissionRequest.swift` | 73 | explains a permission — use, cost of refusing, way back — then opens the pane that grants it |
| `StatusPalette.swift` | 417 | colors and measurements, and the dark appearance the panel is held in whatever the Mac is set to (D43) |
| `FloatingPanel.swift` | 122 | non-activating `NSPanel`; makes itself key before a click, drops the second click of a double-click; adopts one of the two homes |
| `PanelHomes.swift` | 364 | the two homes and the lamp that stands for the panel up there, the rescue when the menu bar had no room for it, and the list of every switch the menus offer |
| `MenuBarLamp.swift` | 239 | one `NSStatusItem`: the column's most urgent state as a drawn lamp, blinking only while something needs a person, and able to say whether it was drawn at all; with the counter switched on, `wanting · working` beside it |
| `MenuAction.swift` | 21 | an `NSMenuItem` target that runs a closure, because target/action is Objective-C dispatch and a Swift class silently answers nothing |
| `ChatWindowController.swift` | 123 | owns the one extended window; opened on request |
| `ChatShell.swift` | 230 | every conversation, the selection, and what each costs |
| `ChatShellView.swift` | 197 | the two columns, and one row of the list |
| `ChatSession.swift` | 324 | one conversation: transcript on disk + status from the hooks + the composer's state; a message goes into the session's own box when it has one (D81), off the main actor, pending until the conversation shows it, and through the mailbox otherwise, or when the box has gone since; a message unseen after a minute stops being on its way; whether the person has words in the composer, so a proposal that would not land is known |
| `ChatView.swift` | 323 | bubbles, activity lines, the composer, which takes LampMaster's proposed text, once, when it is empty; its header left to the Plancia, which draws its own (D98) |
| `MarkdownView.swift` | 157 | draws the blocks; inline markup goes to `AttributedString` |
| `DictationButton.swift` | 97 | the microphone, and the box that hides the macOS-26 seam |
| `AlertSettings.swift` | 56 | the menu bar counter and the notification for a finished turn, both off until asked for (5.6), and the bar's shortcut from any app, off until chosen (D77) |
| `SettingsView.swift` | 168 | the Settings form: LampMaster first, the companion mod, the menu bar and notifications, then remote machines, their state, the buttons; the "Show terminal sessions" switch |
| `SettingsWindowController.swift` | 59 | owns the Settings window; activates the app so it comes up in front |
| `LampMasterSettings.swift` | 114 | LampMaster's section: the switch with the sentence that says what it sends and spends, on screen before it is pressed (D60); the second switch, which lets every session ask it (D63); how often, which model, the kinds switched off — by the person or by themselves, with why (D95) — and "Suggest again", which restarts a kind's count |
| `ModSettings.swift` | 130 | the companion mod's switch, what it does said before it is pressed, the switch for permissions from the panel with its sentence above it (D73, D80), the band's switch with what it shows (D84), and on request Claude Code's own reading of the version this app carries (`claude plugin validate`), with the installed version when they differ and a refresh that failed at launch. Re-read every three seconds: Getting started, the command line or the launch refresh can change it while the window is open |
| `GettingStartedWindow.swift` | 169 | *Getting started*, opened after the hooks are installed and from both menus (`--getting-started` opens it at launch, for screenshots and for a Mac nobody is clicking). A window rather than a list in the panel, for the reason of D61; the ticks are read again every two seconds, because the Accessibility permission arrives from System Settings and not from a click here |
| `TourBand.swift` | 161 | the tutorial's band at the top of a trial panel, always there so a screenshot taken there never passes for real sessions: where the tour is, the step's sentence, Skip, Resume, Quit trial. `TourController` keeps the progress by step id in a domain of its own, because every trial starts on a fresh home; the panel's gestures move it on (D119). `show(stepId:)`, for `--tour-step`, puts it on one step and keeps nothing, so a photograph never replaces the person's own place. `tourRing` rings what the step speaks of — a row, the bar, the allowance, LampMaster, the panel's menu — breathing unless motion is reduced, never taking a click (D121). In a trial, opening a row only marks it seen: there is no editor behind an invented folder, and the warning that said so was modal and held off the trial's own quit |
| `LampMasterStrip.swift` | 122 | LampMaster above the rows, only while it is on, never blinking — advice is not a session waiting: in the wide panel a row with its star, name, what the last round found and the open count, a click opening its Plancia (D97); in the narrow one a line of fixed height. Both counted by `PanelMetrics.height` |
| `LampMasterPlancia.swift` | 213 | LampMaster's Plancia (D96, D97): the cards, Today, Frame and Cost, chosen at the top, read from its files each time they are drawn; `--lampmaster <sheet>` opens the Plancia on one |
| `LampMasterCardViews.swift` | 173 | the cards, in LampMaster's Plancia (D97; a window of their own until then, D61): the kind, the sentence, the evidence behind a disclosure, the sessions as buttons, the words a click would propose or ask, the action, *Ask without disturbing* with its answer in the card when the session's mod can answer (D85), *Ignore*, *Wrong*, *Don't suggest this kind*. what a card can ask the panel to do |
| `PanelHandoff.swift` | 50 | a handoff delivered (D91): into the session's Plancia composer, unsent, or copied where no composer can take it — gone, on another machine, sending off, the Plancia not open, the person's own words in it; and the mod's proven `/handoff <name>`, the name finding one session or asking for the exact one, nothing copied for a name that finds none |
| `PanelLampMaster.swift` | 135 | what a card does to the panel, by reusing what a row does — a question or a reply opens the Plancia with it in the composer, never sent (D85); the same raise, the same confirmation before ending a process, the same dismissal. A card can never do something a row could not |
| `Alerts.swift` | | dialogs |

> **`StatusPalette.timeColor`** is `Color.primary.opacity(0.62)` and not
> `.secondary`: over an `NSVisualEffectView` the weak semantic hues get
> attenuated a second time and disappear. The hierarchy comes from the font
> **weight**.

---

# The tests

## `LampBoardTests/` — 1190 cases

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
| `RemoteModScriptsSuite` | the mod put on another machine, run for real with `python3` on a temporary home and a `claude` that writes down its calls: every file and the three values owner-only, then `marketplace add` and `install` from a clean slate; a machine with a panel of its own left alone, even on the same port; its own files rewritten; a failed install taking the key back; a `~/.lampboard` others can write refused; a `~/.lampboard` that is a link refused; taken out with its three files |
| `RemotePeerScriptsSuite` | a message into a node session's box, run for real with `python3` against a Unix socket a listener holds: the key's line then the words, from `lampboard`; another session's id, a key others can read, a session file and key with no start time, a malformed id or nothing to send, refused and said |
| `SessionCardSuite` · `LampMasterSignalsSuite` | a transcript read into a card, a line cut between two reads, what counts as saved; every signal on both sides of its threshold |
| `LampMasterFrameSuite` · `LampMasterAdviceSuite` | who enters the frame and in what order, detail given up before sessions; evidence that is not in the frame never reaches the panel |
| `TourSuite` | the script holding nothing real and catching what would be, a beat as the hook's payload, the steps the trial can show, every sentence within the band's two lines, a step moving only on its own gesture, skip and resume |
| `RemoteTranscriptScriptSuite` | the paths asked for; the asks as base64, a path that is not a transcript's not sent; the answer only for what was asked and only when its numbers add up — no overflow, sign, fraction or boolean; whole lines only |
| `BackgroundSessionSuite` | `kind: bg` admitted and other non-interactive kinds not, an SDK entrypoint still out; named by its title, its second line saying background (D103); a job file read for its summary, its need while blocked and its id, an id unfit for a shell or read as an option refused, a bidi override flattened, the live file's `jobId` kept only when safe; the row's line from the job, a held question still first; the job attached to a background row only (AV2) |
| `UnreadAnswersSuite` | each answer nobody read adds one and a prompt starts again; looking clears it and *mark as unread* brings back one; a failed turn or one still waiting on work adds nothing; the row's `✉n` from two on, none on a row at work (R3c, D108) |
| `FocusSuite` | without a focus everything passes, with one only its session; what waits kept once per session and kind; the summary in one line, the most urgent first, nothing when nothing waited, and only what is still so (D110) |
| `AllowanceForecastSuite` | the last hour's pace and when the window runs out; nothing from one reading, five minutes or a flat line; a reset starting the history again; the sentence only before the reset (D111) |
| `GovernorSuite` | one step down by family and nowhere past Haiku; lowered until the reset and back after it or when taken off; the session in focus kept; the mod heard only proven, the model only signed; the file's round trip, expired entries dropped (D112) |
| `RadarSuite` | another live session's latest write of the file within two hours, never one's own, an old one or a closed session's; the sentence with a flattened name; the request proven for its session and file, the answer signed (D113) |
| `AwaySuite` | answers, failures and asks counted as they happen; the line on return with how long, the answers, what still waits, the failures and what it cost; nothing happened said as much; a session gone since still counted; under a minute not "0m" (D114) |
| `LampStyleSuite` | dashed while working and stuck on one tool, solid while working otherwise; hollow without the mod only when the mod is in use, the session has had two minutes, and it is on this machine (D115) |
| `HoldSuite` | away, a destructive command held with what it does, on any line and unmasked, a cut one unread; here or harmless, it goes; the request proven for its session, command and cut, the answer signed (D116) |
| `DecisionBoardSuite` | a decision pinned for its repository as one clean line and only there; empty, too long, repeated, past twenty or under a name no one could pin refused, the board unchanged; taken off by number; the version moving with the words and the repository; the block numbered, the withdrawal naming no repository; the file round trip; the command line's changes; the mod heard only with a proof for its own session; the answer signed over version and words, nothing for a session with no repository or a hostile name (D105) |
| `LampMasterChatSuite` | a follow-up carrying the last three exchanges, cut and fenced; the person named as the asker from the panel; the index's words by root and merged where two agree; no reuse for a follow-up; today's questions with who asked (D118) |
| `LampMasterSheetsSuite` | today's suggestions only, the newest first, with their outcome; the last frame read back with signals, precedents and the allowance; the day's rounds, spending, last runs and each kind's acceptance and state |
| `LampMasterBenchSuite` | a saved round read as frame and answer; kept, lost and new by key, a lost accepted card a regression and an ignored one gone a gain; the report with the regressions first |
| `LampMasterAutoMuteSuite` | under a fifth over two weeks off, with why; too few or too young not; what counts and what does not; a kind off left alone, one asked back counting from then |
| `LampMasterQuotaSuite` | the pace's forecast, none too early or without a reset; one line per account, the window most at risk; the round skipped when this Mac's account is tight, not another machine's or a model's own cap, and the line saying so |
| `LampMasterPrecedentsSuite` | a failure's names kept, the fingerprint's own taken out; another project or another day, never the session itself, the day's boundary; three at most, clean and clipped; in the round's frame, dropped first over budget, only for sessions kept, never in the digest; no search without words, four failures at most |
| `LampMasterMCPSuite` | the protocol line by line, `server/discover` refused without ending the conversation, each lookup on invented sessions, earlier conversations named without their words, no lookup carrying another session's words, sources quoted in full or dropped, the limits |
| `LampMasterQuickSuite` | the urgent pairs and only those, due only for a pair not yet seen, ten minutes and six a day, today's quick rounds counted, the pairs kept in a round and an old round still read, Sonnet |
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
| `CacheClockSuite` | an hour's or five minutes' cache read from the reply's usage, a read keeping the last write's lifetime, none when no write is in sight; the minutes left, none once cold; shown only where the person moves next; kept by a mod's measure and taken by a reported count (D100) |
| `ContextSuite` | the token sum; a refusal that must not read as 0%; the floor and the dash; the iterations fallback; a dated model id; an unknown model |
| `ModReportSuite` · `ModLedgerSuite` | the mod's reports read and bounded, a hostile id or word refused; the session's own count never replaced by the transcript's; the ledger's cost, windows and bound; a start's features, an answer's nonce and text, lines kept and cut to the bound, or its reason |
| `ModFilesSuite` | the carried mod equal to the repository's byte for byte; loopback only, nothing written or run, two model calls and both forks, the handoff's with its fixed question; a side question taken proven or not, answered with the key's proof, and the start saying `ask`; `/lampmaster` on the MCP tool's route and name, with nothing for the model; Claude Code's own install and removal steps; enabled, version and a declared marketplace read back; the band asking its route and opening through its own, never the answer route, the engine's own band when nothing waits, one clock per session stopped at its end; a question sent proven to `/question`, answered only with a signed choice, only in a shape a card shows; an edit's or a write's lines sent as counts, never text; the one note the mod leaves the model is the decision board, asked with the key, taken signed, once per change and only once its prompt entered, again after a compaction, never waiting long (D105) |
| `WaitingQueueSuite` | the order of urgency then age, the state the row shows when a subagent is alive, a second ask as a new card armed anew, armed from when the queue shows it, a new answer re-arming the group, an amber row with nothing said, stuck only after fifteen minutes, two ready answers alone and three as one, one LampMaster card counting the rest, a watched command that failed and not one that succeeded, armed at 600 ms, the keys and the ones not yet live, the selection kept on its card, resolved elsewhere |
| `WatchSuite` | the report read back as posted, the malformed ones refused (a folder with a bidi mark or a newline included); at most twenty rows; a running command never pruned; yellow, green, red with the code; an end without its start; terminal sessions hidden without hiding a command; no hook can claim the harness |
| `StuckSuite` | a tool's start and end read and its line made one printable line, secrets masked; an end before its start; a subagent's call and a call from an earlier turn left out; the ledger's running tools across a measure and the end; the cap; stuck at fifteen minutes and only while working; a turn that stops takes its tool with it |
| `SpokenAlertSuite` | said only when asked for, unlocked and a minute from the keys; the row's name in one plain line, cut, or "A session" (D117) |
| `NotificationTextSuite` | what a notification says for a wait, a failure and a finished turn, never the previous answer; the menu bar counter with its zeros |
| `LoopbackGuardSuite` | loopback hosts and no `Origin` pass; any `Origin`, a rebound or malformed `Host` refused |
| `ModAllowanceSuite` | the mod's windows over an older answer, kept from a newer one, alone when the service gave nothing, ignored when none can be drawn; only the default account's windows reach the strip |
| `ModTrustSuite` | the real `validate` output as four sentences; an unknown call shown as spelled; a valid but empty reading refused |
| `BandSuite` | what stops work, the most urgent first, three at most, answers to read left to the panel; never the asking session's own; one clean line each, cut with an ellipsis; a secret masked and a bidi override gone; only the kind for a node; the versioned wire |
| `IndexRecordsSuite` | the person's words and Claude's answers kept, context and tool calls not; the conversation's folder, title, first and last, prompts; a later chunk adding to an earlier; 4,000 characters at most; a search quoted word by word, the last a prefix |
| `WeekSummarySuite` | the last seven days counted per project and day, the week's first second in and the one before out, midnight across the change of hour, the busiest day by prompts before recency, two folders of one name kept apart, untitled conversations counted and not named, the paragraph, a quiet week, more than three titles and eight projects, a title or folder on its line; the time sessions waited on you, answer to next prompt, an absence over four hours left out; the week as tiles in order, none for an empty week (D109) |
| `HandoffSuite` | the mod's request read strictly and only when proven with the permission key, counted by code point; the mod asking the same question and registering `/handoff`; a name finding one session, the exact one alone, or saying it is not enough; `/handoff @from @to` naming both, the `@` optional; a hint half typed, never to itself or to no session; needing the mod and sending on and saying which; a session on another machine copied for, one there asked there; the question's size and parts, the brief's head |
| `CommandBarSuite` | the four kinds of query, names ranked exact, start, word, anywhere, then what a session says; empty listing what needs you; actions by their words and `/command` naming only actions; `@` naming only sessions, and with words after the name a send, saying how to switch it on while it is off; `?` to LampMaster or saying it is off; the selection kept in the list; the shortcut from anywhere off unless chosen and never `⌘K` alone ; `@name ?question` asked without disturbing only a session whose mod can answer; what was said found after what is open, a row's own conversation not repeated |
| `PermissionImpactSuite` | the destructive commands named by what they do, in many spellings, a secret's mask not hiding the next command; anything else said nothing about, `git restore --staged` and `git rm --cached` included; a command that goes on said so; an edit's and a write's counts, out-of-range counts refused; the card carrying it from the mod's ask and from a hook's; a warning drawn as one, a count not |
| `QuestionGateSuite` | a question read with its session, call, words and two to four distinct options, others refused; one clean line and short options; proven under its own prefix, a permission's proof refused; the signed choice; a question back to its dialog at 20 seconds and a permission at 55; a held question as a question card, a digit choosing, Allow not answering it |
| `PermissionGateSuite` | HMAC-SHA256 against RFC 4231; an ask genuine only with its key's proof for its call; the same call id from another session another ask; the signed answer; answers by session and call; an ask read with its session, call, tool and masked line; malformed ones refused; 55 seconds, then the dialog; an answer taken once; one ask per call, eight at most; the three verdicts |
| `PeerBoxSuite` | a side question as one provable line then the question, nothing empty or too long; the box, the session and its busy state read from a session file as 2.1.289 writes it; no box before 2.1.224, on a relative path or another protocol; the key file for that pid only, and its token only for that process; the two lines sent, nothing empty, nothing past 64 KB; the user's words read out of the envelope, and never from another sender |
| `PeerTranscriptSuite` | a message from the panel taken idle, and one taken mid-turn as a `queued_command`, shown as the user's; another session's, even with the preamble copied, a note |
| `FileConflictsSuite` | the same file of the same checkout, both live, within two hours, each naming the other; reading, an old write, a closed session, another checkout or a relative path not a conflict |
| `PlanciaHeaderSuite` | machine, surface and agent, model, context, cost in that order; what is not known left out; Claude's model ids read as names, anything else as it came |
| `PlanciaSuite` | the three depths cycled and stepped down, a session found by LampMaster's eight characters only when they name one, their widths, the Plancia closing by itself only with nothing waiting, the pointer away and no pin; a tool's duration, one still running, an end without a start; a turn's own cost; the mod's reports read into it; the newest sixty kept, a detail one short line |
| `RowActivitySuite` | the second line for every state: the ask, the reason, the tool and when it may be stuck, the answer's first line, what holds a blue row, the agent at rest, the machine of a remote row, `+N` for a project of several, a blank first line skipped; one line, cut, with no control or bidi character |
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

## `LampBoardE2E/` — 159 cases

| Suite | Covers |
|---|---|
| `TransportSuite` | **the socket via `lsof`**, token, methods, refusals; a POST with `Origin` and a rebound `Host` refused, through `curl` since URLSession will not send a Host of the caller's choosing |
| `WatchE2ESuite` | `lampboard watch` run for real: a failing command red with the command's own exit code and output, a succeeding one green with its own `--port`, `/watch` behind the token, the command left alone when no panel hears |
| `PidReuseE2ESuite` | a live `sleep` named by a session file with the wrong start makes no row, with its own start makes one |
| `LifecycleSuite` | the states walked over HTTP |
| `CoverageSuite` | integrated terminal, terminal rows outside every workspace, a background session a row of its own in a folder an editor claims (D103), a renamed row, a signal from another machine, subagents; a background session found on disk with no hook, carrying its job's summary, its need and its attach id, losing them when the job goes and keeping its row (AV2) |
| `ScaleSuite` | adoption, twenty-two sessions, dead process |
| `InstallationSuite` | `install-hooks`, **`hook.sh` actually executed**, both halves carry the token, an old Claude Code kept on the script, non-headless startup |
| `NodeTranscriptE2ESuite` | the node's program run with `python3` in a fake home: the tail first, then only what was added, a shrunk file read again, a link and a path out of the projects not read (D94) |
| `SearchE2ESuite` | `lampboard search` on a fake home's transcripts: a conversation found by its words and its name, by an unaccented word, never by a reminder; nothing found said; the index owner-only; `lampboard week` counting and naming this week's conversation, one ten days old left out, no prompt quoted |
| `PermissionE2ESuite` | a permission key of its own, not the token; an ask without the key's proof, or proven with the token, answered `ask`, unsigned; a new installation answering `ask` at once; `/check/answer` and the list behind the token; switched off, `ask` at once; a malformed ask `ask`; switched on, an ask listed by `GET /check`, waiting, not released by another session's answer, released by its own, signed, which counts once; a question waiting for a choice, answered signed, Allow refused for it |
| `ModE2ESuite` | `mod install`, a reinstall, a refused install that leaves nothing half in, and `uninstall-hooks`, through a fake `claude` that records its home; the carried files on disk; the port file written `0600`, `/mod` refusing a missing or wrong token and a body that is not a report, a measure landing on a hook's row as the session's own count without touching its colour, and making no row of its own; `/handoff` refusing a missing token, a `GET` and a proof made with the token, and taking one made with the permission key; the decision board pinned, listed and taken off from the command line, a port in its words kept, its file 0600; `/mod/decisions` answering a proven session with its repository's board, signed, nothing without the proof or with the token as key, no answer for a session it does not know, nothing pinned for one with no repository (D105) |
| `TrialE2ESuite` | the trial playing the script into the four states the reducer really produces, its Codex row still a Codex row after three sweeps, quitting it leaving no home and no process, `tour --json` printing a script that holds nothing real |
| `TokenLifecycleSuite` | reuse, regeneration, corrupted token, **the launch repair** in a home of its own, an installation under the previous name brought forward |
| `LampMasterE2ESuite` | `mcp install` registering through `claude`'s own command and `uninstall-hooks` taking it out; `lampboard mcp` started as Claude Code starts it, answering from the cards without the asker and behind the notice; `who_knows` naming a twenty-day-old conversation from the search index without its words; a question that keeps only the real source and costs nothing the second time; a round against a fake `claude` that writes down its standard input and arguments, a failure another project met before reaching its frame as a precedent from the index (D92), a kind passed over for two weeks switched off with why (D95), the bench replaying a saved round and naming what the new answer lost (D102): the frame on the pipe and never on the command line, the validator dropping an invented quote, the skip when nothing changed, the day's ceiling, the deadline, an answer outside the schema, switched off, the token; a failure repeated three times bringing a quick round with Sonnet at the turn's end, and a second turn's end within the minute bringing none |

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
Seven hooks, `session.start`, `session.measure`, `tool.call`, `tool.check`,
`session.receive`, `ui.render` and `session.end`, each passing the event on first and then posting to `/mod` on
`127.0.0.1` with the token — `tool.check` only for a real call the engine would
put to its dialog, asking `/check` with a nonce and its HMAC made with the permission key (never the key itself, and never the token),
and returning the panel's `allow` or `deny` only when the answer is signed back,
the engine's own `ask` otherwise (D80); an edit's or a write's lines counted from its input and sent as numbers (D87); on `AskUserQuestion` in `tool.call`, a question of one choice and two to four options put to `/question` the same way, answered only with a signed choice (D86);
`session.receive`, which takes a message that starts with the panel's side-question
line before the session sees it, whole or cut, proven or not, and only when proven answers it with
`$.model.fork` over the conversation and posts the answer once the port has said again that it is LampBoard (D82) — its one use of the
model, and the one time it reads the conversation; `ui.render` on the band above the prompt, asked of `/mod/band` every five seconds
from one clock per interactive session, stopped at its end, emptied when the panel stops answering, labels sharing the width, redrawn on change, a digit posting `/mod/band/open` — drawn on the screen, never in the conversation (D84);
and `/lampmaster <question>`, registered at the start, which posts the typed
question to `/lampmaster/tool` and prints the answer to the person only (D71); and
`/handoff <name>` (D91), which asks a fork over the conversation for the handoff —
its second and last use of the model — and posts it to `/handoff`, proven with the
permission key, once the port has said again that it is LampBoard. It reads
the home (`HOME`, absolute only — never `LAMPBOARD_HOME`, which a project's settings
can set, D80), the token, the port and the permission key, and nothing else; it sends nothing until that port answers `/health` as LampBoard, since
a project's settings can set environment variables for its sessions and a cloned
repository could point the mod at a port of its choosing:
no conversation but for a proven side question, no file of the project, no command. When the panel is not there,
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
| `Scripts/make-screenshots.sh` | the README's images, taken from the tutorial's trial: the real app on a temporary home playing `DemoScript`, the one place demo data lives (D64), with `--trial-fresh` so the band always shows step one and nobody's progress moves; `screencapture -l` reads the window's backing store, which works with the screen locked. `LAMPBOARD_BIN` points it at a build other than the bundle. The widest **visible** window of the process: a text field leaves a hidden, wider one behind |
| `Scripts/make-cask.sh` | renders the Homebrew cask from a **published** release, taking the checksum from the asset GitHub serves rather than from `dist/` |
| `Scripts/release.sh` | disk image into `dist/`, twice — under the version and under the version-free name the `latest` address serves; signs, notarizes and staples when the keychain allows it, and says which of the three outcomes it reached |
| `Scripts/release-remote.sh` | the release cut on the Mac that signs, from any machine that reaches it (D106): the tag to the mirror, `release.sh` run over ssh with that account's own keychain, the four files brought back into `dist/` |
| `Scripts/check-mod.sh` | the companion mod as Claude Code reads it, through `claude plugin validate`: a module that breaks one rule is dropped whole and silently from every session (D112); part of `test.sh`, attacked by `bite.sh` |
| `Scripts/make-pkg.sh` | the installer package a fleet manager deploys, wrapped around the bundle `release.sh` already stapled: a disk image has no version field and an MDM needs one to read. Refuses to produce an unsigned package, and needs a Developer ID **Installer** certificate, which is not the one that signs the app |
| `Scripts/test.sh` | both suites, then the documentation check |
| `Scripts/run-remote.sh` | the same gate on the test Mac: pushes the branch to a bare repository there, runs `test.sh` in a worktree of its own under a lock and a time limit; where that Mac is lives in the git-ignored `.env.machines` |
| `Scripts/check-contract.sh` | the assumptions about Claude Code, static or `--live`; `--record` re-records the golden baseline |
| `Scripts/smoke-clicks.sh` | does a click still land where the row promises. `--live` raises windows and asks the window server who came forward; without it, recognition only and nothing moves. Writes `docs/smoke-clicks.md` |
| `Scripts/check-docs.sh` | the figures, links, event counts and suite registrations the docs state, and the WORKLOG's status table against the repository |
| `Scripts/bite.sh` | commits twenty-eight violations and demands twenty-eight catches; a gate nobody has seen fail has not been distinguished from a broken one |
| `Scripts/measure-compaction.py` | every auto-compaction in the transcripts, and the value our own reading had reached at each — the measurement that settles the context denominator |
