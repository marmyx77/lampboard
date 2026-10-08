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

    private func liveRefused(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The live view could not open"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
