import AppKit
import LampBoardCore

/// The panel's side of the live view (D130): what a row asks of it.
extension PanelController {

    /// «Open here» on a background session's row.
    func openHere(_ job: BackgroundJob) {
        if live?.open(job: job.id) != true {
            liveRefused("LampBoard could not open this session: Claude Code was not found on this Mac.")
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
