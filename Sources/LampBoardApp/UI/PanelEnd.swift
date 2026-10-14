import AppKit
import LampBoardCore

/// «End session…» (D168): a session ended from the panel or the Hub, wherever
/// it runs. A session in tmux leaves no shell behind: its tmux session closes,
/// Claude Code with it, here or on its machine. A temporary one closes its
/// terminal. One elsewhere on this Mac (VS Code, a terminal) is asked to stop,
/// as a conversation's own menu does. The conversation stays on disk, to be
/// taken up again from its project.
///
/// Its own file for the reason `PanelQueue.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    /// Whether a session can be ended from here.
    func canEnd(_ session: SessionState) -> Bool {
        live?.directTarget(for: session.id) != nil || liveTarget(session) != nil || !session.workspace.isRemote
    }

    /// `confirmed` skips the question: the tests' wish only, under a fake home.
    func endSession(_ session: SessionState, name: String, confirmed: Bool = false) {
        // Just started, its tmux pane is not learnt yet (ten seconds): the
        // target the Hub started it with.
        let target = live?.directTarget(for: session.id) ?? liveTarget(session) ?? startedTarget?(session.id)
        let working = session.status == .working || session.status == .awaiting
        func confirm(_ detail: String) -> Bool {
            if confirmed && AppConfig.isUsingHomeOverride { return true }
            return Alerts.confirm(
                title: "End \u{201C}\(name)\u{201D}?",
                message: detail + (working ? "\n\nIt is in the middle of a turn: the turn is cut where it stands." : "")
                    + "\n\nThe conversation is kept: Resume a past conversation… in its project takes it up again.",
                confirmTitle: "End session")
        }
        switch target {
        case .direct?:
            guard confirm("Claude Code stops, and its terminal closes."), let target else { return }
            ending?(session.id)
            live?.endHosted(target)
            store.dismiss(sessionId: session.id)
            rebuildContent()
        case .tmux(let host, let place, _)?:
            let place_ = host.map { " on \($0)" } ?? ""
            guard confirm("Claude Code stops, and its tmux session \u{201C}\(place.session)\u{201D}\(place_) closes with it.") else { return }
            ending?(session.id)
            Task { @MainActor [weak self] in
                let ended = await Self.killTmuxSession(place.session, host: host)
                guard let self else { return }
                if ended {
                    self.store.dismiss(sessionId: session.id)
                    self.rebuildContent()
                } else {
                    Alerts.tell(title: "It did not end",
                                message: "tmux\(place_) would not close the session \u{201C}\(place.session)\u{201D}, or it had already gone.")
                }
            }
        case .newTmux(let host, _, _, let launch, _)?:
            // Started on another machine and not yet placed: found there by its tag.
            guard confirm("Claude Code stops, and its tmux session on \(host) closes with it.") else { return }
            ending?(session.id)
            let script = #"export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; l="# + launch + "; "
                + #"n=$(tmux list-sessions -F '#{@lampboard} #{session_name}' 2>/dev/null | sed -n "s/^$l //p" | head -n 1); "#
                + #"[ -n "$n" ] && tmux kill-session -t "=$n" && echo ended"#
            Task { @MainActor [weak self] in
                let ended = await ProjectSource.ssh(host, NewSession.posix(script))?.contains("ended") == true
                guard let self else { return }
                if ended { self.store.dismiss(sessionId: session.id); self.rebuildContent() }
                else { Alerts.tell(title: "It did not end", message: "tmux on \(host) would not close the session, or it had already gone.") }
            }
        default:
            guard !session.workspace.isRemote, let process = SessionTerminator.process(of: session.id) else {
                if confirmed && AppConfig.isUsingHomeOverride { return Diagnostics.log("end: nothing to end for \(session.id.prefix(8))") }
                return Alerts.tell(title: "Nothing to end here",
                                   message: "LampBoard cannot reach this session's process, or cannot be sure it is the same one.")
            }
            guard confirm("Process \(process.pid), in \((process.cwd as NSString).lastPathComponent), is asked to stop and gets to save what it holds.")
            else { return }
            ending?(session.id)
            if SessionTerminator.terminate(process) {
                store.dismiss(sessionId: session.id)
                rebuildContent()
            } else {
                Alerts.tell(title: "It did not end", message: "The process would not take the signal, or had already gone.")
            }
        }
    }

    /// Closes a tmux session by its exact name, here or over ssh.
    nonisolated static func killTmuxSession(_ name: String, host: String?) async -> Bool {
        let target = "=" + name
        guard let host else {
            guard let tmux = LocalTmuxPlaces.executable() else { return false }
            return await Task.detached {
                (try? Command.run(tmux, ["kill-session", "-t", target], deadline: 5))?.succeeded == true
            }.value
        }
        let script = #"export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; tmux kill-session -t "# + NewSession.shellQuoted(target)
            + " && echo ended"
        return await ProjectSource.ssh(host, NewSession.posix(script))?.contains("ended") == true
    }
}
