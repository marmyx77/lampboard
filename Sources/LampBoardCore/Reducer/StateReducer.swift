import Foundation

/// The actions that can change the traffic light column.
public enum ReducerAction: Sendable, Equatable {
    /// A hook signal, already matched to its workspace (`nil` when nothing claims
    /// its folder), and the kind of place that workspace is (`SessionOrigin`).
    case signal(HookSignal, workspace: Workspace?, origin: SessionOrigin = .editor)

    /// A fact learned outside any signal: the conversation's title, read from
    /// the transcript. Unknown session → nothing happens.
    case remember(sessionId: String, title: String)

    /// Removes every session of one origin — what "Show terminal sessions"
    /// turning off does, at once rather than at the next poll.
    case forget(origin: SessionOrigin)

    /// The user has seen the session: the "unread" states go back to red.
    case markSeen(sessionId: String)

    /// Remedy for one click too many: a cleared row goes back to "there is something to read".
    case markUnread(sessionId: String)

    /// Removes sessions that have been quiet for too long.
    ///
    /// `alive` are the ones whose process is confirmed running; they are kept
    /// whatever their timestamp says. Silence is not death when you can see the
    /// process.
    case prune(alive: Set<String> = [])

    /// Aligns the column with the Claude Code processes that are actually alive.
    /// An empty set is ignored: it almost always means the filesystem read failed,
    /// not that every session disappeared.
    ///
    /// It speaks for **one harness only**, and that is the whole of the second
    /// parameter. The list comes from `~/.claude/sessions`, where Claude Code
    /// drops one file per live process; Codex keeps no such directory, so a Codex
    /// row is absent from that list for the same reason a cat is absent from a
    /// list of dogs. Reconciling across harnesses removed every Codex row within
    /// five seconds of the hook that created it — a row that appeared and
    /// vanished, with nothing anywhere saying why.
    ///
    /// So the sweep prunes only what it can see. A harness with no liveness
    /// source of its own keeps its rows until its own `SessionEnd` arrives, or
    /// until `prune` retires them for silence. That is weaker evidence, and it is
    /// the evidence that exists.
    case reconcile(alive: Set<String>, harness: Harness = .claudeCode, evenIfEmpty: Bool = false)

    /// A fact read from outside the hooks: how full a session's context is.
    ///
    /// Separate from every other action because it changes nothing about the
    /// session's state — not its colour, not its order, not when it was last
    /// seen. It is an observation attached to a row, and a row that does not
    /// exist gets none: this never creates one, because a context reading is not
    /// evidence that a session is worth showing.
    /// The reading is **not** optional, and that is the whole point. When it was,
    /// the two callers disagreed without either noticing: the remote branch
    /// filtered out the sessions it could not read, the local one passed its
    /// `nil` straight through, and `with(context:)` dutifully replaced a good
    /// figure with nothing. A transcript that has moved out from under the reader
    /// for one poll would blank the ring on a session that was still working.
    /// A read that fails is not an observation, so it cannot be spelled here.
    case observed(sessionId: String, context: ContextReading)

    /// Inserts a session discovered from the filesystem, without overwriting one
    /// already known: what the hooks know is always more precise than a deduction.
    case adopt(SessionState)

    /// Takes one row off the column because the user said it is not there any more.
    ///
    /// Different from hiding, which is a lasting choice about a **project** and
    /// puts it in the summary. This is about one conversation, and it is what a
    /// person does with a row whose tab they closed while the process stayed
    /// loaded — a state the machine cannot tell from a live one, because the
    /// existence of a tab is published nowhere.
    ///
    /// It is not permanent and it is not a mute: the row comes back the moment
    /// the session says anything, and a discovered one comes back as soon as its
    /// evidence is newer than the dismissal. See `TrafficLightState.dismissed`.
    case dismiss(sessionId: String)

    /// Moves a row a **derived** colour, and only ever forward in time.
    ///
    /// Every other colour in this state machine was reported: a hook fired, said
    /// what happened, and the panel repeated it. A Claude Desktop conversation
    /// cannot report — it runs with its own `CLAUDE_CONFIG_DIR` and never reads
    /// the hooks on this machine — so its colour is read off its transcript on a
    /// timer, which makes it the one colour that would otherwise be re-asserted
    /// for ever.
    ///
    /// That is why the moment is part of the action and the rule is in here
    /// rather than at the call site. Without it, clearing a green row sets it
    /// seen, five seconds later the transcript still ends in the same answer,
    /// and the row lights up again for something already read: the click would
    /// be undone by the machine that is supposed to obey it. A hook satisfies
    /// this condition by existing, which is exactly why hooks never needed it.
    case derive(sessionId: String, status: SessionStatus, at: Date)

    /// Replaces the whole state (used when the app restarts).
    case reset
}

extension ReducerAction {
    /// A short name for the log, so a row that disappears names what removed it.
    public var label: String {
        switch self {
        case .signal(let signal, _, _): return "signal \(signal.event.rawValue)"
        case .remember: return "remember"
        case .markSeen: return "markSeen"
        case .markUnread: return "markUnread"
        case .prune: return "prune"
        case .reconcile(let alive, let harness, _):
            return "reconcile \(harness.rawValue) keeping \(alive.count)"
        case .observed: return "observed"
        case .adopt: return "adopt"
        case .dismiss: return "dismiss"
        case .derive: return "derive"
        case .reset: return "reset"
        case .forget: return "forget"
        }
    }
}

/// A pure state machine: `(state, action) -> new state`.
///
/// No dependency on the clock, the filesystem or the network — `now` is a parameter.
/// All the traffic light logic lives here, and it is entirely under test.
public enum StateReducer {
    public static func reduce(
        _ state: TrafficLightState,
        action: ReducerAction,
        now: Date
    ) -> TrafficLightState {
        // A session that speaks is a session that is there, whatever anybody
        // clicked. A hook fires because a turn moved, so it outranks a dismissal
        // without needing to compare dates: the click said "this is not here any
        // more", and the signal is the row saying otherwise.
        var state = state
        if case .signal(let signal, _, _) = action {
            state = state.undismissing(sessionId: signal.sessionId)
        }

        switch action {
        case .reset:
            return .empty

        case .prune(let alive):
            return state.pruning(
                olderThan: AppConfig.sessionStaleAfter, at: now, keepingAlive: alive
            )

        case .reconcile(let alive, let harness, let evenIfEmpty):
            // An empty set is normally treated as "the reader failed", because the
            // Claude side cannot tell that from "nothing is running" and erasing
            // every row on a bad read is unrecoverable.
            //
            // The Codex scanner **can** tell them apart: a probe that could not run
            // returns `.unavailable` and never reaches here. Without this the last
            // Codex session on a machine kept its row for ever, and the case that
            // caught it is the end-to-end one that closes a descriptor and watches
            // the row go.
            guard evenIfEmpty || !alive.isEmpty else { return state }
            return TrafficLightState(
                sessions: state.sessions.filter {
                    $0.value.harness != harness || alive.contains($0.key)
                },
                // Carried through, and the reason is a defect: this branch runs on
                // every sweep, so dropping it here emptied the register of
                // dismissed rows five seconds after the click and the row came
                // straight back. Every state this file builds by hand has to carry
                // it — see the test that walks it through all four.
                dismissed: state.dismissed
            )

        case .observed(let sessionId, let context):
            guard let session = state.sessions[sessionId] else { return state }
            return state.upserting(session.with(context: context))

        case .adopt(let session):
            guard state.sessions[session.id] == nil else { return state }
            // A row the user took off comes back only on something newer than the
            // click. Without this the next sweep puts it straight back — the
            // process is still alive and the rollout still open, which is exactly
            // what made the row outlive its tab in the first place.
            guard state.admits(sessionId: session.id, evidenceAt: session.updatedAt) else {
                return state
            }
            return state.upserting(session).undismissing(sessionId: session.id)

        case .dismiss(let sessionId):
            return state.dismissing(sessionId: sessionId, at: now)

        case .derive(let sessionId, let status, let moment):
            guard let session = state.sessions[sessionId],
                  session.status != status,
                  moment > session.statusSince
            else { return state }
            return state.upserting(session.with(status: status, at: moment))

        case .markSeen(let sessionId):
            guard let session = state.sessions[sessionId], session.status.clearsOnFocus else {
                return state
            }
            return state.upserting(session.markedSeen(at: now))

        case .markUnread(let sessionId):
            guard let session = state.sessions[sessionId] else { return state }
            return state.upserting(session.markedUnread(at: now))

        case .signal(let signal, let workspace, let origin):
            let next = apply(signal: signal, workspace: workspace, to: state, now: now)
            return remembering(factsOf: signal, origin: origin, in: next)

        case .remember(let sessionId, let title):
            guard let session = state.sessions[sessionId] else { return state }
            return state.upserting(session.with(title: title))

        case .forget(let origin):
            return TrafficLightState(
                sessions: state.sessions.filter { $0.value.origin != origin },
                dismissed: state.dismissed
            )
        }
    }

    /// Records the facts a signal carries about the session — where its
    /// transcript lives, how it was started — whatever else the signal did.
    ///
    /// It sits here, once, rather than on each of the seven paths through `apply`:
    /// these facts are orthogonal to the traffic light — they do not depend on the
    /// event, the state or the ordering — and threading them through every branch
    /// would mean seven chances to forget one and no test that notices six. This
    /// is the **only** place they are written from a signal.
    ///
    /// A session `apply` removed or refused is simply not there, and this does
    /// nothing. That is the correct outcome, not a special case.
    private static func remembering(
        factsOf signal: HookSignal,
        origin: SessionOrigin,
        in state: TrafficLightState
    ) -> TrafficLightState {
        guard let session = state.sessions[signal.sessionId] else { return state }
        // A row this machine **found** keeps what it was found with. The folder
        // was already protected; these three were not, and they are the same
        // kind of fact. The transcript path is the thread back to the
        // conversation, the entrypoint decides whether a click raises a
        // terminal, an editor or an application, and the origin decides which
        // of those the row even offers. All three were read off a live process
        // or an index; a hook on an unauthenticated route is a claim about
        // them, and the claim loses.
        //
        // The surface is the sharpest case, and the audit that asked for it had
        // already established the principle elsewhere: it comes from the
        // executable holding the rollout open, which is a fact about this
        // machine, and not from what a payload calls itself.
        // The git identity is the exception among these, and it is set **before**
        // the found-row guard on purpose. The other three are claims a hook makes
        // about facts this machine read for itself, so a found row keeps its own.
        // Nothing here reads git at all — it cannot, without asking macOS for
        // folder access — so for a found row the hook is not a competing claim,
        // it is the only one there will ever be.
        var updated = session
        if let git = signal.git { updated = updated.with(git: git) }
        guard !session.wasFound else { return state.upserting(updated) }
        return state.upserting(
            updated
                .with(transcriptPath: signal.transcriptPath)
                .with(entrypoint: signal.entrypoint)
                .with(origin: origin)
        )
    }

    // MARK: - Applying a signal

    private static func apply(
        signal: HookSignal,
        workspace: Workspace?,
        to state: TrafficLightState,
        now: Date
    ) -> TrafficLightState {
        // Only sessions that deserve a row, and only inside a known workspace.
        guard signal.deservesTrafficLight, let workspace else { return state }

        // The birth and death of a subagent must be read **before** the rule that
        // discards subagent signals: they carry `agent_id` like all the others,
        // but they speak about the parent's turn, not the child's.
        if let transition = signal.subagentTransition {
            return applySubagent(
                transition, signal: signal, workspace: workspace, to: state, now: now
            )
        }

        // A subagent works inside the parent's turn: it has no traffic light of its own.
        guard !signal.isFromSubagent else { return state }

        if signal.event == .sessionEnd {
            return state.removing(sessionId: signal.sessionId)
        }

        guard let newStatus = status(for: signal) else {
            return discovering(signal: signal, workspace: workspace, in: state, now: now)
        }

        // The invariant, enforced rather than only written down.
        //
        // `Harness.cannotReport` says a Codex row never turns red, because Codex
        // publishes no failure event and silence does not tell a crash from a long
        // turn. Until now that held because no Codex event reached the branch that
        // produces `.failed`, which is a different thing from being true: the
        // guarantee is in the model and in the README, and it depended on the hook
        // configuration rather than on the code.
        //
        // A `StopFailure` carrying `X-LampBoard-Harness: codex` is all it would
        // have taken, and that header is on an unauthenticated route.
        let existing = state.sessions[signal.sessionId]

        // The folder of a row this machine found is not a thing a signal gets to
        // set, and the rule belongs here rather than only at the call site that
        // assembles the workspace. It was enforced in one caller, correctly, and
        // a pure state machine that will happily move a found row anywhere it is
        // told is a guarantee resting on nobody forgetting.
        //
        // Computed **before** the guard below and not after it, which is where a
        // third audit found it. That branch returned early and applied the
        // signal's own workspace, so the rule this comment describes had an
        // exception three lines under it. The running app never reached it —
        // `StateStore` substitutes the known folder before calling in — which is
        // exactly the dependence on a caller that putting the rule here was
        // meant to remove.
        let place = existing?.wasFound == true ? existing!.workspace : workspace

        guard !signal.harness.cannotReport.contains(newStatus) else {
            return state.upserting(
                (existing ?? SessionState(
                    id: signal.sessionId, status: .idle, workspace: place,
                    updatedAt: now, statusSince: now, harness: signal.harness
                ))
                .with(workspace: place)
            )
        }

        // An answer that is already waiting is not downgraded to "working" by a
        // trailing signal that arrived out of order.
        //
        // The comparison is against `baseStatus`, not the displayed state: a
        // session with green set aside and subagents in flight *appears* yellow,
        // and using the appearance here would make the very downgrade this rule
        // exists to prevent look legitimate — erasing precisely the answer that
        // is waiting to be read.
        if let existing,
           shouldKeep(current: existing.baseStatus, over: newStatus, event: signal.event) {
            return state.upserting(
                existing
                    .with(workspace: place)
                    .with(lastMessage: preview(of: signal.lastAssistantMessage))
            )
        }

        let base = existing?
            .with(workspace: place)
            ?? SessionState(
                id: signal.sessionId,
                status: newStatus,
                workspace: workspace,
                updatedAt: now,
                statusSince: now,
                harness: signal.harness
            )

        let updated = base
            // The agent a row belongs to is not a thing a payload gets to say
            // about a row that was found. It came from the file a live process
            // holds open, and letting a claim change it would unlock everything
            // the rest of this rule protects: `wasFound` is itself read from the
            // harness.
            .with(harness: base.wasFound ? base.harness : signal.harness)
            .with(status: newStatus, at: now)
            .with(lastMessage: preview(of: signal.lastAssistantMessage))
            .with(failureReason: newStatus == .failed ? (signal.failureReason ?? .unknown) : nil)
            // What is registered behind the row is a fact about *this* Stop; any
            // other event means it is over, or never was.
            //
            // Kept for a green row too, not only a blue one: a turn can end with
            // nothing running and an ear still open, and that ring has to survive
            // the answer being read.
            .with(waitingOn: signal.event == .stop ? signal.reportableBackgroundTaskTypes : [])
            // The question lives exactly as long as the amber does. A signal that
            // carries one brings it; any signal that moves the row off amber takes
            // it away. Keeping it a moment longer would leave a row showing a
            // question that has already been answered, which is the same class of
            // wrong as the notification that quoted the previous reply.
            .with(pendingAsk: newStatus == .awaiting
                ? (signal.pendingAsk ?? base.pendingAsk)
                : nil)

        // A new question opens a new turn: the previous turn's subagents no longer
        // count, and if some `SubagentStop` got lost along the way this is where
        // the stuck counter clears.
        return state.upserting(
            signal.event == .userPromptSubmit ? updated.withoutSubagents() : updated
        )
    }

    /// Moves a session's subagent counter.
    ///
    /// A start creates the row if it isn't there: a subagent starting **proves** a
    /// session is working, and that is stronger evidence than what the app already
    /// trusts when discovering new sessions.
    ///
    /// A stop, by contrast, creates nothing. There is nothing to decrement in a
    /// session never seen before, and materializing a row from a closing event
    /// would mean inventing a state out of its own conclusion.
    private static func applySubagent(
        _ transition: (id: String, starting: Bool),
        signal: HookSignal,
        workspace: Workspace,
        to state: TrafficLightState,
        now: Date
    ) -> TrafficLightState {
        guard let existing = state.sessions[signal.sessionId] else {
            guard transition.starting else { return state }
            return state.upserting(
                SessionState(
                    id: signal.sessionId,
                    status: .working,
                    workspace: workspace,
                    updatedAt: now,
                    statusSince: now,
                    harness: signal.harness,
                    activeAgentIds: [transition.id]
                )
            )
        }

        // A subagent **starting** releases a pending question, and this is the one
        // place that can tell: a main loop blocked on a permission prompt cannot
        // spawn anything, so if a child is being born the prompt was answered.
        //
        // It does **not** prove the turn is running in general, and a first draft
        // of this rule said it did. A background agent launched at the end of a
        // turn sends its `SubagentStart` *after* the parent's `Stop` — the log
        // shows it — and repainting that row yellow would call a session that has
        // stopped "working". Left to the derived state, it reads `waiting`, which
        // is what it is.
        //
        // A subagent *finishing* proves nothing either way — one already running
        // when the prompt opened can finish while the turn is still blocked.
        let released = transition.starting && existing.baseStatus == .awaiting
        let base = released
            ? existing.with(status: .working, at: now)
            : existing

        return state.upserting(
            base
                .with(workspace: workspace)
                .withSubagent(id: transition.id, starting: transition.starting, at: now)
        )
    }

    /// Maps event → traffic light state. `nil` means "change nothing".
    private static func status(for signal: HookSignal) -> SessionStatus? {
        switch signal.event {
        case .permissionRequest:
            // The same fact `Notification/permission_prompt` carries on the other
            // side: the turn has stopped and is waiting for a person. It arrives
            // here as its own event because Codex publishes no `Notification`.
            //
            // Unless nobody is waiting. Codex asks for approval of a tool call
            // whether a person or its own reviewer will answer, and the event does
            // not say which. With `auto_review` the answer arrives by itself and
            // the row was blinking amber — the one state that means "you are
            // blocking this" — for as long as the **command** ran, because amber
            // only lifts at `PostToolUse`. Measured: 6.0 s, 6.4 s and 31.0 s in one
            // audit, none of them waiting for anybody.
            //
            // `nil` keeps whatever the row already said, which is yellow: the
            // session is working, and asking itself for permission is work.
            return signal.approvalReviewer == .automatic ? nil : .awaiting

        case .sessionStart:
            // Context compaction fires mid-turn: treating it as the start of a
            // session would clear the yellow of a session that is working, and
            // sink it to the bottom of the column into the bargain.
            return signal.isContextCompaction ? nil : .idle

        case .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure:
            return .working

        case .stop:
            // A turn that ends with work still in flight has **not** finished it,
            // and green means two things at once: there is something to read, and
            // nothing more is coming. The second half is false here.
            //
            // This was examined on the first day and deliberately left alone, on
            // the reasoning that the turn had genuinely ended and an answer
            // genuinely existed. Use overruled it: the session writes a recap, the
            // light goes green, and the actual work carries on for minutes —
            // exactly the lie the subagent correction exists to prevent, arriving
            // by a different door.
            //
            // Green comes back on its own. The work finishes, wakes the session
            // with a notification, and that turn ends with nothing in flight.
            //
            // There is deliberately **no** exemption for work that never ends, of
            // the kind tmux gives itself with `JOB_NOWAIT` — a flag on the jobs the
            // server must not wait for before exiting. The equivalent exists, but
            // on the other side of the boundary: Claude Code drops anything not
            // backgrounded before it builds this list, so a task that reaches us is
            // by its own definition one the session is paused waiting for. Adding a
            // second valve here would mean guessing which of *those* really count,
            // and a guess is exactly what the column must not contain.
            //
            // "Anything in the list" was the first rule, and it was too wide by one
            // type: `dream`, Claude Code's own memory consolidation, sits in the
            // list while the session is idle and never wakes it when it ends.
            // Thirteen of sixteen turns in one session stayed yellow on it.
            //
            // And it is not `working` either. Claude has handed control back; what
            // remains is a wait for the work to wake it. Yellow here lasted as long
            // as a CI run and read as "thinking" the whole time. D22.
            return signal.hasWorkInFlight ? .waiting : .ready

        case .stopFailure:
            // A turn that was cut short produced nothing to read: showing it green
            // like a completed turn is the most expensive lie in the column. The
            // one exception is truncation at maximum length, where the text exists
            // and is merely incomplete.
            return signal.failureReason?.hasUsableOutput == true ? .ready : .failed

        case .notification:
            switch signal.notificationKind {
            case .permissionPrompt, .agentNeedsInput, .elicitationDialog:
                return .awaiting

            case .agentCompleted:
                return .ready

            // `idle_prompt` is an inactivity timer, not an answer: it reports that
            // the session has been quiet for a while, which the traffic light
            // already knows. Mapping it to green invented answers that never arrived.
            case .idlePrompt:
                return nil

            case .none:
                return nil
            }

        case .sessionEnd:
            return nil

        // Handled earlier by `applySubagent`: they never reach this point.
        case .subagentStart, .subagentStop:
            return nil
        }
    }

    /// Some events do not move the state of an existing row, but they do reveal
    /// the existence of a session the app had not yet seen — typically because it
    /// was started mid-session.
    ///
    /// This applies only to the inactivity timer, which *proves* a session is idle.
    /// Context compaction, by contrast, creates nothing: inventing an `idle` row
    /// for a session that is demonstrably working would be exactly the lie this
    /// correction removes.
    private static func discovering(
        signal: HookSignal,
        workspace: Workspace,
        in state: TrafficLightState,
        now: Date
    ) -> TrafficLightState {
        guard state.sessions[signal.sessionId] == nil,
              signal.notificationKind == .idlePrompt
        else {
            return state
        }

        return state.upserting(
            SessionState(
                id: signal.sessionId,
                status: .idle,
                workspace: workspace,
                updatedAt: now,
                statusSince: now,
                harness: signal.harness
            )
        )
    }

    /// Protects the "unread" states from signals that would downgrade them.
    ///
    /// The real case: after `Stop` (green), a `PostToolUse` from the turn that just
    /// closed can arrive late. Without this rule the light would go back to yellow
    /// and the waiting answer would go unnoticed.
    private static func shouldKeep(
        current: SessionStatus,
        over incoming: SessionStatus,
        event: HookEventKind
    ) -> Bool {
        // `failed` needs the same protection as `ready` and `awaiting`, but for a
        // different
        // reason, and that is why it isn't in `blocksDowngrade`.
        //
        // That flag answers the question "does this state survive a restart?", and
        // for `failed` the answer is no: if the turn really does resume, yellow is
        // the correct information and red is a leftover. But a late `PostToolUse`
        // **is not a restart** — it is the tail of the turn that just got cut short,
        // the same phenomenon this rule exists to neutralize on `ready`. Without
        // this addition, a trailing signal erased the cause of the error and
        // painted a session yellow when it wasn't working at all.
        let resists = current.blocksDowngrade || current == .failed
        guard resists, incoming == .working else { return false }

        // A pending question yields to the **one** event that proves it was
        // answered, and only that one.
        //
        // `PostToolUse` cannot fire unless the tool actually ran, which means the
        // permission was granted. `PostToolUseFailure` carries the same proof and
        // is needed beside it: Claude Code emits one **or** the other, so a tool
        // that was permitted and then failed produces only the second, and reading
        // just the first left the amber up in exactly that case. A tool the sandbox
        // blocked produces neither, which is right — nothing ran.
        // `PreToolUse` cannot say the same: it carries
        // `permissionDecision` in its own output schema, so it runs *inside* the
        // permission decision and therefore **before** the prompt. One arriving
        // afterwards is out of order and proves nothing — which is why the amber
        // still resists it.
        //
        // Measured, and this is why the exception exists: a permission prompt put
        // a row amber at 08:48 and it stayed amber for thirty-three minutes while
        // subagents came and went, because nothing but the user's next prompt
        // could release it. The prompt is what blocks the turn; once a tool has
        // completed, the turn is not blocked any more.
        if current == .awaiting, event == .postToolUse || event == .postToolUseFailure {
            return false
        }

        // A new user prompt, on the other hand, is a legitimate transition:
        // it means they read it and started again.
        return event != .userPromptSubmit
    }

    /// Reduces the message to a one-line preview for the tooltip.
    private static func preview(of message: String?) -> String? {
        guard let message = message?.trimmed, !message.isEmpty else { return nil }
        let singleLine = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        let limit = 140
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }
}
