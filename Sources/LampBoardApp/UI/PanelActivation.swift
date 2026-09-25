import LampBoardCore
import AppKit

/// Where a click goes, which is a different question for every surface.
///
/// Split out of `PanelController` at the 800-line ceiling. The seam is real: what
/// stays there is the panel as a window, and what left is the one decision that
/// has to be right or the app is lying — a row that leads somewhere is a promise,
/// and the promise is different for a VS Code window, a terminal tab, a machine
/// down the tunnel and an application that hosts its own chat.
extension PanelController {

    func activate(_ row: ColumnRow, markSeen: Bool, opensTab: Bool = true) {
        if markSeen {
            // Only the sessions that were in the most urgent state: you haven't
            // seen the others in the group, and clearing them would be a loss.
            for id in row.sessionIdsToClear { store.markSeen(sessionId: id) }
        }

        let session = row.primary

        // A terminal row's place is a terminal tab, found through the session's
        // process at click time (D25): its pid from the session file, the chain
        // up to the hosting application, that application's own way of selecting
        // a tab. Never an editor window of a folder that has none — and never a
        // modal: the session may simply have ended since the last poll.
        if session.origin == .terminal {
            activateTerminal(session)
            return
        }

        // A Claude Desktop session lives in Claude Desktop, whatever folder it is
        // working on. Without this it went to the folder's VS Code window, which
        // is the convincing wrong answer: the folder really is open there, and
        // the conversation really is not.
        //
        // Raising the application is the whole of what this surface offers and
        // therefore the whole truth: there is one window, and the conversation is
        // a tab inside it that nothing outside the app can select. So it is
        // reported as raised, not as "only activated" — that phrasing exists for
        // a click that fell short of what it could have done, and this one did
        // not.
        if ClaudeDesktop.isEntrypoint(session.entrypoint) {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: ClaudeDesktop.bundleIdentifier
            ) else {
                store.reportError("Claude Desktop is not on this Mac any more.")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            store.clearError()
            return
        }

        // A Codex session is raised by its own surface, not by the folder's.
        //
        // Until this, clicking one opened a VS Code window for its project, which
        // is right for the editor extension and wrong for everything else: a
        // session running in the ChatGPT app has a window, and it is not that one.
        // The folder being open in VS Code makes the window *relevant to the
        // project*, never the place the conversation lives.
        //
        // The surface comes from the executable holding the rollout open, which is
        // a fact about this machine rather than a string the transcript chose:
        // `originator` has been four different values in a week.
        if session.harness == .codex, let surface = CodexSurface.named(entrypoint: session.entrypoint) {
            switch surface {
            case .chatgptApp:
                if let identifier = surface.bundleIdentifier,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    store.clearError()
                } else {
                    store.reportError("The ChatGPT app is not on this Mac any more.")
                }
                return

            case .commandLine, .unknown:
                // The executable proves which program it is and not where it is
                // being typed: the same binary runs in Terminal, Ghostty, tmux
                // and VS Code's integrated terminal. So the click asks the
                // question a terminal row already answers — whose ancestry is
                // this, and what tab does that application select — starting
                // from the process holding the rollout open rather than from a
                // session file, because Codex writes none.
                //
                // Until this it stopped here and said so, which was honest and
                // useless: six rows on this Mac that could be found, coloured
                // and named, and not gone to.
                activateTerminal(session)
                return

            case .editorExtension:
                break  // The window of its folder really is where it lives.
            }
        }

        // A remote session's window, if it has one here, is the Remote-SSH window
        // of its folder; the focuser knows how to find it. The tab deep link is
        // off for it — the link goes to the local extension host, and this
        // session's is on the other machine. Off as well for a session the
        // extension did not start (`claude` in a terminal): the link would find
        // no tab for it and open a new one, which is the mess the widget exists
        // to avoid.
        let remoteHost = session.workspace.host
        let hasTab = remoteHost == nil && DeepLinkPolicy.opensTab(entrypoint: session.entrypoint)
        switch VSCodeFocuser.focus(
            workspace: session.workspace,
            sessionId: opensTab && hasTab ? session.id : nil
        ) {
        case .raised:
            store.clearError()

        case .activatedOnly(let reason):
            // VS Code is in front of the user: interrupting with a modal window
            // would be out of proportion. The strip under the rows carries it
            // instead, with the button — the context menu alone was a place
            // nobody looks, which is how a missing permission read as a broken app.
            store.reportError(
                "Window not raised (\(reason.shortDescription)): only VS Code was activated.",
                issue: reason.panelIssue
            )
            awaitPermission(for: reason) { [weak self] in
                self?.activate(row, markSeen: false, opensTab: opensTab)
            }

        case .failed(let error):
            // Normal for a session driven from a terminal on the node: there is no
            // window here to raise, and a modal saying so would be true and
            // useless. The menu says where the session is instead.
            if let remoteHost {
                store.reportError(
                    "“\(session.workspace.name)” runs on \(remoteHost): "
                        + "no Remote-SSH window of that folder is open here (\(error.shortDescription))."
                )
                return
            }
            store.reportError(error.shortDescription, issue: error.panelIssue)
            awaitPermission(for: error) { [weak self] in
                self?.activate(row, markSeen: false, opensTab: opensTab)
            }
            Alerts.warn(
                title: "Cannot open “\(session.workspace.name)”",
                message: error.localizedDescription
            )
        }
    }

}
