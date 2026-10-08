import AppKit
import LampBoardCore

/// The panel's side of the live view (D130): what a row asks of it.
extension PanelController {

    /// «Open here» on a row the live view can open.
    func openHere(_ target: LiveTarget) {
        guard live?.open(target) != true else { return }
        switch target {
        case .job: liveRefused("LampBoard could not open this session: Claude Code was not found on this Mac.")
        case .tmux(nil, _, _): liveRefused("LampBoard could not open this session: tmux was not found on this Mac.")
        case .tmux, .newTmux: liveRefused("LampBoard could not open this session: that machine's name is not one ssh can be given.")
        }
    }

    /// «New conversation in LampBoard»: in the row's folder, a background
    /// session on this Mac, or a tmux session on the row's machine (D133).
    func startHere(_ row: ColumnRow) {
        startSession(host: row.workspace.host, folder: row.workspace.path, name: row.alias ?? row.workspace.name)
    }

    /// Starts a session and opens it: what «New session…» and a row both do.
    func startSession(host: String?, folder: String, name: String?) {
        guard let host else {
            live?.start(directory: folder, name: name) { [weak self] message in self?.liveRefused(message) }
            return
        }
        // Free names are the other machine's to pick: it knows all of its own.
        let tmuxName = NewSession.tmuxName(for: "/" + (name ?? (folder as NSString).lastPathComponent), taken: [])
        guard let target = LiveTarget.starting(host: host, folder: folder, name: tmuxName), live?.open(target) == true else {
            liveRefused("LampBoard could not start a session on \(host): its name, or that folder, is not one ssh can be given.")
            return
        }
    }

    /// «Move to LampBoard…» (D135): every check first, then the editor's
    /// process is asked to end and the conversation goes on in the background.
    func moveHere(_ row: ColumnRow) {
        let session = row.primary
        guard MoveHere.isMovable(session), let process = movable(session.id) else { return }
        let name = row.alias ?? session.title?.nilIfEmpty ?? row.workspace.name
        guard Alerts.confirm(
            title: "Move \u{201C}\(name)\u{201D} to LampBoard?",
            message: "Its VS Code tab stops, and the conversation goes on in a LampBoard window with everything it "
                + "remembers, as a background session: it keeps running when the window is closed.\n\n"
                + "Close its tab in VS Code afterwards: a message typed there would be refused.",
            confirmTitle: "Move"
        ) else { return }
        // The dialog may have stayed open for minutes: everything again, now.
        guard let again = movable(session.id), again == process else { return }
        live?.move(process, name: name) { [weak self] message in self?.liveRefused(message) }
    }

    /// The process of a conversation that may move now, every check passed;
    /// `nil`, having said why, otherwise.
    private func movable(_ sessionId: String) -> SessionProcess? {
        guard let session = store.state.sessions[sessionId], MoveHere.isBetweenTurns(session.status) else {
            Alerts.tell(title: "Not in the middle of a turn",
                        message: "This conversation is working, or waiting for an answer. Move it when it has finished.")
            return nil
        }
        guard let process = SessionTerminator.process(of: sessionId) else {
            Alerts.tell(title: "Nothing to move",
                        message: "LampBoard cannot find the process of this conversation on this Mac, or cannot be sure it is the same one.")
            return nil
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: process.cwd, isDirectory: &isFolder), isFolder.boolValue else {
            Alerts.tell(title: "Nothing to move", message: "The folder this conversation started in is no longer there.")
            return nil
        }
        let config = try? Data(contentsOf: URL(fileURLWithPath: MoveHere.configPath(
            environment: ProcessInfo.processInfo.environment, home: AppConfig.homeDirectory.path)))
        guard MoveHere.isTrusted(folder: process.cwd, config: config) else {
            liveRefused(LiveLaunch.StartFailure.untrusted.message)
            return nil
        }
        return process
    }

    private func liveRefused(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The live view could not open"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
