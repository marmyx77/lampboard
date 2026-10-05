import AppKit
import LampBoardCore

/// The baton (5.4, D91) delivered: a handoff waits in a session's Plancia
/// composer, to be read, changed and sent — never sent by itself (D85). From
/// the bar, `/handoff @from @to` (T1); from inside a session, the mod's
/// `/handoff <name>` posting to `POST /handoff` (T2).
///
/// Its own file for the reason `PanelBar.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    /// The handoff proposed to `to`: `nil` when it waits in its composer, or
    /// what happened instead — where no composer can take it, it is copied.
    func propose(handoff brief: String, to: String) -> String? {
        func copied(_ why: String) -> String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(brief, forType: .string)
            return why + ": the handoff is copied, to paste where it goes."
        }
        guard let target = session(named: to) else { return copied("That session is gone") }
        if let host = target.workspace.host { return copied("\(target.displayName) is on \(host)") }
        // A composer that cannot send would hold it where nothing can be done with it.
        guard preferences.messageSendingEnabled else { return copied("Sending is off in the panel") }
        openPlancia(sessionId: to)
        guard let thread = plancia.thread, thread.sessionId == to else { return copied("Its Plancia did not open") }
        // The person's own words stay: the handoff is not dropped on them, it is copied.
        guard !thread.hasDraft else { return copied("\(target.displayName)'s composer already has your text") }
        thread.proposed = brief
        Diagnostics.log("handoff → \(to.prefix(8)): \(brief.count) chars proposed")
        return nil
    }

    /// `POST /handoff` (T2), proven: a session wrote its own handoff for the
    /// one it named. The answer is what that session shows the person.
    func receive(handoff request: Handoff.Request) -> String {
        let name = RowActivity.flat(request.to).prefix(40)
        let found = CommandBar.sessions(named: request.to, rows: currentRendering.rows, now: Date())
        // Nothing copied for a name that finds nothing: the clipboard is taken
        // only for a session that exists and cannot take it in its composer.
        guard found.count < 2 else {
            return "\(found.count) sessions match \(name) (\(found.prefix(3).map(\.title).joined(separator: ", "))): name one exactly."
        }
        guard let first = found.first, let to = first.sessionId else { return "No session called \(name) in LampBoard's panel." }
        guard to != request.session else { return "That is this session: name the one that takes over." }
        let source = session(named: request.session)?.displayName ?? "another session"
        return propose(handoff: Handoff.brief(from: source, text: request.text), to: to)
            ?? "Handoff written: it waits in \(first.title)'s composer in LampBoard, to read, change and send."
    }
}
