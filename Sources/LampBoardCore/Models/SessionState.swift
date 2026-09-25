import Foundation

/// State of a single Claude Code session — that is, of one traffic light.
///
/// The type is immutable: every transition produces a new instance through the
/// `with…` methods, so there is no path along which a state can change under
/// the feet of whoever is reading it.
public struct SessionState: Sendable, Equatable, Identifiable {
    /// Claude Code session id.
    public let id: String

    /// The state the hooks declared for the main turn.
    ///
    /// It does not always match what is displayed: see `status`.
    public let baseStatus: SessionStatus

    /// VS Code workspace the session belongs to.
    public let workspace: Workspace

    /// Preview of the last answer, shown as a tooltip.
    public let lastMessage: String?

    /// Timestamp of the last signal received. Used for ordering and for
    /// dropping sessions that have been quiet for too long.
    public let updatedAt: Date

    /// Timestamp at which the session entered its current state.
    /// Lets the row show "how long it has been working".
    public let statusSince: Date

    /// Why the turn stopped. Only populated in the `failed` state.
    public let failureReason: StopFailureReason?

    /// How many subagents are running inside this session's turn.
    ///
    /// Which coding agent this session belongs to.
    ///
    /// Carried on the row rather than looked up, because two of them can be open
    /// in the same project at the same time: the panel groups by folder, so a row
    /// that had to ask the folder which harness it was would get the wrong answer
    /// exactly when it mattered. It decides which reader parses the transcript,
    /// and which limits the card declares.
    public let harness: Harness

    /// What this session is asking for, while it is asking. Cleared the moment
    /// the row stops being amber: an ask that outlives its question is worse
    /// than none, because it reads as current.
    public let pendingAsk: PendingAsk?

    /// The subagents believed to be alive, **by identity**.
    ///
    /// A subagent has no traffic light of its own, but its existence **proves**
    /// the session is working: without this a forty-five minute background
    /// workflow leaves the light frozen, because `Stop` only fires when the turn
    /// closes and nothing arrives in between.
    ///
    /// It is a set and not a counter because hooks are fire-and-forget over a
    /// socket and a duplicate delivery is a fact of the transport, not a bug to
    /// be prevented upstream. A counter that a repeated `SubagentStart` pushed to
    /// two would only ever be brought back down by one `SubagentStop`, and the
    /// row stayed blue for the rest of the session. Adding the same identity
    /// twice is free; the idempotence is a property of the type instead of a
    /// rule somebody has to remember.
    public let activeAgentIds: Set<String>

    /// How many subagents are alive. Derived, so every reader is unchanged.
    public var activeSubagents: Int { activeAgentIds.count }

    /// What the session is waiting on, when it is `waiting`: the types Claude Code
    /// listed in flight at the last `Stop`, in its order — `monitor`, `shell`,
    /// `subagent`. Empty otherwise.
    ///
    /// Kept so the row can say *why* it is blue. A wait that lasts a day is only a
    /// defect if you cannot tell what is holding it; naming the shell makes the
    /// honest question — is that a dev server nobody will stop? — askable.
    public let waitingOn: [String]

    /// Where this session's transcript lives, when a hook has told us.
    ///
    /// Optional and it stays optional: a session adopted from the filesystem has
    /// no transcript path until the first hook arrives, and a chat window that
    /// cannot open is a better outcome than one that opens the wrong file.
    public let transcriptPath: String?

    /// The repository and branch this session started in, when the hook script
    /// could resolve them (`GitIdentity`). A fact about the session: set once by
    /// the session start that carries it, and never cleared by the signals that
    /// do not — every later event comes from a hook that does no git work.
    public let git: GitIdentity?

    /// How Claude Code was started for this session — `claude-vscode` by the
    /// extension, `cli` by hand in a terminal — read from the hook's header or
    /// the session file. `nil` until something has said.
    ///
    /// It is what tells the click whether a tab exists to open: the extension
    /// resolves the deep link in the focused window and, for a session it does
    /// not host, opens a new tab instead of finding one. A fact about the
    /// session, so it is set once and never cleared by a signal that lacks it.
    public let entrypoint: String?

    /// The kind of place the row lives in. See `SessionOrigin`.
    public let origin: SessionOrigin

    /// The title Claude gave the conversation, once it has given one.
    ///
    /// Read from the transcript, never from a hook. It is what names a terminal
    /// row: the folder of a session started in `~` is a username, and the title is
    /// what the person sees in their terminal's title bar.
    public let title: String?

    /// How full this session's context was at its last reply.
    ///
    /// A reading, not a fact about now: only assistant records carry a token
    /// count, so anything loaded since is invisible and the reading says as much
    /// about itself. `nil` for a session that has never answered, for one on a
    /// machine that could not be asked, and for a model whose window is not in
    /// the table — three different silences, all of which must render as a dash
    /// rather than as an empty space.
    public let context: ContextReading?

    /// When this session first appeared to the panel.
    ///
    /// The one moment about a session that never moves: `updatedAt` follows every
    /// signal and `statusSince` follows every transition, so neither can order a
    /// list that must hold still. It is what numbers the conversations inside a
    /// row, in the order they were opened, and it is preserved by every copy.
    ///
    /// A session built without one is first seen when it was last updated, which
    /// is the only moment it knows about itself.
    public let firstSeenAt: Date

    public init(
        id: String,
        status: SessionStatus,
        workspace: Workspace,
        lastMessage: String? = nil,
        updatedAt: Date,
        statusSince: Date,
        failureReason: StopFailureReason? = nil,
        harness: Harness = .claudeCode,
        git: GitIdentity? = nil,
        pendingAsk: PendingAsk? = nil,
        activeAgentIds: Set<String> = [],
        transcriptPath: String? = nil,
        waitingOn: [String] = [],
        entrypoint: String? = nil,
        origin: SessionOrigin = .editor,
        title: String? = nil,
        context: ContextReading? = nil,
        firstSeenAt: Date? = nil
    ) {
        self.firstSeenAt = firstSeenAt ?? updatedAt
        self.context = context
        self.waitingOn = waitingOn
        self.entrypoint = entrypoint?.trimmed.nilIfEmpty
        self.origin = origin
        self.title = title?.trimmed.nilIfEmpty
        self.id = id
        self.baseStatus = status
        self.workspace = workspace
        self.lastMessage = lastMessage
        self.updatedAt = updatedAt
        self.statusSince = statusSince
        self.failureReason = failureReason
        self.harness = harness
        self.pendingAsk = pendingAsk
        self.activeAgentIds = activeAgentIds
        self.transcriptPath = transcriptPath
        self.git = git
    }

    /// `true` when this row's folder is **evidence the panel found**, not
    /// something it was told.
    ///
    /// A Claude Code session announces itself and its folder follows the latest
    /// resolution: opening its directory in an editor genuinely moves it into
    /// that window, which is the behaviour D25 describes. A Codex session and a
    /// Claude Desktop session are the opposite case. Nobody announces them: one
    /// is read out of the rollout a live process holds open, the other out of the
    /// index beside its session home, and in both the folder was established
    /// before any signal existed.
    ///
    /// So for these two a later hook may move the **colour** and nothing else.
    /// Not the folder, not the transcript, not the surface, not the agent: every
    /// one of those was established by looking at this machine, and a hook is a
    /// claim. `POST /signal` is not authenticated, so "only our hooks send that"
    /// is an assumption and not a bound.
    ///
    /// The hole was real twice over. First the folder: a hook naming a known
    /// session id, with a `cwd` that happened to match some other window, moved
    /// the row into that other project. Then the rest of it, which the same
    /// audit had asked about and the first fix had not covered — the transcript
    /// path is the thread back to the conversation, and the entrypoint is what
    /// decides whether a click raises a terminal, an editor or an application.
    /// A row that names a Codex session and calls itself `claude-vscode` gets an
    /// editor window opened for a conversation that is not in one.
    public var wasFound: Bool {
        harness == .codex || ClaudeDesktop.isEntrypoint(entrypoint)
    }

    /// The state the traffic light actually shows.
    ///
    /// As long as a subagent is alive the session **is working**, whatever the
    /// last hook of the main turn may have said. This is not a refinement: with
    /// background agents, `Stop` fires when the parent turn returns control while
    /// the agents keep going for tens of minutes. Taking that `Stop` literally
    /// paints green — "there is an answer to read" — onto a session that is still
    /// working, and that is the most expensive lie the column can tell.
    ///
    /// Deriving it rather than storing it also solves the way back on its own:
    /// when the last subagent finishes, the green that was set aside reappears
    /// without anyone having to remember it.
    ///
    /// The one exception is waiting for a permission, which always wins: it blocks
    /// everything, subagents included, and it needs you now.
    ///
    /// What a live subagent paints depends on whether the parent is still in its
    /// turn. While it is (`working`), the row is working. After the parent's
    /// `Stop`, a subagent still alive is a session **waiting** to be woken by it —
    /// not one working. It used to paint yellow over any state, and yellow over a
    /// session that has stopped is the half-truth D22 exists to remove.
    public var status: SessionStatus {
        guard activeSubagents > 0 else { return baseStatus }
        switch baseStatus {
        case .awaiting: return .awaiting
        case .working: return .working
        case .ready, .idle, .waiting, .failed: return .waiting
        }
    }

    // MARK: - Copies

    /// Copy with a new state. `statusSince` only advances when the state really
    /// changes, so a burst of `PreToolUse` events doesn't reset the stopwatch.
    public func with(status newStatus: SessionStatus, at now: Date) -> SessionState {
        replacing(
            status: newStatus,
            updatedAt: now,
            statusSince: newStatus == baseStatus ? statusSince : now
        )
    }

    /// Copy with a new failure cause.
    /// Passing `nil` clears it: a session that restarts does not carry the
    /// previous turn's error with it.
    public func with(failureReason newReason: StopFailureReason?) -> SessionState {
        replacing(failureReason: .some(newReason))
    }

    /// Copy marked as seen by the user.
    ///
    /// Unlike `with(status:at:)` this does **not** touch `updatedAt`: that field
    /// records Claude's last activity, and it is what the row label displays. A
    /// click is not session activity, and jumping a three-day-old session to "now"
    /// would erase the only useful information it carries.
    public func markedSeen(at now: Date) -> SessionState {
        replacing(status: .idle, statusSince: now, failureReason: .some(nil))
    }

    /// Copy restored to "there is something to read".
    ///
    /// This is the remedy for one click too many: `markedSeen` is irreversible by
    /// construction, and without this escape hatch an accidentally consumed answer
    /// is lost. It leaves `updatedAt` alone for the same reason.
    public func markedUnread(at now: Date) -> SessionState {
        guard baseStatus == .idle else { return self }
        return replacing(status: .ready, statusSince: now)
    }

    /// Copy that records — or forgets — what the session is waiting on.
    /// Copy carrying a fresh context reading.
    ///
    /// Compared before replacing, like every other `with`: a reading that has
    /// not moved must not produce a new value, or the panel republishes its
    /// whole snapshot every five seconds and redraws for nothing.
    /// A reading that failed is not passed here at all — see `ReducerAction.observed`.
    /// A reading that succeeded but found nothing left to read is a *value*, with
    /// `confidence == .unknown`, so a compacted session still has a way to say so.
    public func with(context reading: ContextReading) -> SessionState {
        guard reading != context else { return self }
        return replacing(context: .some(reading))
    }

    /// Copy belonging to the harness the hook says it does.
    ///
    /// A row can be born from the filesystem sweep before any hook arrives, and
    /// the sweep can only guess — it reads one agent's directory and knows
    /// nothing of the other. The hook is the authority: it is sent by a script
    /// this app wrote and installed for one agent. Without this the guess stood
    /// for the life of the row, and a Codex session adopted as a Claude one read
    /// its rollout with the wrong parser and drew an empty ring forever.
    public func with(harness newHarness: Harness) -> SessionState {
        guard newHarness != harness else { return self }
        return replacing(harness: newHarness)
    }

    /// Copy carrying the repository and branch, when a signal brought them.
    ///
    /// There is no way to **clear** it, unlike `pendingAsk`. Only a session start
    /// carries the identity; every other event arrives without it, and a setter
    /// that could take `nil` would let the next `Stop` erase a perfectly good
    /// branch name — which is the shape of the bug this signature prevents.
    public func with(git identity: GitIdentity) -> SessionState {
        guard identity != git else { return self }
        return replacing(git: identity)
    }

    /// Copy carrying — or dropping — the question the session is blocked on.
    public func with(pendingAsk ask: PendingAsk?) -> SessionState {
        guard ask != pendingAsk else { return self }
        return replacing(pendingAsk: .some(ask))
    }

    public func with(waitingOn types: [String]) -> SessionState {
        guard types != waitingOn else { return self }
        return replacing(waitingOn: types)
    }

    /// Copy with a new preview message.
    public func with(lastMessage newMessage: String?) -> SessionState {
        replacing(lastMessage: .some(newMessage ?? lastMessage))
    }

    /// Copy with an updated workspace: a session can change `cwd` and end up in
    /// a different workspace.
    public func with(workspace newWorkspace: Workspace) -> SessionState {
        replacing(workspace: newWorkspace)
    }

    /// Copy that remembers where the transcript is.
    ///
    /// A `nil` argument leaves the known path alone instead of clearing it. The
    /// path is a fact about the session that does not stop being true because one
    /// signal failed to carry it, and forgetting it would close the chat window
    /// of a session that is merely between events.
    public func with(transcriptPath newPath: String?) -> SessionState {
        guard let newPath, newPath != transcriptPath else { return self }
        return replacing(transcriptPath: .some(newPath))
    }

    /// Copy that remembers how the session was started. Same rule as the
    /// transcript path: `nil` leaves the known value alone.
    public func with(entrypoint newValue: String?) -> SessionState {
        guard let newValue = newValue?.trimmed.nilIfEmpty, newValue != entrypoint else { return self }
        return replacing(entrypoint: .some(newValue))
    }

    /// Copy living in another kind of place. It follows the latest resolution:
    /// a terminal session whose folder gets opened in an editor becomes an
    /// editor row at its next signal — the session moved into a window.
    public func with(origin newOrigin: SessionOrigin) -> SessionState {
        guard newOrigin != origin else { return self }
        return replacing(origin: newOrigin)
    }

    /// Copy that knows the conversation's title. `nil` or blank leaves it alone.
    public func with(title newTitle: String?) -> SessionState {
        guard let newTitle = newTitle?.trimmed.nilIfEmpty, newTitle != title else { return self }
        return replacing(title: .some(newTitle))
    }

    // MARK: - Naming

    /// What a person reads for this session.
    ///
    /// The folder name for an editor row — it is what the window title says, and
    /// the key the window is found by. For a terminal row, the conversation title
    /// once there is one: the folder of a session started in the home directory
    /// is a username, and says nothing about which of three terminals it is.
    public var displayName: String {
        guard origin == .terminal, let title else { return workspace.name }
        return title
    }

    /// Copy with the subagent counter shifted by `delta`, never below zero.
    ///
    /// The floor at zero is not pedantry: `SubagentStop` can arrive without its
    /// matching `SubagentStart` — the app may have started mid-turn — and a
    /// negative counter would hold the row yellow forever.
    /// Copy with one subagent recorded as born or gone.
    ///
    /// Both directions are idempotent by construction: inserting an identity
    /// already present changes nothing, and removing one already absent changes
    /// nothing. A duplicate delivery of either event is therefore harmless, and
    /// a `SubagentStop` for a child this app never saw start — which happens
    /// every time the app launches mid-turn — cannot push the count negative.
    public func withSubagent(id: String, starting: Bool, at now: Date) -> SessionState {
        let updated = starting
            ? activeAgentIds.union([id])
            : activeAgentIds.subtracting([id])
        guard updated != activeAgentIds else { return replacing(updatedAt: now) }
        return replacing(updatedAt: now, activeAgentIds: updated)
    }

    /// Copy with the counter zeroed.
    ///
    /// The reset point is the **user's prompt**, not the end of the turn: with
    /// background agents the turn finishes while they are still working, and
    /// resetting there would restore green at the worst possible moment. A new
    /// prompt, by contrast, is a certain boundary, and it doubles as a safety net —
    /// if a `SubagentStop` gets lost along the way, the stuck counter clears on the
    /// next question instead of holding the row yellow until pruning.
    public func withoutSubagents() -> SessionState {
        guard !activeAgentIds.isEmpty else { return self }
        return replacing(activeAgentIds: [])
    }

    // MARK: - Queries

    /// Duration of the current state relative to `now`.
    public func statusDuration(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(statusSince))
    }

    /// `true` when the session has subagents in flight.
    public var hasActiveSubagents: Bool { activeSubagents > 0 }

    // MARK: - Internal

    /// Copy with only the given fields replaced.
    ///
    /// Fields that can hold `nil` arrive as a double optional: `nil` means "leave
    /// it alone", `.some(nil)` means "clear it". Without that distinction there
    /// would be no way to erase `failureReason`, which is exactly what is needed
    /// when a session restarts after an error.
    private func replacing(
        status: SessionStatus? = nil,
        workspace: Workspace? = nil,
        lastMessage: String?? = nil,
        updatedAt: Date? = nil,
        statusSince: Date? = nil,
        failureReason: StopFailureReason?? = nil,
        harness: Harness? = nil,
        git: GitIdentity? = nil,
        pendingAsk: PendingAsk?? = nil,
        activeAgentIds: Set<String>? = nil,
        transcriptPath: String?? = nil,
        waitingOn: [String]? = nil,
        entrypoint: String?? = nil,
        origin: SessionOrigin? = nil,
        title: String?? = nil,
        context: ContextReading?? = nil
    ) -> SessionState {
        SessionState(
            id: id,
            status: status ?? baseStatus,
            workspace: workspace ?? self.workspace,
            lastMessage: lastMessage ?? self.lastMessage,
            updatedAt: updatedAt ?? self.updatedAt,
            statusSince: statusSince ?? self.statusSince,
            failureReason: failureReason ?? self.failureReason,
            harness: harness ?? self.harness,
            git: git ?? self.git,
            pendingAsk: pendingAsk ?? self.pendingAsk,
            activeAgentIds: activeAgentIds ?? self.activeAgentIds,
            transcriptPath: transcriptPath ?? self.transcriptPath,
            waitingOn: waitingOn ?? self.waitingOn,
            entrypoint: entrypoint ?? self.entrypoint,
            origin: origin ?? self.origin,
            title: title ?? self.title,
            context: context ?? self.context,
            firstSeenAt: firstSeenAt
        )
    }
}
