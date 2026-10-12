import AppKit
import Foundation
import LampBoardCore
import SwiftUI

/// Builds the Hub and wires it to the panel, the mod's reports and the Dock.
@MainActor
enum HubSetup {

    static func make(
        store: StateStore, panel: PanelController, live: LiveWindowController, server: SignalServer?, port: UInt16
    ) -> HubWindowController {
        let deps = HubDependencies(
            store: store,
            queue: panel.queue,
            lampMaster: panel.lampMaster,
            lampMasterActions: panel.lampMaster.map { panel.lampMasterActions(for: $0) },
            sidebar: { [weak panel] select in panel?.hubSidebar(select: select) ?? AnyView(EmptyView()) },
            chatSource: { id in chatSource(for: id, store: store) },
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
            tools: { [weak panel] id in
                (panel?.activity?.logs[id]?.entries ?? []).compactMap { entry in
                    if case .tool(let name, let detail) = entry.kind { return (name, detail) }
                    return nil
                }
            },
            target: { [weak panel] id in
                guard let panel, let session = store.state.session(named: id) else { return nil }
                return panel.liveTarget(session)
            },
            live: live,
            move: { [weak panel] id in
                guard let panel, let row = panel.movableRow(id) else { return nil }
                return { [weak panel] in panel?.moveHere(row) }
            },
            projects: ProjectStore(),
            hosts: { store.remoteHosts },
            startBackground: { [weak panel] folder in panel?.startInBackground(folder: folder, name: nil) },
            liveOn: { host in Set((store.remoteSessions[host] ?? []).map(\.sessionId)) }
        )
        let model = HubModel(deps: deps)
        let hub = HubWindowController(model: model)
        panel.openHub = { [weak hub] id in hub?.show(session: id) }
        let launcher = SessionLauncher(store: store) { [weak hub] started in hub?.show(started) }
        model.launcher = launcher
        let conductor = LampMasterConductor(
            store: store, launcher: launcher, port: port,
            target: { [weak panel] id in store.state.sessions[id].flatMap { panel?.liveTarget($0) } },
            openInHub: { [weak hub] id in hub?.show(session: id) })
        model.conductor = conductor
        // From the server's queue; the conductor answers on the main actor itself.
        server?.onLampMasterHands = { body in conductor.answer(body) }
        panel.startInHub = { [weak model] host, folder, name in
            guard let model, host != nil || LocalTmuxPlaces.executable() != nil else { return false }
            model.startSession(folder: folder, host: host, name: name)
            return true
        }
        // Move to LampBoard ends in tmux, in the Hub (hub-terminale R6).
        live.resumeInTmux = { folder, id, name, failed in
            launcher.launch(folder: folder, host: nil, start: .resume(sessionId: id), name: name) { if let reason = $0 { failed(reason) } }
            return true
        }
        live.openInHub = { [weak panel] target in panel?.showInHub(target) ?? false }
        panel.hubIsOpen = { [weak hub] in hub?.isOpen ?? false }
        panel.hubIsKey = { [weak hub] in hub?.isKey ?? false }
        panel.closeHub = { [weak hub] in hub?.close() }
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
