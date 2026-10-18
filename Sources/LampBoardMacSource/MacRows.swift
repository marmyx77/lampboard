import Foundation
import LampBoardCore

/// The Mac's column as `v1` rows: each snapshot the read endpoint already
/// publishes, with what the panel knows of the row besides (§2.2).
///
/// A row of this Mac comes from this Mac. A row the Mac shows for another
/// machine (the tunnel's, D24) names that machine as its source, and its owner
/// — the one that notifies for it (§2.9) — is the Mac unless that machine has a
/// `lampd` the Mac found healthy, which then owns its own rows. Until W5's tee,
/// no node is passed as healthy: the seam is `nodesWithLampd`.
public enum MacRows {

    /// What the panel knows of one row beyond its snapshot.
    public struct Facts: Equatable, Sendable {
        public var readAt: Date?
        public var hidden: Bool
        public var order: Int?
        /// Where a terminal reaches it on its machine: `tmux:<session>`, `job:<id>`.
        public var terminal: String?
        public var permissionMode: String?
        /// A permission question the Mac holds in process (D80).
        public var heldByMac: Bool
        public var cacheMinutes: Int?
        public var runningTool: String?
        public var fileConflict: String?

        public init(readAt: Date? = nil, hidden: Bool = false, order: Int? = nil, terminal: String? = nil,
                    permissionMode: String? = nil, heldByMac: Bool = false, cacheMinutes: Int? = nil,
                    runningTool: String? = nil, fileConflict: String? = nil) {
            self.readAt = readAt
            self.hidden = hidden
            self.order = order
            self.terminal = terminal
            self.permissionMode = permissionMode
            self.heldByMac = heldByMac
            self.cacheMinutes = cacheMinutes
            self.runningTool = runningTool
            self.fileConflict = fileConflict
        }
    }

    /// When the Mac last heard from each other machine, and whether it answered.
    public struct HostSight: Equatable, Sendable {
        public let probedAt: Date?
        public let reachable: Bool

        public init(probedAt: Date?, reachable: Bool) {
            self.probedAt = probedAt
            self.reachable = reachable
        }
    }

    public static func rows(
        _ snapshots: [SessionSnapshot], mac: V1SourceIdentity, facts: [String: Facts] = [:],
        hosts: [String: HostSight] = [:], nodesWithLampd: Set<String> = []
    ) -> [V1Row] {
        snapshots.map { snapshot in
            let fact = facts[snapshot.id] ?? Facts()
            var extras = V1RowExtras(
                cacheMinutes: fact.cacheMinutes, runningTool: fact.runningTool, fileConflict: fact.fileConflict,
                hidden: fact.hidden, order: fact.order, readAt: fact.readAt, terminal: fact.terminal,
                permissionMode: fact.permissionMode, heldByMac: fact.heldByMac
            )
            guard let host = snapshot.host else {
                return V1Row(session: snapshot, source: mac, owner: mac.name, extras: extras)
            }
            let sight = hosts[host]
            extras.hostProbedAt = sight?.probedAt
            extras.hostReachable = sight?.reachable
            let node = V1SourceIdentity(kind: .node, name: host)
            return V1Row(session: snapshot, source: node, owner: nodesWithLampd.contains(host) ? host : mac.name, extras: extras)
        }
    }
}
