import Combine
import Foundation
import LampBoardCore

/// The person's choices about a node's rows, kept in step between the panel and
/// the node's `lampd` (W5, §2.12). The rules are `NodeChoices`': this only reads
/// the panel, sends, and applies what comes back.
///
/// - Names, hidden, mute and order changed in the panel, by whatever path, are
///   seen as a difference from what was last sent and go as `v1` commands.
/// - Read, unread and taken off are acts: `StateStore.onNodeChoice` sends them
///   as they happen.
/// - What the node sends back — a row read on the phone, renamed, muted —
///   changes the panel, and becomes the new baseline, so nothing echoes.
/// - Once per node, at its first link, the panel's own copy is merged in.
@MainActor
final class NodeChoicesSync {
    private let store: StateStore
    private let preferences: Preferences
    private let fleet: RemoteFleet
    private var sent: [String: NodePanelView] = [:]
    private var applied: [String: [String: Date]] = [:]
    private var watches: [AnyCancellable] = []
    private var defaultsWatch: NSObjectProtocol?

    init(store: StateStore, preferences: Preferences, fleet: RemoteFleet) {
        self.store = store
        self.preferences = preferences
        self.fleet = fleet
    }

    func start() {
        store.onNodeChoice = { [weak self] command, host in
            guard let self, self.fleet.lampdHealthy.contains(host) else { return }
            self.fleet.send(MacToNode(command: command, at: Date()), to: host)
        }
        fleet.onLinked = { [weak self] host in self?.linked(host) }
        fleet.onNodePreferences = { [weak self] host, choices in self?.received(choices, from: host) }
        watches.append(store.$state.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sendChanges() })
        defaultsWatch = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendChanges() }
        }
    }

    private func rows(of host: String) -> [NodeRowKey] {
        store.state.sessions.values.filter { $0.workspace.host == host }.map { session in
            NodeRowKey(id: session.id, key: session.workspace.key,
                       readySince: session.status.clearsOnFocus ? session.statusSince : nil)
        }
    }

    private func view(of host: String) -> NodePanelView {
        NodeChoices.view(rows: rows(of: host), rowNames: preferences.rowNames, hidden: preferences.hiddenWorkspaces,
                         muted: preferences.mutedWorkspaces, rowOrder: preferences.rowOrder)
    }

    /// A node's link answered: the migration once, and the baseline.
    private func linked(_ host: String) {
        let now = view(of: host)
        if !preferences.nodeMigrationsSent.contains(host) {
            fleet.send(MacToNode(migration: RowPreferencesWire(NodeChoices.migration(now)), at: Date()), to: host)
            preferences.nodeMigrationsSent = preferences.nodeMigrationsSent.union([host])
            Diagnostics.log("nodes: the panel's choices for \(host) merged into its lampd once")
        }
        sent[host] = now
    }

    private func sendChanges() {
        for host in fleet.lampdHealthy {
            let now = view(of: host)
            guard let before = sent[host] else { continue }
            for command in NodeChoices.commands(from: before, to: now) {
                fleet.send(MacToNode(command: command, at: Date()), to: host)
            }
            sent[host] = now
        }
    }

    private func received(_ choices: RowPreferences, from host: String) {
        let rows = rows(of: host)
        // A read of an earlier answer never puts out a newer one (`readySince`).
        var stamps = applied[host] ?? [:]
        let update = NodeChoices.panelUpdate(from: choices, rows: rows, view: view(of: host), applied: &stamps)
        applied[host] = stamps
        guard !update.isEmpty else { return }
        if !update.names.isEmpty {
            var names = preferences.rowNames
            for (key, name) in update.names { names[key] = name }
            preferences.rowNames = names
        }
        if !update.hidden.isEmpty {
            preferences.hiddenWorkspaces = preferences.hiddenWorkspaces
                .union(update.hidden.filter(\.value).keys).subtracting(update.hidden.filter { !$0.value }.keys)
        }
        if !update.muted.isEmpty {
            preferences.mutedWorkspaces = preferences.mutedWorkspaces
                .union(update.muted.filter(\.value).keys).subtracting(update.muted.filter { !$0.value }.keys)
        }
        for id in update.read { store.markSeenFromNode(sessionId: id) }
        for id in update.unread { store.markUnreadFromNode(sessionId: id) }
        // What the node said is now what the panel shows: nothing goes back.
        sent[host] = view(of: host)
    }
}
