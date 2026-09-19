import LampBoardCore
import Combine
import Foundation

/// The interface's source of truth.
///
/// Holds the state as an immutable value and replaces it on every action by going
/// through the reducer. All mutations happen on the main actor, so views can never
/// observe a state that is halfway through an update.
@MainActor
final class StateStore: ObservableObject {

    @Published private(set) var state: TrafficLightState = .empty

    /// Last diagnostic error, shown in the context menu.
    @Published private(set) var lastError: String?

    /// The same fault as a value, when it is one the user can act on.
    ///
    /// Kept beside the sentence rather than parsed out of it: the panel needs to
    /// decide whether to offer a button, and which pane that button opens, and
    /// neither question can be answered by reading English back.
    @Published private(set) var issue: PanelIssue?

    private let windowReader: IDEWindowReader
    private let liveSessionReader: LiveSessionReader
    private let clock: () -> Date
    private let snapshots: SnapshotBox?
    private let preferences: Preferences
    /// Finds Codex sessions that will never send a signal.
    // Not private, and deliberately: these two and the one action below are what
    // `StateStoreAdoption` needs, and that file exists because this one reached
    // the ceiling the project sets itself. The same seam `PanelActivation` opened
    // in `PanelController`, for the same reason.
    /// The Codex probe lives on an actor of its own: it spawns a subprocess, and
    /// this store draws. See `CodexProbe` for the measurement that moved it.
    private let codexProbe = CodexProbe()
    private var codexScanInFlight = false

    /// The Codex sessions a process was last seen holding open.
    ///
    /// Kept because the twelve-hour prune at the end of a sweep asks "who is
    /// confirmed?", and the answer for Codex arrives from another actor a moment
    /// later. Without it, six rows for conversations that had been open since
    /// yesterday were pruned for being old and re-adopted when the probe
    /// answered — every five seconds, which is what a panel flickering looks
    /// like from the outside.
    ///
    /// It is also the right answer and not only the convenient one: a Codex row
    /// exists because a live process holds its rollout open, and that is a
    /// confirmation. The age rule is the bound for rows nobody can confirm.
    private var liveCodexIds: Set<String> = []

    /// Records what the last Codex probe confirmed. Internal, because the
    /// adoption that learns it lives in `StateStoreAdoption`.
    func rememberLiveCodex(_ ids: Set<String>) { liveCodexIds = ids }

    let desktopScanner = ClaudeDesktopScanner()

    private var pollTimer: Timer?
    private var remoteTimer: Timer?

    init(
        windowReader: IDEWindowReader = IDEWindowReader(),
        liveSessionReader: LiveSessionReader = LiveSessionReader(),
        clock: @escaping () -> Date = Date.init,
        snapshots: SnapshotBox? = nil,
        preferences: Preferences = Preferences()
    ) {
        self.windowReader = windowReader
        self.liveSessionReader = liveSessionReader
        self.clock = clock
        self.snapshots = snapshots
        self.preferences = preferences

        // The rows the user took off, from the last time the panel ran. Without
        // this a restart brings back every discovered row that was cleared away,
        // and the reason it was cleared has not changed in the meantime: a chat
        // tab closed while its process stayed loaded is still closed. Entries
        // past `sessionStaleAfter` are dropped by the reader, so this cannot grow
        // into a list that quietly hides a session somebody wants back.
        state = TrafficLightState(dismissed: preferences.dismissedSessions)
    }

    // MARK: - Other machines

    /// The last answer each remote host gave, kept between polls. A host with no
    /// entry has never answered since it was configured.
    ///
    /// Kept, and not re-read on every local pass, for two reasons. The local poll
    /// runs every few seconds and an ssh handshake does not belong on that
    /// cadence; and `reconcile` filters the column down to the sessions it is
    /// handed, so a remote row must be in that set on **every** pass or it would
    /// be erased four times a minute between remote reads.
    ///
    /// A host that fails to answer keeps its previous entry. Silence is not death
    /// — the same rule that stopped this app pruning live local sessions.
    private var remoteSessions: [String: [LiveSession]] = [:]

    /// Which sessions have ever held a conversation. See `ConversationIndex` for
    /// why a live process is not enough to earn a row.
    let conversations = ConversationIndex()

    /// When each host's last answer was **asked for** — not received. A probe may
    /// only declare dead what it looked for after a row's last sign of life: a
    /// session that spoke through the tunnel after the probe started is not
    /// "missing from the answer", it is newer than the question.
    private var remoteAnsweredAt: [String: Date] = [:]

    /// `true` while a pass over the hosts is running off the main actor. A pass
    /// slower than the timer is skipped, not queued: two unreachable hosts would
    /// otherwise stack passes forever.
    private var isProbing = false

    /// The hosts to ask, as configured in the settings.
    private var remoteHosts: [String] { preferences.remoteHosts }

    /// Whether folders no editor claims get rows (D25), as configured.
    var showsTerminalSessions: Bool { preferences.showsTerminalSessions }

    /// Sessions whose transcript is being read for a title right now, so a
    /// burst of signals does not start a read per signal.
    private var titleReadsInFlight: Set<String> = []

    /// Reads how full each local session's context is, cached on file size.
    private let contextReader = ContextReader()
    private var contextReadsInFlight: Set<String> = []

    // MARK: - Terminal sessions

    /// The folder a terminal row is anchored on, for a signal nothing claims:
    /// the `cwd` of the session's live file, or `nil` when there is no such
    /// file, the feature is off, the signal names a host, or nobody is in front
    /// of the session (`sdk`, `print`).
    private func terminalHome(for signal: HookSignal) -> Workspace? {
        guard showsTerminalSessions, signal.host == nil, signal.deservesTrafficLight else { return nil }
        guard let file = liveSessionReader.readLiveSessions()
            .first(where: { $0.sessionId == signal.sessionId && $0.host == nil && $0.deservesTrafficLight })
        else { return nil }
        return Workspace(path: file.cwd)
    }

    /// What "Show terminal sessions" turning off does, at once.
    func forgetTerminalSessions() {
        apply(.forget(origin: .terminal), now: clock())
    }

    /// Adopts the Codex sessions a live process is holding a rollout open for.
    ///
    /// They arrive this way because they arrive no other way. Codex inside the
    /// ChatGPT app registers our hooks, marks them trusted, runs a full session
    /// and sends nothing: measured, with eight events configured and not one line
    /// in the log. A row for it has to be found rather than announced.
    ///
    /// Three rules hold the honesty of it together.
    ///
    /// The folder comes from the rollout's own first record, never from anything
    /// sent to us. That is the replacement for the admission gate, not its
    /// removal: the old bound was a Claude Code window lock, which a machine
    /// running only Codex does not have.
    ///
    /// The state is **idle**, which here means the absence of information rather
    /// than a claim, exactly as it does for a Claude session adopted from disk. An
    /// open descriptor proves a conversation is loaded in a live program; it does
    /// not prove the model is doing anything, and the editor extension was
    /// observed holding open a rollout whose last record was a year old. Reading
    /// turns out of the rollout is a separate capability and needs fixtures, a
    /// gate and a version, because the format is declared unstable by the people
    /// who write it.
    ///
    /// And a probe that could not answer removes nothing. `lsof` stats every open
    /// descriptor, so a network mount whose server has gone away stops it: that is
    /// absence of evidence, and this project already draws the same line for a
    /// remote host that has gone quiet.
    /// Reads the conversation's title off the main actor and remembers it.
    ///
    /// For any session that has none yet, wherever it runs. It used to be for
    /// terminal rows only, on the reasoning that an editor row is named by its
    /// folder anyway. That reasoning held while a folder meant one session: three
    /// conversations open in the same project were then three rows called the
    /// same thing, separable only by a UUID the panel never shows. The title is
    /// what tells them apart, so every session earns one.
    ///
    /// Called when the row is born and at every `Stop` while it is still unnamed:
    /// a title appears after the first exchange, not before.
    func requestTitleIfMissing(sessionId: String) {
        guard let session = state.sessions[sessionId],
              session.title == nil, !titleReadsInFlight.contains(sessionId)
        else { return }
        // The hook's word first — a session in a git worktree keeps its transcript
        // where the derivation would not look — then the derived place, for a row
        // adopted from the filesystem before its first hook.
        let derived = TranscriptLocator.candidateURL(sessionId: sessionId, cwd: session.workspace.path).path
        let path = session.transcriptPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? derived

        // No file, no read. The check costs one `stat` on this actor and saves a
        // detached task plus a hop back for a session whose transcript does not
        // exist yet, which is every session in its first instants and every one
        // that will never have a transcript at all. It stopped mattering the
        // moment this stopped being for terminal rows only: twenty-two sessions
        // arriving together used to mean twenty-two reads of nothing.
        guard FileManager.default.fileExists(atPath: path) else { return }

        titleReadsInFlight.insert(sessionId)
        Task.detached(priority: .utility) { [weak self] in
            let title = SessionTitleReader.title(atPath: path)
            // Unwrapped here and not inside the hop: weak for the read, which is
            // the slow part and the reason the reference is weak at all, then a
            // plain value for the actor. Unwrapping inside `MainActor.run` makes
            // that closure capture the *variable*, which Swift 6 rejects — the
            // warning was a compile error waiting for the language mode to move.
            guard let self else { return }
            await MainActor.run {
                self.titleReadsInFlight.remove(sessionId)
                if let title { self.apply(.remember(sessionId: sessionId, title: title), now: self.clock()) }
            }
        }
    }

    /// Refreshes how full a session's context is, from its transcript.
    ///
    /// Off the actor, like the title read and for the same reason: this seeks
    /// into a file that can be a hundred megabytes, and the thread it must not
    /// do that on is the one drawing the panel. Remote sessions are skipped —
    /// their transcript is not a file here, and their reading arrives from the
    /// probe that stands where it is.
    private func refreshContext(sessionId: String) {
        guard let session = state.sessions[sessionId], session.workspace.host == nil,
              !contextReadsInFlight.contains(sessionId)
        else { return }

        let harness = session.harness
        // The derived path is Claude Code's scheme — one file per session under a
        // folder named after the project — and it exists because a session can be
        // seen before it has ever sent a hook. Codex files its rollouts by date
        // instead, so there is nothing to derive: a Codex row without a path in
        // its payload simply has no reading yet, which is the truth and not a
        // failure. Deriving a Claude path for it would open somebody else's file.
        let derived = harness == .claudeCode
            ? TranscriptLocator.candidateURL(
                sessionId: sessionId, cwd: session.workspace.path
            ).path
            : nil
        guard let path = session.transcriptPath.flatMap({
            FileManager.default.fileExists(atPath: $0) ? $0 : nil
        }) ?? derived,
            FileManager.default.fileExists(atPath: path)
        else { return }

        contextReadsInFlight.insert(sessionId)
        // Captured here, on the actor, so the detached task never reaches back
        // for a main-actor property: `await self.contextReader…` compiles and
        // quietly performs the read on the main thread.
        let reader = contextReader
        Task.detached(priority: .utility) { [weak self] in
            let reading = await reader.reading(
                ofTranscriptAt: path, for: sessionId, harness: harness
            )
            guard let self else { return }
            await MainActor.run {
                self.contextReadsInFlight.remove(sessionId)
                // A read that came back empty is not news. The transcript can be
                // mid-rotation, mid-compaction, or simply not there for one poll,
                // and publishing that as an observation would blank the ring on a
                // session that is still working. The last figure we did read stays
                // until a better one arrives.
                guard let reading else { return }
                self.apply(.observed(sessionId: sessionId, context: reading), now: self.clock())
            }
        }
    }

    /// Every remote session currently believed to exist.
    private var knownRemote: [LiveSession] {
        remoteSessions.values.flatMap { $0 }
    }

    /// Asks each configured host, on its own slow timer.
    func pollRemoteHosts() {
        let hosts = remoteHosts

        // A host removed from the settings takes its answers with it, so its rows
        // stop being confirmed and go on the next pass rather than lingering.
        for gone in remoteSessions.keys where !hosts.contains(gone) {
            remoteSessions.removeValue(forKey: gone)
            remoteAnsweredAt.removeValue(forKey: gone)
        }

        guard !hosts.isEmpty else {
            poll()
            return
        }
        guard !isProbing else { return }
        isProbing = true

        // The ssh handshakes happen **off the main actor**. The first version
        // awaited them on it, and with one unreachable host the panel, the click
        // and the chat window froze for the connect timeout every twenty seconds —
        // and a host is unreachable exactly when its tunnel is down, which is the
        // common case this feature exists for.
        let startedAt = clock()
        Task.detached(priority: .utility) { [weak self] in
            let answers = hosts.map { host in
                (host: host, sessions: RemoteSessionReader(host: host).readLiveSessions())
            }
            await MainActor.run { [weak self] in
                self?.absorbRemoteAnswers(answers, askedAt: startedAt)
            }
        }
    }

    /// Records what the hosts said, then realigns the column.
    private func absorbRemoteAnswers(
        _ answers: [(host: String, sessions: [LiveSession]?)], askedAt: Date
    ) {
        isProbing = false
        for (host, sessions) in answers {
            guard let sessions else {
                // No answer. Keep what we had and say so once.
                Diagnostics.log("remote \(host): no answer, keeping \(remoteSessions[host]?.count ?? 0) known rows")
                continue
            }
            // The whole answer, unfiltered: it is a confirmation set now, not a
            // list of rows to create, and a session that spoke through the tunnel
            // must be confirmable whatever its file says about its kind.
            if sessions.count != (remoteSessions[host]?.count ?? -1) {
                Diagnostics.log("remote \(host): \(sessions.count) sessions")
            }
            remoteSessions[host] = sessions
            remoteAnsweredAt[host] = askedAt

            // What the probe read of each session's context, on the machine
            // where its transcript actually is. `.observed` attaches it to a row
            // that already exists and creates none — a remote session earns its
            // row by speaking through the tunnel, not by being seen.
            for session in sessions {
                guard let reading = session.context else { continue }
                apply(
                    .observed(sessionId: session.sessionId, context: reading),
                    now: askedAt
                )
            }
        }

        // An answer that is days old is not an answer. Dropping it puts the host
        // back among the silent ones: its rows are no longer confirmed or denied,
        // and only the age rule can remove them.
        let staleBefore = clock().addingTimeInterval(-AppConfig.remotePollInterval * 10)
        for (host, askedAt) in remoteAnsweredAt where askedAt < staleBefore {
            Diagnostics.log("remote \(host): last answer is stale, forgetting it")
            remoteSessions.removeValue(forKey: host)
            remoteAnsweredAt.removeValue(forKey: host)
        }
        poll()
    }

    var sessions: [SessionState] { state.ordered }

    // MARK: - Signal intake

    /// Applies a hook signal, first resolving the workspace hosting it.
    func handle(_ signal: HookSignal) {
        let now = clock()

        // A process announcing itself is not a conversation, and only a
        // conversation earns a row. `ConversationIndex` carries the reasoning and
        // the cost.
        guard conversations.startIsWorthARow(
            signal, alreadyKnown: state.sessions[signal.sessionId] != nil
        ) else {
            Diagnostics.log("session start with no conversation behind it: \(signal.sessionId.prefix(8))")
            return
        }

        var workspace: Workspace?
        if let host = signal.host, remoteHosts.contains(host) {
            // Through the tunnel. No lock on this machine can claim a folder that
            // lives on another one, so the session's own folder is the workspace,
            // and the host travels with it — that is what the click will raise.
            workspace = Workspace(path: signal.cwd, host: host)
        } else {
            if let host = signal.host {
                // A host this app was never told about is a header anyone on
                // loopback could have written. It does not get to skip the gate
                // that bounds every local signal.
                Diagnostics.log("signal names unknown host \(host); treated as local")
            }
            workspace = WorkspaceResolver.resolve(
                cwd: signal.cwd,
                in: windowReader.readWindows(),
                at: now
            )
        }

        // A folder nobody claims is a place too (D25): with terminal sessions
        // on, the row's folder is the one the session **file** names — the hook's
        // cwd follows every `cd` Claude makes, the file's is written once — and
        // there is a row only if such a file exists and its process is alive. A
        // signal alone is not enough: that condition is what keeps out a forged
        // host header treated as local, a path from another machine, and a
        // process already gone.
        var origin = SessionOrigin.editor
        if workspace == nil, let home = terminalHome(for: signal) {
            workspace = home
            origin = .terminal
        }

        // A session that already has a row keeps it, whatever the gate says about
        // its folder now.
        //
        // The gate decides **admission**, not updates: it exists so that a path
        // from another machine, a forged host header or a process already gone
        // cannot conjure a row. None of that is in question once the row is
        // there — it was admitted by evidence of its own, and a signal naming it
        // can only move its colour.
        //
        // What this cost: every Codex session running in a terminal. The scanner
        // adopts it from the rollout a live process holds open, which is the only
        // way that surface is ever seen, and then every hook it sent was dropped
        // because no Claude Code window claims that folder and no Claude session
        // file names the session. Six rows on this Mac, born idle and idle for
        // ever, in kitty, iTerm2, WezTerm and Ghostty alike. The same drop is
        // what silences a VS Code window between a restart and its reconnection,
        // for a session the column is already showing.
        //
        // And for a row **found** rather than announced, the folder stays the one
        // it was found in, whatever the signal says.
        //
        // This paragraph used to claim that outright and the code did not do it:
        // the resolver ran first, and a hook whose `cwd` matched any open editor
        // window moved the row into that window's project. A comment that
        // describes a guarantee the code does not give is worse than no comment,
        // because the next person stops looking.
        //
        // The distinction is `wasFound`. A Claude Code session that
        // announces itself may move — opening its directory in an editor really
        // does move it there (D25). A Codex or Claude Desktop row may not: its
        // folder came from a rollout or an index before any hook existed, and a
        // hook can only move its colour.
        if let known = state.sessions[signal.sessionId], known.wasFound || workspace == nil {
            workspace = known.workspace
            origin = known.origin
        }

        // A signal whose `cwd` matches no editor window is discarded — there is no
        // row to put it on. That is correct, and it used to be **silent**, which is
        // not.
        //
        // The case that showed why: after restarting the Mac, a VS Code window has
        // no lock file until its Claude panel reconnects. Every hook from that
        // window is dropped in the meantime, so a turn finishes and the light never
        // goes green — with nothing anywhere saying why. From the outside it looks
        // exactly like the traffic light being broken.
        //
        // Nothing changes about the behavior. What changes is that the log now
        // names the workspace nobody claimed, so the next hour of this goes into
        // reading one line instead of bisecting the app.
        if workspace == nil {
            Diagnostics.log(
                "signal dropped: \(signal.event.rawValue) for \(signal.cwd), "
                    + "no editor window claims that folder "
                    + (showsTerminalSessions
                        ? "and no live session file names the session"
                        : "(a window that has not reconnected writes no lock; terminal sessions are off)")
            )
        }

        let before = state.sessions[signal.sessionId]?.status.rawValue ?? "absent"
        apply(.signal(signal, workspace: workspace, origin: origin), now: now)
        let after = state.sessions[signal.sessionId]?.status.rawValue ?? "absent"
        if before == "absent" || signal.event == .stop {
            requestTitleIfMissing(sessionId: signal.sessionId)
        }

        // Every signal, and what it did to the color.
        //
        // This is the instrument the project spent three separate evenings without.
        // "The light is wrong" could only be answered by reasoning about which of
        // eight events might have arrived in what order — and reasoning is exactly
        // what produced the wrong answers, twice. One line per hook turns that into
        // reading.
        //
        // It names the **transition**, not the payload: the question is always
        // "what turned it that color", never "what were the bytes".
        let subagent = signal.isFromSubagent ? " [subagent]" : ""
        let source = signal.sessionSource.map { " source=\($0)" } ?? ""
        let kind = signal.notificationKind.map { "/\($0.rawValue)" } ?? ""
        // A `Stop` that leaves a row yellow is only readable if the line says what
        // held it. The count was not enough: one session sat yellow for a day with
        // no background shell ever launched, and the log could only say "something".
        let types = signal.inFlightBackgroundTaskTypes
        let inFlight = types.isEmpty ? "" : " inFlight=\(types.count)[\(types.joined(separator: ","))]"
        let fromHost = signal.host.map { " host=\($0)" } ?? ""
        Diagnostics.log(
            "signal \(signal.event.rawValue)\(kind) "
                + "session=\(signal.sessionId.prefix(8)) "
                + "\(before) -> \(after)\(subagent)\(source)\(inFlight)\(fromHost)"
        )
    }

    /// The user opened the session: the unread states are cleared.
    func markSeen(sessionId: String) {
        apply(.markSeen(sessionId: sessionId), now: clock())
    }

    /// Takes one row off the column, at the user's request.
    ///
    /// The sweep that follows would put a discovered row straight back — the
    /// process is alive and the rollout open, which is what made the row outlive
    /// its tab — so the reducer keeps the moment and admits it again only on
    /// something newer. See `TrafficLightState.dismissed`.
    func dismiss(sessionId: String) {
        apply(.dismiss(sessionId: sessionId), now: clock())
    }

    /// Remedy for one click too many: the row goes back to "there is something to read".
    func markUnread(sessionId: String) {
        apply(.markUnread(sessionId: sessionId), now: clock())
    }

    func reset() {
        apply(.reset, now: clock())
    }

    func reportError(_ message: String, issue: PanelIssue? = nil) {
        lastError = message
        self.issue = issue
    }

    /// Clears the last error after a successful operation, so the menu doesn't
    /// keep showing a fault that has already gone away.
    func clearError() {
        guard lastError != nil || issue != nil else { return }
        lastError = nil
        issue = nil
    }

    // MARK: - Periodic realignment

    /// Starts the periodic realignment against the live Claude Code processes.
    ///
    /// It does two things the hooks cannot, because they only report what happens
    /// and never what disappeared or what was already there: it removes the rows
    /// whose process has died, and it adopts the sessions opened before the app
    /// started — which would otherwise stay invisible until you did something in
    /// that window.
    func startPolling(every interval: TimeInterval = AppConfig.liveSessionPollInterval) {
        pollTimer?.invalidate()
        poll()

        // What the snapshot says about a session — its slot, its name, whether it
        // is muted — comes from the preferences, and a preference can change with
        // the state standing still: a rename, a drag, `lampboard rename` from
        // another process. Republish on every change of the defaults, and on
        // every poll as a floor, so no reader is ever more than one poll behind.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.republish() }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        startRemotePolling()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
    }

    /// Asks the other machines on their own, much slower timer.
    ///
    /// Separate from the local one because each host costs a process spawn and an
    /// ssh handshake: putting that on the local cadence would mean an ssh every
    /// five seconds for a column that changes far less often than that.
    private func startRemotePolling(
        every interval: TimeInterval = AppConfig.remotePollInterval
    ) {
        remoteTimer?.invalidate()
        // Off the first pass: the app has to show the local column immediately,
        // and an unreachable host must never be what delays it.
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task.detached { [weak self] in
                guard let self else { return }
                await self.pollRemoteHosts()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        remoteTimer = timer
    }

    /// One realignment pass.
    func poll() {
        let started = Date()
        var cost = SweepCost()
        defer { SweepLog.record(from: started, cost) }
        let now = clock()
        let live = cost.spending(\.live) {
            liveSessionReader.readLiveSessions().filter(\.deservesTrafficLight)
        }
        let windows = cost.spending(\.windows) { windowReader.readWindows() }

        // Remote rows are **confirmed** here, never created. A session on another
        // machine gets its row when it speaks — its hooks reach this machine
        // through the tunnel — and loses it when that machine's probe no longer
        // lists its pid. The first version adopted every session the probe found
        // as a red row, and that produced a column of things nobody had opened
        // and nothing could open: a `claude` left in a detached tmux for two days
        // is real, and it is not a window you can click.
        //
        // `reconcile` keeps only what it is handed, so every remote row that must
        // survive has to be in the set: the ones the probe confirmed, and the ones
        // it **could not have seen** — on a configured host that has not answered
        // yet (silence is not death), or newer than the question the host last
        // answered (a session that spoke after the probe started is not missing
        // from the answer). Without the second clause every new remote session
        // was erased by the next local pass, five seconds after its first hook,
        // and came back only when it spoke again. A row on a host no longer
        // configured is in neither set and goes.
        let configured = Set(remoteHosts)
        let unconfirmed = state.sessions.values.compactMap { session -> String? in
            guard let host = session.workspace.host, configured.contains(host) else { return nil }
            guard let askedAt = remoteAnsweredAt[host], remoteSessions[host] != nil else { return session.id }
            return session.updatedAt > askedAt ? session.id : nil
        }
        // Claude Desktop's local sessions are Claude Code sessions like any
        // other; they are simply written somewhere else. Adopted **before** the
        // sweep and counted among the living, because the sweep prunes by
        // harness and theirs is Claude Code: left out of the set they would be
        // born and erased in the same pass.
        let desktop = cost.spending(\.desktop) { adoptDesktopSessions(at: now) }

        let confirmed = Set(live.map(\.sessionId))
            .union(knownRemote.map(\.sessionId))
            .union(desktop)
        apply(.reconcile(alive: confirmed.union(unconfirmed)), now: now)

        // Started, not waited for. What it finds is applied when it answers,
        // which is the same five-second cadence one probe late.
        refreshCodexProbe()

        // The switch turning off takes its rows with it — here, so that a switch
        // flipped from the Settings window is honoured within one poll.
        if !showsTerminalSessions, state.sessions.values.contains(where: { $0.origin == .terminal }) {
            apply(.forget(origin: .terminal), now: now)
        }

        adoptLiveSessions(live, windows: windows, at: now)

        // Only what was actually confirmed is exempt from the age rule. A remote
        // row nobody can confirm — its host silent, its probe broken — must still
        // be bounded by the twelve-hour prune like every other mistake, or a
        // session killed without a `SessionEnd` stays in the column forever.
        // The Codex rows a descriptor confirms are exempt too. An open rollout
        // is a conversation loaded rather than a model working, so its last word
        // can be days old while the process holding it is very much alive.
        apply(.prune(alive: confirmed.union(liveCodexIds)), now: now)

        // The context readings, last: they change no colour and no order, so
        // they ride the tick that is already walking every session rather than
        // getting a timer of their own. An unchanged file costs one `stat`.
        for sessionId in state.sessions.keys { refreshContext(sessionId: sessionId) }

        republish()
    }

    /// Publishes the snapshot again with the preferences as they are now.
    func republish() {
        publishSnapshot()
    }

    // MARK: - Internal

    /// Asks the Codex probe, off this actor, and applies what it says when it
    /// says it.
    ///
    /// One at a time: a probe that runs long — `lsof` is documented to pause on a
    /// descriptor sitting on an unreachable mount — must not have a second one
    /// started on top of it every five seconds. The flag is read and written only
    /// here, on the main actor, so it needs nothing around it.
    ///
    /// A probe still in flight when the app stops simply applies its answer to a
    /// store nobody is polling any more, which changes a value and draws nothing.
    private func refreshCodexProbe() {
        guard !codexScanInFlight else { return }
        codexScanInFlight = true
        Task { [weak self] in
            guard let self else { return }
            // The suspension is the point: `scan()` runs on the probe's actor,
            // and only the arithmetic on its answer comes back here.
            let result = await self.codexProbe.scan()
            self.codexScanInFlight = false
            self.adoptCodexSessions(result, at: self.clock())
        }
    }

    func apply(_ action: ReducerAction, now: Date) {
        let next = StateReducer.reduce(state, action: action, now: now)
        guard next != state else { return }
        if Diagnostics.isEnabled, next.sessions.count < state.sessions.count {
            let gone = state.sessions.keys.filter { next.sessions[$0] == nil }
                .compactMap { state.sessions[$0] }
                .map { "\($0.id.prefix(8)) \($0.harness.rawValue)/\($0.entrypoint ?? "-")" }
            Diagnostics.log("lost \(gone.count) to \(action.label): \(gone.joined(separator: ", "))")
        }
        givePlaces(to: next)
        // Written here rather than in `dismiss`, because the register changes in
        // both directions: a row is taken off, and a row that speaks takes itself
        // back. Saving only the first would resurrect a dismissal at the next
        // restart for a session that had already returned.
        if next.dismissed != state.dismissed {
            preferences.dismissedSessions = next.dismissed
        }
        state = next
        publishSnapshot()
    }

    /// Every project in the state gets a place in the column's order, **before**
    /// the state is published: the first render that shows a project already
    /// knows where it goes, and a known project never moves (D23).
    ///
    /// Here and not in the panel, because the panel is one reader of the order
    /// among three — the extended window and `/sessions` are the others — and
    /// headless mode has no panel at all. An order that only the panel maintains
    /// is an order the CLI disagrees with.
    private func givePlaces(to next: TrafficLightState) {
        let order = preferences.rowOrder
        let merged = RowOrder.absorbing(next.sessions.values.map(\.workspace.key), into: order)
        if merged != order { preferences.rowOrder = merged }
    }

    /// Deposits the version readable by the HTTP server into the box.
    ///
    /// The slot and the mute flag are read from the preferences here rather than
    /// carried in `SessionState`: they are things the **user** decided about a
    /// project, not things Claude Code reported about a session, and the domain
    /// state has no business holding them.
    private func publishSnapshot() {
        guard let snapshots else { return }
        let order = preferences.rowOrder
        let muted = preferences.mutedWorkspaces
        let names = preferences.rowNames

        snapshots.replace(with: state.ordered.map { session in
            SessionsCodec.snapshot(
                of: session,
                muted: muted.contains(session.workspace.key),
                slot: RowOrder.slot(of: session.workspace.key, in: order, limit: AppConfig.maxSlots),
                alias: RowNames.name(of: session.workspace.key, in: names)
            )
        })
    }
}
