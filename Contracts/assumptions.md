# The assumptions

lampboard depends on things nobody promised. This file names every one of them,
says **where the code leans on it** and **what breaks when it goes away**.

It exists so that "Claude Code updated and something is off" becomes a ten-minute
repair instead of a rediscovery. `Scripts/check-contract.sh` mechanizes the part
that can be mechanised; this file carries the part that can't — the *why*, and the
arrow back into the code.

**First worked out against Claude Code 2.1.220 / extension 2.1.220-darwin-arm64
on 2026-07-31; last re-verified by `check-contract.sh` against 2.1.251 on
2026-08-31** (the recorded version is in `required-fields.json`).

How to read a record:

- **How verified** — `probe` means a real session was recorded and the field
  observed; `binary` means read out of the shipped code; `runtime` means watched
  working on this machine. Nothing here says "documented", because none of it is.
- **Failure mode** — what you would actually see. This matters more than the
  assumption: the ones that fail *loudly* are cheap, the ones that fail *silently*
  are what this file is for.

---

## hook.events · ten of the thirty-one, and the reasons for the other twenty-one

**We assume** `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`,
`StopFailure`, `SessionEnd`, `SubagentStart`, `SubagentStop`, `PostToolUse`,
`PostToolUseFailure` are delivered to a registered hook.

**Depends at** [HookConfigMerger.swift:21](../Sources/LampBoardCore/Setup/HookConfigMerger.swift#L21) ·
[StateReducer.swift](../Sources/LampBoardCore/Reducer/StateReducer.swift)

**How verified** — `probe`. Eight of the ten recorded live; `Notification` and
`StopFailure` need conditions a probe can't force cheaply and stay on recorded
shapes under unit test. The checker says so instead of passing silently.

**This record used to be titled "the eight events fire"**, which reads as *these
are the events*. **There are thirty-one.** The full list, and the class each one
falls into, is in `required-fields.json` under `hookEventInventory`, and
`check-contract.sh` now verifies it against the binary on every run: an event we
register disappearing is a failure, a new event appearing is a note asking for it
to be classified. Before that, neither would have been reported by anything.

Twenty-one of the twenty-two we do not use fall into three groups; the twenty-second, `PreToolUse`, is treated on its own below., and the difference between
them is the difference between **measured** and **read**:

- **Decision hooks** — `PermissionRequest`, `PermissionDenied`, `Elicitation`,
  `ElicitationResult`. These do not observe, they answer: the output schema in
  the binary carries a verdict (`decision.behavior` = `allow` | `deny`;
  `action` = `accept` | `decline` | `cancel`). Registering one puts this app's
  hook script inside the approval path, which changes what a bug in it can cost —
  from *a light that lags* to *a tool call approved without the user seeing it*.
  The schema is measured; **the firing is not**, because a non-interactive
  `claude -p` never reaches an approval prompt. See
  [D20](../docs/04-decisions.md#d20--the-traffic-light-does-not-answer-questions).

- **The teammate board** — `TeammateIdle`, `TaskCreated`, `TaskCompleted`.
  **Measured, and not what the names suggest.** The payload is `task_id`,
  `task_subject`, `task_description`, `teammate_name`, `team_name`: the
  teammates/team task board, with nothing to do with background shells. A probe
  running a real backgrounded `sleep 6` produced neither of them.

- **Not about turn state** — `PostToolBatch`,
  `UserPromptExpansion`, `PreCompact`, `PostCompact`, `Setup`, `ConfigChange`,
  `WorktreeCreate`, `WorktreeRemove`, `InstructionsLoaded`, `CwdChanged`,
  `FileChanged`, `DirectoryAdded`, `MessageDisplay`. Workspace and editor facts.
  Read in the binary, never probed — so this group is a hypothesis, and it is
  labeled as one.

`PostToolUse` **is** registered, and it was not always. It costs a spawn per tool
call, which is why it was left out on the reasoning that it "adds nothing
`UserPromptSubmit` and `Stop` do not already bracket". That reasoning was wrong in
one specific way: it is the only registered event that can fire between a mid-turn
`Notification` and the closing `Stop`, and therefore the only one that can prove a
permission prompt was answered. Without it an amber row kept flashing for
thirty-three measured minutes at somebody who had already replied.

`PostToolUseFailure` **was in that last group, and the group was wrong.** It sat
under "not about turn state" as a hypothesis read in the binary and never probed,
which is exactly what that label is for. Probed on 20 September 2026 it turned out
to be load-bearing: Claude Code emits `PostToolUse` **or** this one, never both. A
permitted `Bash` exiting non-zero produced `PostToolUseFailure` and no
`PostToolUse` — so the one registered event that can prove a permission was
answered was silent in precisely the case where the tool was allowed and then
failed, and the amber survived the answer that should have cleared it. It is
registered, and the reducer treats the two identically.

`PostToolBatch` was probed in the same pass and is deliberately **not** registered,
which is a stronger statement than leaving it unexamined. It fires once per block
of tool calls in one assistant message: five parallel `Read`s produced one, five
sequential ones produced five, so the saving it offers exists only where there is
parallelism — and since the hooks became native `http` posts an event no longer
costs a process, which was the only reason to count them. Worse, it fires **even
when every tool in the batch was blocked and none ran**, measured: two denied tools
produced two `PreToolUse`, no `PostToolUse`, no `PostToolUseFailure`, and one
`PostToolBatch`. So it cannot carry the proof this app needs from that position —
it would release an amber that was never answered.

`PreToolUse` stays apart: decoded, so it maps to `working` if it ever arrives, but
not registered. It cannot do that job — it carries `permissionDecision` in its own
output schema, so it runs *inside* the permission decision and therefore **before**
the prompt.

**Failure mode** — **silent**. An event that stops firing doesn't error; the row
just stops moving. This is the assumption the live probe exists for.

---

## hook.payload.core · every payload carries session_id, hook_event_name, cwd

**Depends at** [HookPayloadDecoder.swift:66](../Sources/LampBoardCore/Parsing/HookPayloadDecoder.swift#L66)

**How verified** — `probe`.

**Failure mode** — **loud**. The decoder rejects the payload and the server
answers 400. You would see it in the panel's error note.

---

## hook.stop.message · Stop carries last_assistant_message

**Depends at** [HookPayloadDecoder.swift:86](../Sources/LampBoardCore/Parsing/HookPayloadDecoder.swift#L86)

**How verified** — `probe`. Recorded as `"pong"` from a session asked to reply
with exactly that.

**Failure mode** — quiet but harmless: the row tooltip loses its preview. Nothing
else depends on it.

---

## hook.subagent.shape · SubagentStart/Stop carry agent_id and agent_type

**Depends at** [HookSignal.swift:23](../Sources/LampBoardCore/Models/HookSignal.swift#L23) ·
[SessionState.swift:129](../Sources/LampBoardCore/Models/SessionState.swift#L129)

**How verified** — `probe`. A session was made to launch one general-purpose
agent; both events recorded, with `agent_id`, `agent_type`, and on the stop also
`agent_transcript_path` and `last_assistant_message`.

**Failure mode** — **silent, and the worst one**. The whole derived-state design
rests here: without these two events the counter never moves, `Stop` is taken
literally, and a session with agents working in the background shows **green** —
"there is an answer to read" — for as long as the work lasts. That is the most
expensive lie the column can tell.

---

## hook.subagent.ordering · Stop can arrive before SubagentStop

**We assume** the parent turn can return control while its agents keep working.

**Depends at** [SessionState.swift:129](../Sources/LampBoardCore/Models/SessionState.swift#L129)
— the reason `status` is computed rather than stored.

**How verified** — `runtime`, on real background workflows. The probe records the
*foreground* ordering (`SubagentStart → SubagentStop → Stop`), which is the other
case and does not contradict it.

**Failure mode** — if this stopped being true, nothing breaks: the derived state
degrades to the stored one. This assumption only costs us if it is *forgotten*,
not if it changes.

---

## hook.sessionstart.source · SessionStart carries source, and `compact` fires mid-turn

**Depends at** [StateReducer.swift:250](../Sources/LampBoardCore/Reducer/StateReducer.swift#L250)

**How verified** — `probe` for the field (`source: startup`); `binary` for the
`compact` value.

**Failure mode** — **silent**. If `source` disappeared, a context compaction would
be read as a session start and would clear the yellow of a working session, sinking
it to the bottom of the column.

---

## entrypoint.transport · the entrypoint is NOT in the payload

**We assume** `CLAUDE_CODE_ENTRYPOINT` exists only in the environment, which is why
the hook script copies it into a header.

**Depends at** [HookScriptBuilder.swift:28](../Sources/LampBoardCore/Setup/HookScriptBuilder.swift#L28)

**How verified** — `probe`. No recorded payload contains it.

**Failure mode** — quiet: the filter loses its input and every session is admitted.
A deny-list that admits too much shows rows, it doesn't hide them.

---

## entrypoint.values · the non-interactive values

**We assume** `sdk`, `sdk-cli`, `sdk-ts`, `sdk-py`, `print` are sessions nobody is
watching, and everything else deserves a row.

**Depends at** [AppConfig.swift:175](../Sources/LampBoardCore/Config/AppConfig.swift#L175)

**How verified** — `probe` + `binary`. **This record is the reason the harness
exists.** The list had been written from the documentation and was missing
`sdk-cli`, which is what `claude -p` really reports. The first live run found it.

Two things learned in the same minute:

- `CLAUDE_CODE_ENTRYPOINT` is **inherited by child processes**. A probe launched
  from inside a Claude Code session records the *parent's* value and proves
  nothing. The harness scrubs the variable; the first recording, before it did,
  claimed `claude -p` reports `claude-vscode`.
- The binary contains nine values: `print`, `sdk`, `cli`, `vscode`, `jetbrains`,
  `claude-vscode`, `sdk-ts`, `sdk-cli`, `sdk-py`. `cli` is deliberately admitted —
  that is `claude` from VS Code's integrated terminal, decision D3.

**Failure mode** — one row too many. By design: this is exactly why the list is a
deny-list and not an allow-list.

---

## sessions.file · ~/.claude/sessions/&lt;pid&gt;.json exists, named after the PID

**We assume** one file per live process, whose name is the PID, containing
`sessionId`, `cwd`, `kind`, `entrypoint`; and that the files survive the process,
so liveness needs `kill(pid, 0)`.

**Depends at** [LiveSession.swift:82](../Sources/LampBoardCore/Workspace/LiveSession.swift#L82) ·
[LiveSessionReader.swift:58](../Sources/LampBoardApp/Runtime/LiveSessionReader.swift#L58)

**How verified** — `runtime`, continuously: it is one of the two sources the column
is built from.

**Failure mode** — **silent and slow**. Without this source the hooks alone never
report what disappeared: closing a Claude panel leaves a clickable row pointing
nowhere, and the column starts empty at every launch.

---

## ide.lock · ~/.claude/ide/&lt;port&gt;.lock maps a folder to a window

**We assume** one lock per connected window, carrying `workspaceFolders`,
`ideName` and `pid`; that `ideName` is `vscode.env.appName` (so forks write their
own); that `pid` is the **editor's** process and therefore does not identify a
window on its own — every window of one VS Code shares it; and that the file is
written **once**, when the window connects, and never touched again.

**Depends at** [IDEWindow.swift:43](../Sources/LampBoardCore/Workspace/IDEWindow.swift#L43)
· [IDEWindowReader.swift:29](../Sources/LampBoardApp/Runtime/IDEWindowReader.swift#L29)

**How verified** — `runtime`. The write-once property was measured the hard way:
locks 7.98 days old belonging to a VS Code that had been running continuously.

**That last property is the load-bearing one.** A lock's age says how long the
window has been open, not whether it is still there — and windows stay open for
weeks. Believing a lock only while it was young made five projects disappear from
the column on their eighth day, silently. Liveness is `kill(pid, 0)`; age is only
the fallback for a lock with no usable pid, which is the orphan case the rule was
invented for. See [Traps](../docs/07-traps.md).

**Failure mode** — **silent**. No lock matching a `cwd` means the session's hooks
are discarded and no row appears. The drop is now logged by name, which is the
difference between reading a line and bisecting the app.

---

## sessions.file.mtime · the session file's timestamp is frozen at startup

**We assume** `~/.claude/sessions/<pid>.json` is written when the session starts
and **never rewritten**, so its modification time is not a sign of activity.

**Depends at** [LiveSessionReader.swift:52](../Sources/LampBoardApp/Runtime/LiveSessionReader.swift#L52)
— which is why activity is read from the transcript instead.

**How verified** — `runtime`, by measuring both at once on a session that was
working: transcript **1.3 minutes** old, session file **173.6 hours**.

**Failure mode** — **silent, and it hides sessions**. Taking this file's age as
"time since last activity" makes every long-lived session look stale, and the
twelve-hour rule then removes it while it is working.

**If this ever changes** — if Claude Code starts touching the file on activity —
nothing breaks: the reader takes the **later** of the two timestamps.

---

## extension.deeplink · vscode://Anthropic.claude-code/open reads session

**Depends at** [SessionDeepLink.swift:26](../Sources/LampBoardCore/Workspace/SessionDeepLink.swift#L26)

**How verified** — `binary`, in `extension.js`.

**Failure mode** — quiet, and already handled: the deep link is a bonus on top of
raising the window, never a replacement, and it ships **off by default**. If it
breaks, the click still takes you to the right window.

---

## extension.prompt · a prompt cannot be sent to an already-open session

**We assume** the `prompt` parameter is applied **only when a new panel is
created**. When a panel for that session already exists, the extension refuses and
tells the user so.

**How verified** — `binary`. The refusal is a user-facing string in the shipped
code:

> `"Session is already open. Your prompt was not applied — enter it manually."`

**Why this record exists** — it is the answer to "can lampboard send a command to
a running agent", and the answer is no, through this channel. The one case where
it would be useful — a session that is open and waiting — is exactly the case the
extension refuses. See decision N7.

**Failure mode** — none: we depend on nothing here. This record is tracked in
`required-fields.json` under `extensionOpportunities`, where the **disappearance**
of the refusal is reported as an opening rather than a breakage.

---

## extension.newconversation · a new conversation opens, and a prompt only prefills

**We assume** `/open` **without** a `session` parameter creates a fresh Claude tab,
and that a `prompt` given alongside it is **prefilled into the composer, not
submitted**.

**Depends at** [SessionDeepLink.swift](../Sources/LampBoardCore/Workspace/SessionDeepLink.swift)
— the new-conversation URL, reached from the row menu and from `lampboard new`.

**How verified** — `binary`, followed all the way through the extension:

```
URI /open → primaryEditor.open → createPanel(session, prompt)
          → setupPanel(panel, session, prompt)
          → getHtmlForWebview(…, prompt, …)     → <div id="root" data-initial-prompt="…">
          → webview: initialPrompt → setInputText(…)   ← prefills, does not send
```

**Why this record exists** — it settles the second half of the N7 question. The
prompt channel is not merely restricted to new conversations; even there it only
puts text in the box. A key that opens a tab with text you must then confirm is
not a command key, which is why `lampboard new` sends no prompt at all.

**Failure mode** — none in the direction that matters. If a future version started
*submitting* the prompt, an unchanged lampboard would keep opening empty
conversations, which is the same behavior it has today.

---

## transcript.usage · A reply records what the context held

**We assume** every `assistant` record in a transcript carries
`message.usage` with `input_tokens`, `cache_creation_input_tokens` and
`cache_read_input_tokens`, that their sum is the context at that moment, and
that `message.model` names the model that produced it.

**Depends at** [ContextScanner.swift](../Sources/LampBoardCore/Transcript/ContextScanner.swift)
· [ContextReading.swift](../Sources/LampBoardCore/Transcript/ContextReading.swift)

**How verified** — `probe`. A `statusLine` command was configured in a throwaway
project and its stdin captured: for a live session it reported
`context_window.total_input_tokens` equal to that sum, and
`context_window.context_window_size` equal to the model's window. Claude Code
computes the same number the same way, which is the only reason this is a
reading and not an estimate.

**Failure mode** — if the field names moved, the panel would show a dash for
every row. Visible, and the safe direction: the figure disappears rather than
becoming wrong.

---

## model.contextWindow · The window is a property of the model

**We assume** each model id maps to a fixed context window, recorded under
`modelContextWindows` and re-read from the installed binary on every run of
`check-contract.sh`.

**Depends at** [ContextWindows](../Sources/LampBoardCore/Transcript/ContextReading.swift)
· [required-fields.json](required-fields.json)

**How verified** — `binary`, on 2.1.268: eighteen models in Claude Code's own
registry, each with a `window:`. Sixteen are recorded here; the other two,
`claude-fable-5-1` and `claude-mythos-5-1`, are point releases that inherit their
parent's window, and the check confirms the number they inherit is the number the
binary carries rather than merely noting they are absent. A point release that
moved its window would otherwise be divided by its parent's, confidently, for
everybody — the same failure this section exists for, one generation down.

And by contradiction: a session started with `--model sonnet`, with **no** `[1m]`
suffix anywhere, reported a window of 1,000,000 — so the suffix is not the
discriminator and the model id is.

**Failure mode** — a release changes a window and nothing else changes. The
panel would divide by the old number with full confidence, which is why this is
a contract with a check rather than a constant in the source. A model the table
does not know gets no percentage, never a guessed one.

**Not covered** — `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`,
`CLAUDE_CODE_DISABLE_1M_CONTEXT`, `DISABLE_COMPACT` and the `autoCompactWindow`
setting can move the real ceiling with nothing on disk to record it per session.
All unset on this machine when this was written; undetectable the day one is set.

---

## context.ceiling · the window is the ceiling, the compaction trigger is not ours

**We assume** a session's saturation is `input + cache_creation + cache_read`
over the **whole** window of its model — not over Claude Code's auto-compaction
threshold, which is a different quantity measured on a different numerator.

**Depends at** [ContextReading.percent](../Sources/LampBoardCore/Transcript/ContextReading.swift)
· [measure-compaction.py](../Scripts/measure-compaction.py)

**How verified** — `transcripts`, and this one earned its own script. Claude Code
computes its threshold as `window − min(maxOutputTokens, 20 000) − 13 000`
(readable in the binary: `iSe → W3(eF(…))`) and counts down to it — but against
**its own** token estimate, which is not this sum. On the same compaction the two
have been seen 0.4% apart (966,032 against 973,029) and sixty-fold apart.

So the question was put to the files instead: at what value of *our* sum does a
session actually get compacted? Every `compact_boundary` carrying
`trigger: "auto"` in 18,622 transcripts — 236 of them — with the last reply
before it as the reading at that moment:

| window | n | highest reading | past 90% | above 100% |
|---|---|---|---|---|
| 1,000,000 | 20 | 99.91% | 10 | 0 |
| 200,000 | 216 | 99.99% | 79 | 0 |

**Failure mode** — a denominator below the window prints figures above 100% and
tells somebody a session is fuller than it is. Set the table to 0.92 × window,
the ratio three hand-readings of the indicator agreed on, and this measurement
answers `108.6%` twice within a second. That is the check, and it is the reason
0.92 is not in this repository.

**Not covered** — the direction the other way. Our reading is a floor: whatever
was loaded after the last reply is invisible, so the envelope approaches the
ceiling from below and never touches it. This proves the denominator is not too
small; it cannot prove it is not slightly too large.

---

## hook.background_tasks · Stop reports the work still in flight

**We assume** `Stop` carries `background_tasks`, a list of the background work
still in flight at the end of the turn, **already filtered** by Claude Code to the
things the session is waiting on.

**Depends at** [HookPayloadDecoder.swift:135](../Sources/LampBoardCore/Parsing/HookPayloadDecoder.swift#L135)
· [StateReducer.swift:259](../Sources/LampBoardCore/Reducer/StateReducer.swift#L259)

**How verified** — `probe`, then `binary`. A session told to run `sleep 45` in the
background produced, on `Stop`:

```json
[{"id":"befqfrl0r","type":"shell","status":"running",
  "description":"Sleep for 45 seconds","command":"sleep 45"}]
```

The builder in the CLI binary settles the rest of the shape:

```js
function <builder>(e){let t=[];for(let r of Object.values(e)){if(!<filter>(r))continue;
  let n={id:r.id,type:<map>[r.type]??r.type,status:r.status,description:…};…}}
function <filter>(e){if(e.status!=="running"&&e.status!=="pending")return!1;
  if("isBackgrounded"in e&&e.isBackgrounded===!1)return!1;return!0}
```

Four facts follow, and three of them contradict what this record used to say.

**`id` is unconditional.** Every entry has `id`, `type`, `status`, `description`;
`command`, `agent_type`, `server`, `tool` and `name` are added per type.

**The list is filtered before it is sent.** Only `running` or `pending`, and only
if backgrounded. So "finished tasks stay in the list", asserted here and in a test,
was **false** — and defending against them is what dropped the `pending` ones.

**It is not a list of shells.** Ten types map into it: `local_bash`→`shell`,
`local_agent`→`subagent`, `local_workflow`→`workflow`, `monitor_mcp`/`monitor_ws`
→`monitor`, `mcp_task`→`MCP task`, `in_process_teammate`→`teammate`,
`remote_agent`→`cloud session`, `dream`, `auto_mode_scan`.

**The status vocabulary** is `pending, running, completed, failed, killed, paused`.

Claude Code's own description of the field is the definition we use: it exists so a
hook can tell *"session is done"* from *"session is paused waiting for background
work to wake it"*, and is *"empty when nothing is in flight"*. Presence in the list
is the signal, not the status word — **minus two types**. The decoder still drops
the three terminal statuses, as the one defense that stays useful if the upstream
filter ever loosens.

**The two types, and why they are Claude Code's exclusion and not ours.** Its own
"active tasks" view, read in the binary, starts from the very predicate that builds
this payload and then removes exactly two:

```js
Object.values(e).filter(bL).filter((t)=>t.type!=="remote_agent"&&t.type!=="dream")
```

`dream` is its background memory consolidation: it starts on an idle session,
writes nothing to the transcript (`skipTranscript: true`), and does not wake the
session when it ends. A hook payload lists it; the user never sees it. Counting it
as work held a row yellow for a day — thirteen of sixteen turns in one session
stayed `working -> working`, with no background shell ever launched and the
transcript silent from one second after `Stop`. The payload carries display names,
so the exclusion is `dream` and `cloud session`. Anything else, including a type
we have never seen, still counts as work: guessing "busy" costs a blue `waiting` row (D22) that clears on the next clean
turn, guessing "done" costs the lie the field exists to
prevent.

Green returns on its own: the work finishes, wakes the session, and that turn ends
with an empty list — so there is no counter to get stuck, which the subagent design
needed a safety net for.

**No exemption is applied here** for work that never ends, of the kind tmux gives
itself with `JOB_NOWAIT` for jobs the server must not wait for before exiting. The
equivalent already exists upstream — `isBackgrounded === false` is dropped before
we see it — and a second valve on this side would mean guessing which of the
remaining entries really count.

**Failure mode** — **silent, and it already happened once, in the expensive
direction**. Counting only `running` put the light green in front of queued work.
If the field disappeared entirely, every turn would look clean and the
green-during-work lie comes straight back.

**Not read** — `session_crons`, alongside it: the `CronCreate`, `ScheduleWakeup`
and `/loop` tasks that will wake this session later. A session sleeping between
loop iterations has an answer to read and is not working, so it stays green.

## hook.effort · Stop reports the reasoning level, and it cannot be set from outside

**We assume** `effort.level` arrives on `Stop`, and that changing it requires
either `claude --effort <level>` at session start or `/effort` typed into the
session.

**Depends at** — nothing.

**How verified** — `probe` for the field (`{'level': 'high'}`); `binary` and
`claude --help` for the two ways to set it.

**Why it is recorded** — it is the Codex Micro's rotary dial. The dial's value is
changing effort **mid-flight**, and that needs text delivered to a running
session, which N7 rules out. We can read the level and never write it, so the
feature reduces to a badge nobody asked for.

---

## transcript.path · every payload carries transcript_path, and it is absolute

**We assume** each hook payload carries `transcript_path`, pointing at the
session's JSONL transcript.

**Depends at** [HookPayloadDecoder.swift:88](../Sources/LampBoardCore/Parsing/HookPayloadDecoder.swift#L88)

**How verified** — `probe`. Present on all 12 invocations in the golden recording,
across all 8 event types.

**Failure mode** — **silent, and it degrades rather than breaks**: without the
path the chat window falls back to `transcript.location`, and if that fails too it
says it has no transcript. The traffic light is untouched. This is deliberate —
the column is the product, the chat window is a feature.

---

## transcript.human · origin.kind == "human" is the only proof of who spoke

**We assume** a transcript record was typed by a person **if and only if** it
carries `origin: {"kind": "human"}`.

**Depends at** [TranscriptDecoder.swift:63](../Sources/LampBoardCore/Transcript/TranscriptDecoder.swift#L63)

**How verified** — `runtime`, at scale: 7042 transcripts scanned. `origin.kind`
takes three shapes — `human`, `task-notification`, absent.

**Why nothing else will do** — a record of type `user` is usually not a message.
The protocol files tool results, hook context and injected reminders under the
same role. The tempting shortcut ("no `toolUseResult`, therefore a person") was
measured across 60 recent transcripts: it promotes **579** records against **209**
real ones. Nearly three fabricated user messages for every genuine one.

**Failure mode** — **silent and bad**: if the field is renamed, every conversation
goes empty; if its meaning shifts, the window starts attributing machine output to
the user, and there is nothing on screen to suggest it is lying. The static check
fails when no human record is found in 40 transcripts, which is the loud version
of the first case and the best available proxy for the second.

---

## transcript.location · the transcript path is derivable from cwd and session id

**We assume** a session's transcript lives at
`~/.claude/projects/<cwd, every non-alphanumeric character replaced by "-">/<session-id>.jsonl`.

**Depends at** [TranscriptLocator.swift:35](../Sources/LampBoardCore/Transcript/TranscriptLocator.swift#L35)

**How verified** — `runtime`: **7065 of 7066** transcripts on the machine matched.

**Why it exists** — sessions adopted from `~/.claude/sessions/` carry no
transcript path, and after a restart of lampboard that is every session. Without
this the chat window would stay empty until the next prompt.

**The one exception, and why it is handled** — a session running in a git worktree
reports the **main** repository as its `cwd` while the transcript is filed under
the worktree. The derived path is therefore a *candidate*: the caller checks it
exists and otherwise reports no transcript. Trusting it blindly would show an
empty conversation for a session that has plenty to say.

**Failure mode** — **quiet**: a changed rule means adopted sessions stop opening,
while sessions with a live hook keep working. Not covered by the static check —
it is a naming convention, not a field, and the file-exists check is what makes
being wrong harmless.

---

## transcript.blocks · content is a list of typed blocks

**We assume** `message.content` is either a string or a list of blocks, and that
`text` / `tool_use` on the assistant side and `text` / `tool_result` / `image` /
`document` on the user side cover what needs rendering.

**Depends at** [TranscriptDecoder.swift:151](../Sources/LampBoardCore/Transcript/TranscriptDecoder.swift#L151)

**How verified** — `runtime`, 40 transcripts sampled by the static check on every
run. New block types are **reported, not failed**: an unknown block is skipped (only `image` and `document` draw a placeholder), so
a new type shows as a gap until it is handled — and the check names it.

**Failure mode** — **visible**: a new content type shows up as a gap in a bubble.
The check names it on the next run.

---

## rewake.mechanism · a Stop hook with asyncRewake outlives the turn, and exit 2 sends

**We assume** that a `Stop` hook carrying `"asyncRewake": true` is spawned
**detached**, survives the turn that launched it, and that when it later exits
with code **2** its stdout is enqueued as the session's next turn. The message
arrives wrapped in `<task-notification>` with `rewakeMessage` as its preamble.

**Depends at** [RewakeScriptBuilder.swift:60](../Sources/LampBoardCore/Setup/RewakeScriptBuilder.swift#L60)
· [HookConfigMerger.swift:180](../Sources/LampBoardCore/Setup/HookConfigMerger.swift#L180)

**How verified** — `runtime`, by reproduction on 2026-08-01. Three times, twice
through the shipped scripts: a session idle for thirty seconds, a message written
by an unrelated process, and one second later a `queue-operation enqueue`, a
`user` record with `origin.kind == "task-notification"`, a tool call and an
answer. The recorded envelope is in `golden/delivered-message.json`.

Also `binary`: the option names and the delivery path are grepped out of the
shipped CLI on every contract run.

**The names are `@internal`** — Claude Code owes us no deprecation for them.

**Failure mode** — **silent, and total**. Nothing errors. The composer accepts
your message, the file is written, and no listener ever comes to collect it. This
is the worst failure shape in the project, and it is why the check greps the
binary rather than trusting the version number.

**What it is NOT** — a way to wake a dormant session. A listener can only be born
at the end of a turn, so a session doing nothing arms nothing. The window reports
that state rather than spinning.

---

## rewake.envelope · a delivered message returns as a task-notification

**We assume** a message we delivered comes back in the transcript as a `user`
record with `origin.kind == "task-notification"`, its `message.content` a **bare
string** containing our `rewakeMessage` preamble followed by the text.

**Depends at** [TranscriptDecoder.swift:75](../Sources/LampBoardCore/Transcript/TranscriptDecoder.swift#L75)

**How verified** — `runtime`, recorded verbatim in `golden/delivered-message.json`
and asserted by `DeliveredMessageSuite`.

**Why the preamble is load-bearing twice** — it is what makes the model treat the
message as the user's turn rather than as an injection (instruction-shaped
phrasing was refused eight times out of eight during the investigation), **and**
it is the only thing that tells our own messages apart from a background agent
reporting in on the way back.

**Failure mode** — **visible but wrong**: if the envelope changes, your own
messages start appearing in the conversation as system notes. Nothing breaks; the
window just stops giving you credit for what you wrote.

**A trap already sprung** — the first version of the tests invented a
`content` shaped as a list of blocks. It passed happily against a shape Claude
Code does not produce. Fixtures for this record come from the recording, not from
imagination.

---

## presence.file · CLAUDE_CLIENT_PRESENCE_FILE suppresses phone push notifications

**Depends at** [PresenceFile.swift:23](../Sources/LampBoardApp/Runtime/PresenceFile.swift#L23)

**How verified** — `binary` only. **Never verified at runtime**, and the feature
ships off by default partly for that reason. Inspection also turned up a
`/client/presence` endpoint and a `[presence] pulse` heartbeat, which suggests the
file is one signal among several rather than the mechanism.

**Failure mode** — **silent, and the bad direction**: if the file stops being read,
nothing tells you; if the detection is wrong, the result is not one notification
too many but a notification **lost**, and lost notifications go unnoticed.

---

## remote.sessions · another machine confirms which of its sessions are alive

**We assume** a machine reachable over `ssh` has `python3`, keeps session files at
`~/.claude/sessions/<pid>.json` with the same fields this one uses — `pid`, `cwd`,
`entrypoint`, `kind`, `sessionId`, and `procStart`, the process start time in
clock ticks — and, being Linux, exposes that same start time as field 22 of
`/proc/<pid>/stat`.

**Depends at** [RemoteProbeScript.swift](../Sources/LampBoardCore/Workspace/RemoteProbeScript.swift)
· [RemoteSessionsDecoder.swift](../Sources/LampBoardCore/Workspace/RemoteSessionsDecoder.swift)
· [StateStore.swift](../Sources/LampBoardApp/Runtime/StateStore.swift) (`poll`)

**What the probe is for, since D24.** Confirmation, not discovery. A remote row is
created by the hooks (below); the probe answers *is this pid still alive*, so a
session that died without a `SessionEnd` loses its row, and a host that has never
answered keeps its rows — `nil` and `[]` are different answers on purpose.

**How verified** — `probe`, against a real always-on node on 24 Aug 2026 (fields)
and 27 Aug 2026 (`procStart`): for a live session the session file said
`"procStart":"5480393"` and `/proc/<pid>/stat` field 22 was `5480393`. Without
that comparison a pid reused after a reboot keeps a dead session's row alive.

**Failure mode** — **loud in one direction, silent in the other.** A host that
cannot be reached is logged by name and keeps its previous rows. But a host whose
file shape changed would return well-formed JSON with missing fields, every record
would be skipped, and every remote row on it would be pruned on the next pass as
"not listed". `lampboard status` and `lampboard remote check` print each host
and what it said for exactly this reason.

**Not assumed** — that the remote transcript can be read from here. It cannot: a remote signal's transcript path is dropped at the decoder, and the
row menu does not offer "Read here" for a row that lives on another machine.

---

## remote.hooks · another machine's hooks reach this one through a tunnel we open

**We assume** three things about the other machine: Claude Code there reads hooks
from `~/.claude/settings.json` with the same schema as here (so
`HookConfigMerger` applies unchanged); `curl` and `python3` exist; and it is
Linux, so `/proc/net/tcp` and `/proc/net/tcp6` say where a port is bound — the
one fact the tunnel refuses to take on trust. **Not assumed**: that the ssh
server is OpenSSH. The machine this was built against runs **Tailscale SSH**,
whose daemon forwards as root; it honoured `-R 127.0.0.1:<port>` (measured in
`/proc/net/tcp`), and created a requested Unix socket `root:root 0600`, which is
why the transport is a port. And one thing about VS Code on this Mac: a
Remote-SSH window's title ends in `[SSH: <what the user typed to connect>]`.

**Depends at** [RemoteInstallScripts.swift](../Sources/LampBoardCore/Setup/RemoteInstallScripts.swift)
· [HookScriptBuilder.swift](../Sources/LampBoardCore/Setup/HookScriptBuilder.swift) (`host:`)
· [RemoteTunnel.swift](../Sources/LampBoardApp/Runtime/RemoteTunnel.swift)
· [WindowTitleMatcher.swift](../Sources/LampBoardCore/Workspace/WindowTitleMatcher.swift) (`bestRemoteMatch`)

**How verified** — against the same node on 27 Aug 2026: `settings.json` there had
no `hooks` key; after `lampboard remote install` it registered the nine events
with the script at `~/.lampboard/hook.sh`, a dated backup was written, and a
`curl` **from the node** to `127.0.0.1:<per-user port>/signal` — the port `remotePort(forUID:)` derives and `remote install` prints — with the `X-LampBoard-Host` header
produced `absent -> working host=minisforum` here. Two Remote-SSH windows were
open on this Mac at the time, titled `resume — <folder> [SSH: 100.x.x.x]` and
`<folder> [SSH: <alias>]` — the label is whatever was typed, hence the matcher
accepts the configured name, the `HostName` ssh resolves it to, and their
addresses.

**Failure mode** — a port already bound is seen before the connect and waited
out; a bind refused ends the tunnel at once (`ExitOnForwardFailure`) with a
reason in the log and the Settings window; a bind on anything but loopback
closes the tunnel with "exposed on <address>" and no retry; a `~/.lampboard`
there that is a symlink or another user's is refused
before anything is written, as is a missing `curl`; a settings file that changed
between the read and the write is left alone and the operation says so; a title
format change in VS Code Remote-SSH would make every remote click report "no
Remote-SSH window of that folder" while the rows keep working — loud, at the click.

---

# When one of these breaks

1. Run `./Scripts/check-contract.sh --live`. It names the record.
2. Read the record here: it says where the code leans and what the symptom is.
3. Fix the code, then **re-record**: `./Scripts/check-contract.sh --record`.
4. Update the record: `verifiedAgainst`, and what you learned.

A legitimate Claude Code change will show up as a failure until somebody blesses
it. That is not a defect of the method — it is the method.

## hook.cwd · the payload's cwd follows Claude's `cd`

**We assume** the `cwd` a hook carries is the session's *current* directory, which
Claude Code moves with the Bash tool's persistent `cd` — not the folder the
session started in. Measured on one session: 16,170 transcript records at the
project root, 29 under `docs/`, after a single `cd docs`.

**Depends at** [StateStore.swift:82](../Sources/LampBoardApp/Runtime/StateStore.swift#L82) —
a terminal row is anchored on the session **file's** `cwd`, written once.

**How verified** — `runtime`, by reading the transcript's `cwd` fields.

**Failure mode** — if the hook's `cwd` stopped moving nothing breaks; if the
file's started moving, terminal rows would drift with every `cd`. Editor rows
are immune either way: a subfolder still resolves to the window's folder.

---

## transcript.title · `ai-title` names the conversation, and repeats

**We assume** the transcript carries `{"type":"ai-title","aiTitle":…}` records,
that the first one sits within the file's head (measured: ≤ 119 KB across four
hundred transcripts), and that later ones repeat or replace it — so the last one
seen is the title. Claude Code writes the same text into the terminal's title bar,
prefixed `✳` — and `✳ Claude Code` before any title exists. That mark is what
tells a Ghostty terminal running `claude` from one running a shell.

**Depends at** [TranscriptTitleScanner.swift:15](../Sources/LampBoardCore/Transcript/TranscriptTitleScanner.swift#L15) ·
[TranscriptTail.swift:38](../Sources/LampBoardCore/Transcript/TranscriptTail.swift#L38)

**How verified** — `runtime`: the chat window's header and the terminal rows'
names come from it.

**Failure mode** — quiet: a terminal row keeps its folder name, which for a
session started in `~` is a username. The chat window shows the folder too.

---

## sessions.file.procStart · two formats, and the macOS one is UTC

**We assume** the session file's `procStart` is the process's start time: clock
ticks since boot on Linux (`"5480393"`), and on macOS a ctime string **in UTC
with no zone marker** at second resolution — `"Wed Aug 26 17:07:24 2026"` for a
process `ps -o lstart` shows at `19:07:24` local. Measured on two live sessions.

**Depends at** [ProcStart.swift:22](../Sources/LampBoardCore/Seat/ProcStart.swift#L22) ·
[SeatResolver.swift:34](../Sources/LampBoardApp/Focus/SeatResolver.swift#L34)

**How verified** — `runtime`, against the kernel's `p_starttime` for the same pid.

**Failure mode** — **loud in the wrong direction**: a format change that parses
as another moment makes every click on a terminal row answer "its pid now
belongs to another process". A format that stops parsing is quiet — the guard
is skipped and a reused pid could be raised.

---

## terminal.sdef · what the terminals' dictionaries expose

**We assume** Terminal.app exposes `tty` on every tab and iTerm2 on every
session (both read-only, both as `/dev/ttysNNN`); that Ghostty's `terminal`
has `id`, `name` and `working directory` and a `focus` command, and no tty;
that kitty and WezTerm have no dictionary and answer through `kitten @` (over
a socket, remote control permitting) and `wezterm cli` (panes with `tty_name`,
no pid). Read with `sdef <app>` and the CLIs' `--help`, then exercised live.

**Depends at** [TerminalScripts.swift:15](../Sources/LampBoardCore/Seat/TerminalScripts.swift#L15) ·
[TerminalListings.swift:9](../Sources/LampBoardCore/Seat/TerminalListings.swift#L9) ·
[TerminalFocuser.swift:30](../Sources/LampBoardApp/Focus/TerminalFocuser.swift#L30)

**How verified** — `runtime`, one click per host on a real `claude` inside it.

**Failure mode** — a property renamed makes the script error and the click
report *AppleScript failed* for that host; a CLI field renamed makes the pane
or window "not found". Both name the host; neither raises a wrong tab.

---

## zellij.socket · the server's socket is named after the session

**We assume** the zellij server runs as `zellij --server <dir>/<session>`, with
the session name as the socket's last path component, and that `lsof -nP -U`
prints a socket's own kernel address in `DEVICE` and its peer as `->0x…` in
`NAME` — which pairs a client with its server. zellij 0.45, macOS 26.

**Depends at** [SeatClassifier.swift:62](../Sources/LampBoardCore/Seat/SeatClassifier.swift#L62) ·
[MultiplexerListings.swift:24](../Sources/LampBoardCore/Seat/MultiplexerListings.swift#L24)

**How verified** — `runtime`, on the zellij session in daily use.

**Failure mode** — quiet: the pairing fails and the click falls back to the tab
whose title carries the session name, which zellij writes there.

---

## What this cannot do

It cannot catch what nobody thought to write down here. The list grows the way it
started: something breaks, and the record is written **before** the fix, so the
next person gets the reasoning and not just the patch.
