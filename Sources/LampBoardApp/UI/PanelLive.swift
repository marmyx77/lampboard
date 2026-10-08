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
        case .tmux: liveRefused("LampBoard could not open this session: that machine's name is not one ssh can be given.")
        }
    }

    /// «New conversation in LampBoard»: a background session in the row's
    /// folder, opened as soon as Claude Code says its id.
    func startHere(_ row: ColumnRow) {
        guard !row.workspace.isRemote else { return }
        live?.start(directory: row.workspace.path, name: row.alias ?? row.workspace.name) { [weak self] message in
            self?.liveRefused(message)
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
