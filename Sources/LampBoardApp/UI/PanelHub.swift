import AppKit
import LampBoardCore
import SwiftUI

/// The Hub's sidebar is the panel itself (D150): the same `PanelRootView`, built
/// from the same store, preferences and actions, wide whatever the panel is.
/// The rows, their order, the R, the ring, the time, the second line and every
/// badge are the panel's by construction, so whoever keeps to the compact panel
/// loses nothing and whoever opens the Hub finds the rows they know. Only a
/// click differs: it opens the conversation beside the rows instead of raising
/// the window, which the conversation's header still does.
extension PanelController {

    func hubSidebar(select: @escaping (String) -> Void) -> AnyView {
        var rowActions = makeRowActions()
        rowActions.open = { row in select(row.primary.id) }
        rowActions.openSession = { member in select(member.id) }
        rowActions.openPlancia = { row in select(row.primary.id) }
        let root = PanelRootView(
            store: store,
            flags: flags(compact: false),
            options: columnOptions,
            mutedWorkspaces: preferences.mutedWorkspaces,
            calmWorkspaces: preferences.calmBlinkWorkspaces,
            expandedRows: preferences.expandedRows,
            focusedSession: preferences.focusedSession,
            actions: makeActions(),
            rowActions: rowActions,
            allowance: allowance,
            lampMaster: lampMaster, openLampMaster: { select(HubModel.lampMasterId) },
            lampMasterActions: lampMaster.map { lampMasterActions(for: $0) }, planciaActions: planciaActions(), samples: samples, tips: tips,
            queue: queue, bar: nil,
            plancia: nil, planciaLeading: false, activity: activity,
            openInEditor: { [weak self] id in
                guard let self, let session = self.store.state.sessions[id] else { return }
                self.activate(session: session)
            },
            closePlancia: {}
        )
        return AnyView(root)
    }
}
