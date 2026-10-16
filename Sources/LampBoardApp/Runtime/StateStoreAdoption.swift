import LampBoardCore
import Foundation

/// Where the rows come from that nobody announced.
///
/// Split out of `StateStore` at the 800-line ceiling, and the seam is a real
/// one. What stays there is the store as a store: signals arrive, the reducer
/// decides, the column changes. What left is the opposite motion — the two
/// surfaces that never send a signal at all and have to be **found**, on a
/// timer, by looking at the disk.
///
/// They are here together because they share the discipline, not the mechanism.
/// A Codex session is found by the rollout a live process holds open; a Claude
/// Desktop conversation by the index and transcript the application keeps beside
/// it. Both obey the same two rules: what a probe could not see is never read as
/// gone, and a state nobody reported is never dressed up as one that was.
extension StateStore {

    // MARK: - Where a hook from an unclaimed folder belongs (moved from StateStore at 800 lines)

    /// A background session's folder, or else, for a signal no folder claims,
    /// a terminal session's: from the signal's live file, read once. The rule
    /// is `LiveAdoption.home`, shared with the node.
    func liveHome(for signal: HookSignal, claimed: Bool) -> (workspace: Workspace, origin: SessionOrigin)? {
        // In tmux or in LampBoard's own terminal, its own folder, whatever editor
        // window contains it: one open on the home folder claimed every project
        // (a person, on 2.1.0, and again on 2.2.6 for a session that ends when closed).
        LiveAdoption.home(
            of: liveFile(for: signal), claimed: claimed, showsTerminalSessions: showsTerminalSessions,
            hasOwnFolder: Self.hasOwnFolder
        )
    }

    /// Whether a live session's process runs in tmux or in LampBoard's own
    /// terminal: in either, no editor window hosts it.
    nonisolated static func hasOwnFolder(_ session: LiveSession) -> Bool {
        guard session.pid > 1 else { return false }
        let ancestry = ProcessTree.ancestry(of: pid_t(session.pid))
        return TmuxPlace.runsInTmux(ancestry: ancestry)
            || TmuxPlace.runsInLampBoard(ancestry: ancestry, lampBoard: ProcessInfo.processInfo.processIdentifier)
    }

    /// The signal's own live file, read once for both questions above: each
    /// read opens every session's file and asks after every process, and a
    /// hook arrived to two of them (P1, 10 October 2026).
    func liveFile(for signal: HookSignal) -> LiveSession? {
        guard signal.host == nil, signal.deservesTrafficLight else { return nil }
        return liveSessionReader.readLiveSessions()
            .first(where: { $0.sessionId == signal.sessionId && $0.host == nil && $0.deservesTrafficLight })
    }

    /// Adopts the Claude Desktop conversations running on this Mac, and returns
    /// their ids so the sweep does not take them straight back.
    ///
    /// Two things here are unlike every other row, and both are declared rather
    /// than hidden.
    ///
    /// The colour is **derived**. A Claude Desktop conversation runs with its
    /// own `CLAUDE_CONFIG_DIR` and never reads the hooks on this machine, so
    /// nothing reports what it is doing; what it leaves is its transcript, and
    /// what a transcript can say is whether a turn is running or has ended. That
    /// is read on a timer, which is why it moves through `.derive` and only ever
    /// forward in time — see the action for what happens otherwise.
    ///
    /// The row's life is **not** the agent process's. That process lives one
    /// turn: built on it, a row appeared while the model worked and vanished the
    /// moment there was an answer. See `ClaudeDesktopScanner` for the
    /// measurement and for what replaced it.
    ///
    /// Cloud sessions are not here and cannot be: they run on Anthropic's
    /// servers and leave nothing on this machine to read.
    /// The Claude Code sessions already running when nobody was watching.
    ///
    /// Every `claude` writes a file into `~/.claude/sessions` when it starts, and
    /// this is what turns those files into rows: after a restart of the panel it
    /// is the only way a session that is not currently speaking appears at all.
    ///
    /// Moved here from the poll when `StateStore` reached the eight hundred lines
    /// this project holds itself to. It belongs with its neighbours rather than
    /// beside the signal intake: like them it is a surface that never announces
    /// itself and has to be found by looking at the disk.
    func adoptLiveSessions(_ live: [LiveSession], windows: [IDEWindow], at now: Date) {
        for session in live where session.host == nil {
            // A live process with nothing to show is not a row. The same rule the
            // signal intake applies, at the other door: this one adopts sessions
            // from their files, and those files are written by every `claude` that
            // starts, including the ones nobody will ever type into.
            guard conversations.hasConversation(sessionId: session.sessionId, cwd: session.cwd) else {
                continue
            }
            // A background session's place is the panel, whatever window has its
            // folder open (AV1); in tmux or LampBoard's own terminal, no editor
            // window's either; unclaimed with terminal sessions on (D25), the
            // file's own folder. The rule is `LiveAdoption.placement`, shared
            // with the node.
            guard let place = LiveAdoption.placement(
                of: session, windows: windows, showsTerminalSessions: showsTerminalSessions, at: now,
                hasOwnFolder: Self.hasOwnFolder
            ) else {
                continue
            }
            let (workspace, origin) = place
            let known = state.sessions[session.sessionId] != nil
            // `idle` unless Claude Code says `busy`: see `LiveAdoption.adopted`
            // for why a row never seen is not inferred to be working.
            apply(.adopt(LiveAdoption.adopted(session, in: workspace, origin: origin)), now: now)
            if !known {
                if origin == .terminal {
                    Diagnostics.log(
                        "adopted as a terminal session: \(session.sessionId.prefix(8)) in \(session.cwd)"
                    )
                }
                requestTitleIfMissing(sessionId: session.sessionId)
            }
        }
    }

    func adoptDesktopSessions(at now: Date) -> Set<String> {
        guard case .observed(let evidence) = desktopScanner.scan() else {
            // A probe that could not answer removes nothing. Every row it would
            // have confirmed stays, which is why the sweep is handed what the
            // store already holds rather than an empty set.
            return Set(state.sessions.values.filter { ClaudeDesktop.isEntrypoint($0.entrypoint) }.map(\.id))
        }

        for item in evidence {
            let derived = DesktopConversation.derivation(
                isAnswering: item.isAnswering, phase: item.phase,
                lastActivity: item.lastActivity, observedAt: now
            )
            let status = derived.status

            guard let known = state.sessions[item.id] else {
                apply(
                    .adopt(
                        SessionState(
                            id: item.id,
                            status: status,
                            workspace: desktopWorkspace(of: item),
                            updatedAt: item.lastActivity,
                            statusSince: item.lastActivity,
                            transcriptPath: item.transcriptPath,
                            entrypoint: ClaudeDesktop.entrypoint,
                            title: item.index.title
                        )
                    ),
                    now: now
                )
                Diagnostics.log(
                    "desktop adopted: \(item.id.prefix(8)) in \(desktopWorkspace(of: item).path) "
                        + "[\(item.index.title ?? "no title"), \(status.rawValue)]"
                )
                continue
            }

            guard status != known.status, derived.moment > known.statusSince else { continue }
            apply(.derive(sessionId: item.id, status: status, at: derived.moment), now: now)
            Diagnostics.log("desktop \(item.id.prefix(8)): \(known.status.rawValue) -> \(status.rawValue)")
        }

        return Set(evidence.map(\.id))
    }

    /// The folder the conversation is about.
    ///
    /// Never the session's own `cwd`: that is its `outputs` directory inside the
    /// application's data, which as a row label reads as a folder called
    /// `outputs` that you cannot go to. Taken from the folders the application
    /// itself resolved as living here, rather than from the first one somebody
    /// picked, because a conversation can hold a local folder and a remote one
    /// at once and only the local one is a place this Mac can open.
    private func desktopWorkspace(of item: DesktopEvidence) -> Workspace {
        Workspace(path: item.index.localFolders.first ?? item.index.folders.first ?? "")
    }

    /// Applies what the Codex probe found, and never asks for it here.
    ///
    /// The asking used to happen inline, on the actor that draws, every five
    /// seconds. Measured on this machine with the sweep instrumented: **80
    /// milliseconds of a 150-millisecond pass**, and every one of them a
    /// subprocess — `lsof` over every live `codex` pid, which was eighteen of
    /// them here. A second audit called this out as a worst case; the steady
    /// state was already the problem.
    ///
    /// So the probe runs on an actor of its own and hands its answer back, and
    /// what is left here is arithmetic on a value: microseconds. See
    /// `StateStore.refreshCodexProbe`.
    func adoptCodexSessions(_ result: CodexScanResult, at now: Date) {
        // A probe that could not answer removes nothing and forgets nothing:
        // the set of confirmed ids stays as it was, so the age rule at the end
        // of the sweep does not take rows the probe simply could not reach.
        // The rule itself is in `CodexAdmission`, where a test can hand it an
        // unavailable probe without having to make `lsof` hang for real.
        let known = Set(state.sessions.values.filter { $0.harness == .codex }.map(\.id))
        guard let verdict = CodexAdmission.verdict(on: result, holding: known) else { return }
        rememberLiveCodex(verdict.alive)

        for item in verdict.arriving {
            apply(
                .adopt(
                    SessionState(
                        id: item.meta.sessionId,
                        status: .idle,
                        workspace: Workspace(path: item.meta.cwd),
                        updatedAt: item.lastActivity,
                        statusSince: item.lastActivity,
                        harness: .codex,
                        transcriptPath: item.rolloutPath,
                        entrypoint: item.surface.entrypoint
                    )
                ),
                now: now
            )
            Diagnostics.log(
                "codex adopted: \(item.meta.sessionId.prefix(8)) in \(item.meta.cwd) "
                    + "[\(item.surface.label), pid \(item.pid)]"
            )
        }

        // Only what a process is still holding open survives. Closing the
        // conversation closes the descriptor, and that is the one signal Codex
        // gives us for free.
        apply(
            .reconcile(alive: verdict.alive, harness: .codex, evenIfEmpty: true),
            now: now
        )
    }

}

extension StateStore {
    /// A session's permission mode, kept before anything may drop its signal
    /// (D139). A subagent's signal carries the mode it runs in, inherited from
    /// its session unless its definition says otherwise.
    func hearMode(_ signal: HookSignal) {
        if let mode = signal.permissionMode {
            permissionModes[signal.sessionId] = mode
            permissionModesHeardAt[signal.sessionId] = Date()
        }
    }

    /// Claude Code's own `busy` lights a row known only as idle (D141): yellow,
    /// or blue where another machine's probe saw the turn closed with background
    /// work registered (`LiveSession.statusFromFile`).
    func lightBusy(_ sessions: [LiveSession], at now: Date) {
        for session in sessions where session.isBusy {
            apply(.busy(sessionId: session.sessionId, status: session.statusFromFile), now: now)
        }
    }

    /// The sessions resting on `host`, found rather than announced (D137): a
    /// row each, idle until its first hook says otherwise, named as Claude Code
    /// names it there. A row that already exists is left alone.
    ///
    /// Called with each fresh answer, never from the five-second pass: between
    /// answers the list is up to twenty seconds old, and a session that has
    /// just ended would come back from it as a ghost.
    func adoptRemoteSessions(_ live: [LiveSession], host: String, at now: Date) {
        guard remoteHosts.contains(host) else { return }
        for session in RemoteAdoption.adoptable(live, showsTerminalSessions: showsTerminalSessions)
        where state.sessions[session.sessionId] == nil {
            let workspace = RemoteWorkspaceResolver.resolve(
                cwd: session.cwd, sessionId: session.sessionId, host: host,
                windows: remoteWindows[host] ?? [], sessions: live, at: now
            )
            apply(.adopt(RemoteAdoption.adopted(session, in: workspace)), now: now)
            Diagnostics.log("remote \(host): adopted \(session.sessionId.prefix(8)) in \(session.cwd)")
        }
    }

    /// Where a remote session sits in tmux, as its own machine's probe last said (D132).
    /// The process in tmux when the conversation has another one too (a VS Code
    /// window opened on it): the Hub's terminal is that one (13 October 2026:
    /// Cervello, in tmux and in VS Code, was read instead of shown).
    func remoteTmuxPlace(sessionId: String, host: String) -> TmuxPlace? {
        remoteSessions[host]?.first { $0.sessionId == sessionId && $0.tmux != nil }?.tmux
    }

    /// How many processes on `host` hold the conversation: more than one is two
    /// writers, and the conversation forks.
    func remoteHolders(sessionId: String, host: String) -> [String] {
        (remoteSessions[host] ?? []).filter { $0.sessionId == sessionId }.map { live in
            if let place = live.tmux { return "tmux «\(place.session)»" }
            switch live.entrypoint {
            case "claude-vscode": return "VS Code"
            case "claude-desktop": return "the Claude app"
            default: return "a terminal"
            }
        }
    }

    /// A session LampBoard started in tmux, once its machine's probe has found
    /// it by its tag: from then on a window's header names it like its row.
    func placed(_ target: LiveTarget) -> LiveTarget {
        guard case .newTmux(let host, _, _, let launch, _) = target,
              let found = remoteSessions[host]?.first(where: { $0.tmux?.launch == launch }), let place = found.tmux
        else { return target }
        return .tmux(host: host, place: place, sessionId: found.sessionId)
    }
}
