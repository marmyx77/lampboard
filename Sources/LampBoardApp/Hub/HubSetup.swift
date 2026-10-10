import AppKit
import Foundation
import LampBoardCore
import SwiftUI

/// Builds the Hub and wires it to the panel, the mod's reports and the Dock.
@MainActor
enum HubSetup {

    static func make(
        store: StateStore, panel: PanelController, live: LiveWindowController,
        hubDesk: @escaping () -> HubCommandDesk?
    ) -> HubWindowController {
        weak var weakModel: HubModel?
        let deps = HubDependencies(
            store: store,
            queue: panel.queue,
            lampMaster: panel.lampMaster,
            lampMasterActions: panel.lampMaster.map { panel.lampMasterActions(for: $0) },
            sidebar: { [weak panel] select in panel?.hubSidebar(select: select) ?? AnyView(EmptyView()) },
            chatSource: { id in chatSource(for: id, store: store) },
            situation: { id in
                let session = store.state.session(named: id)
                let local = session?.workspace.isRemote == false
                return HubWrite.Situation(
                    commands: weakModel?.commandable.contains(id) ?? false,
                    box: local && PeerSender().hasBox(sessionId: id),
                    paste: live.canPaste(into: id),
                    busy: session.map { $0.status == .working || $0.status == .waiting } ?? false,
                    asking: session?.status == .awaiting,
                    presence: HubWrite.presence(surface: weakModel?.surfaces[id], entrypoint: session?.entrypoint,
                                                draft: weakModel?.drafts[id])
                )
            },
            send: { id, text, route, mode in
                switch route {
                case .mod:
                    return hubDesk()?.send(session: id, op: "submit", args: HubWrite.submitArgs(text: text, mode: mode)) ?? false
                case .box:
                    if case .success = PeerSender().send(text, to: id) { return true }
                    return false
                case .paste:
                    return live.submit(text, toSession: id)
                case .none:
                    return false
                }
            },
            openRealWindow: { [weak panel] id in
                guard let panel, let session = store.state.session(named: id) else { return }
                panel.activate(session: session)
            },
            project: { id in
                guard let session = store.state.session(named: id) else { return nil }
                guard let host = session.workspace.host else { return (session.workspace.path, nil) }
                let cwd = store.remoteSessions[host]?.first(where: { $0.sessionId == id })?.cwd ?? session.workspace.path
                return (cwd, host)
            },
            command: { id, op, args in hubDesk()?.send(session: id, op: op, args: args) ?? false },
            tools: { [weak panel] id in
                (panel?.activity?.logs[id]?.entries ?? []).compactMap { entry in
                    if case .tool(let name, let detail) = entry.kind { return (name, detail) }
                    return nil
                }
            },
            canShiftTab: { id in live.canPaste(into: id) },
            shiftTab: { id in live.shiftTab(session: id) },
            mode: { id in
                if let shown = live.screenMode(session: id) { return (shown, Date()) }
                return (store.permissionModes[id].flatMap(HubBar.mode(permission:)), store.permissionModesHeardAt[id])
            }
        )
        let model = HubModel(deps: deps)
        weakModel = model
        let hub = HubWindowController(model: model)
        panel.openHub = { [weak hub] id in hub?.show(session: id) }
        panel.onRebuilt = { [weak hub] in hub?.refreshSidebar() }
        live.keepsDock = { [weak hub] in hub?.isOpen ?? false }
        hub.onVisibilityChange = { [weak live, weak model, weak hub] in
            live?.refreshDockPresence()
            if hub?.isOpen == false { model?.close() }
        }
        return hub
    }

    /// Where a session's transcript is read: the file here, or its path on its machine.
    static func chatSource(for id: String, store: StateStore) -> LiveChatModel.Source? {
        guard let session = store.state.session(named: id) else { return nil }
        if let host = session.workspace.host {
            let cwd = store.remoteSessions[host]?.first(where: { $0.sessionId == id })?.cwd ?? session.workspace.path
            return .remote(host: host, path: LiveChatSource.remotePath(sessionId: id, cwd: cwd))
        }
        return .local(session.transcriptPath.map { URL(fileURLWithPath: $0) }
            ?? TranscriptLocator.candidateURL(sessionId: session.id, cwd: session.workspace.path))
    }
}
