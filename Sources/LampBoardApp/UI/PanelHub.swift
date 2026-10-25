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
        // A click in the Hub's column reads the row, as a click in the panel does.
        rowActions.open = { [store] row in
            for id in row.sessionIdsToClear { store.markSeen(sessionId: id) }
            select(row.primary.id)
        }
        rowActions.openSession = { [store] member in
            store.markSeen(sessionId: member.id)
            select(member.id)
        }
        rowActions.openPlancia = { [store] row in
            for id in row.sessionIdsToClear { store.markSeen(sessionId: id) }
            select(row.primary.id)
        }
        rowActions.mention = { [weak self] row in self?.mention(row) ?? NSItemProvider() }
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
            samples: samples, tips: tips,
            queue: queue, bar: nil, activity: activity
        )
        return AnyView(root)
    }
}

extension PanelController {
    /// A line dragged from the Hub's column (D172): its reference, for the
    /// terminal it lands in, and leave for the session at the centre to ask it.
    /// Only lines that are one conversation get here (`SessionMention.target`).
    func mention(_ row: ColumnRow) -> NSItemProvider {
        guard let target = SessionMention.target(of: row) else { return NSItemProvider() }
        if let asker = hubCentreSession?(), asker != target.sessionId, let lampMaster {
            lampMaster.mentions.grant(asker: asker, target: target.sessionId, at: Date())
            Diagnostics.log("mention: \(asker.prefix(8)) may ask \(target.sessionId.prefix(8))")
        }
        return NSItemProvider(object: SessionMention.text(name: target.name, sessionId: target.sessionId) as NSString)
    }
}
