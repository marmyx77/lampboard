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
            let resolved = WorkspaceResolver.resolve(cwd: session.cwd, in: windows, at: now)
            // Unclaimed and terminal sessions on: the file's own folder is the
            // row's (D25) — the file is the anchor, so no `cd` can move it.
            guard let workspace = resolved ?? (showsTerminalSessions ? Workspace(path: session.cwd) : nil) else {
                continue
            }
            let origin: SessionOrigin = resolved == nil ? .terminal : .editor
            let known = state.sessions[session.sessionId] != nil
            // State `idle`: the app does not know what a session it has never seen
            // is doing, and this is where it says so.
            //
            // It was briefly inferred instead — "the transcript moved in the last
            // forty-five seconds, therefore a turn is in flight" — and that was
            // wrong in a way worth recording. A transcript is appended on plenty of
            // things that are not a turn, **resuming a session among them**. So
            // after a reboot, when Claude Code resumes everything at once, every
            // file moved at once and the whole column went yellow: twelve sessions
            // claiming to be working while none of them were.
            //
            // A column that is uniformly wrong is worse than one that is
            // uniformly cautious, because the panel exists to make the one session
            // that needs you stand out. `idle` here is not a guess dressed up as a
            // fact; it is the absence of information, and the first hook replaces it.
            //
            // The timestamp, by contrast, IS evidence and is kept: it comes from
            // the transcript, which is the only file that moves when a session
            // does something.
            apply(
                .adopt(
                    SessionState(
                        id: session.sessionId,
                        status: .idle,
                        workspace: workspace,
                        updatedAt: session.modifiedAt,
                        statusSince: session.modifiedAt,
                        entrypoint: session.entrypoint,
                        origin: origin
                    )
                ),
                now: now
            )
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
