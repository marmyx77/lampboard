import Foundation

/// The Mac's side of a node that runs `lampd` (W5, §2.3, §2.9, §2.12 of the
/// mobile plan): the rules, written as functions so that each is tested — and
/// bitten — without ssh, a tunnel or a clock. The app wires them; `RemoteTunnel`,
/// `SignalServer` and `MobileServer` keep no rule of their own.

// MARK: - The tunnel's port

/// Which port the tunnel binds on the node, from what the node said before the
/// connect and what the heartbeats said since (§2.3 points 2–3).
public enum TunnelPort {

    public enum Choice: Equatable, Sendable {
        case bind(UInt16)
        /// Not now: the port wanted is held by somebody else; the tunnel waits.
        case wait(String)
    }

    /// - Parameters:
    ///   - primary: the hooks' port, from the uid (`AppConfig.remotePort`).
    ///   - primaryBound, secondaryBound: who is listening there, as the node
    ///     reads `/proc/net/tcp` before the connect.
    ///   - lampdInstalled: `lampd` is where `Scripts/lampd-install.sh` puts it.
    ///   - watch: what the heartbeats decided (`MacNodeLinkWatch.port`).
    public static func choose(primary: UInt16, primaryBound: [String], secondaryBound: [String],
                              lampdInstalled: Bool, watch: MacNodeLinkWatch.Port) -> Choice {
        let secondary = MacNodeLink.secondaryPort(of: primary)
        // `lampd.socket` holding the hooks' port is the ordinary case once
        // `lampd` is in tee: the tunnel goes next to it at once, without waiting
        // for beats it can only hear once connected.
        let wantsSecondary = watch == .secondary || (lampdInstalled && !primaryBound.isEmpty)
        if wantsSecondary {
            guard secondaryBound.isEmpty else {
                return .wait("port \(secondary) is taken there (\(secondaryBound.joined(separator: ", ")))")
            }
            return .bind(secondary)
        }
        // The primary only when it is free (§2.3 point 2): with the socket of
        // systemd, free means `lampd` gave up.
        guard primaryBound.isEmpty else {
            return .wait("port \(primary) is taken there (\(primaryBound.joined(separator: ", ")))")
        }
        return .bind(primary)
    }
}

// MARK: - Events forwarded by a node

/// What the Mac does with a request that `lampd` forwarded (it carries
/// `MacNodeLink.eventHeader`): an event taken once (E3), and never a command
/// for the Mac (R2: «il nodo non comanda il Mac»).
public enum ForwardedByNode {

    /// The Mac's own client routes: they start sessions, raise windows, answer
    /// asks, read the person's boards. None of them is a hook's or the mod's on
    /// a node, so one arriving through `lampd` is refused whatever it carries.
    public static let refusedPaths: Set<String> = [
        AppConfig.nextPath, AppConfig.openPath, AppConfig.newConversationPath, AppConfig.chatPath,
        AppConfig.watchPath, AppConfig.lampMasterPath, AppConfig.lampMasterHandsPath, AppConfig.decisionsPath,
        AppConfig.livePath, AppConfig.checkAnswerPath, AppConfig.hubSendPath, AppConfig.hubRemoteCheckPath,
        AppConfig.hubPath, AppConfig.hubOpenPath, AppConfig.hubFilesPath,
    ]

    /// The routes whose requests are events, counted once.
    public static let eventPaths: Set<String> = [AppConfig.signalPath, AppConfig.modPath]

    public enum Verdict: Equatable, Sendable {
        /// Not forwarded, or forwarded and new: handle it.
        case take
        /// Already taken: answer as if handled, change nothing.
        case duplicate
        case refuse(String)
    }

    public static func verdict(path: String, method: String, eventId: String?, ledger: inout EventLedger) -> Verdict {
        guard let eventId else { return .take }
        if refusedPaths.contains(path) || (path == AppConfig.checkPath && method == "GET") {
            return .refuse("\(path) is the Mac's own route: never from another machine")
        }
        guard eventPaths.contains(path), EventLedger.isWellFormed(eventId) else { return .take }
        return ledger.firstTime(eventId) ? .take : .duplicate
    }
}

/// The ids of the events already taken, the latest `capacity` of them.
public struct EventLedger: Equatable, Sendable {
    public let capacity: Int
    private var order: [String] = []
    private var seen: Set<String> = []

    public init(capacity: Int = 4096) { self.capacity = max(1, capacity) }

    /// `<journal>-<n>`: letters, digits, `.`, `_`, `-`, at most 128.
    public static func isWellFormed(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    /// `true` the first time `id` is seen.
    public mutating func firstTime(_ id: String) -> Bool {
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            let drop = order.count - capacity
            for old in order.prefix(drop) { seen.remove(old) }
            order.removeFirst(drop)
        }
        return true
    }

    public var count: Int { order.count }
}

// MARK: - Who notifies

/// The rule «one owner per row» (§2.9, gate «Nessuna doppia notifica»): a
/// source notifies only the rows it owns. The Mac owns its own and those of the
/// nodes without a healthy `lampd`; a node's `lampd` owns its own.
public enum PushOwnership {
    public static func rows(_ rows: [V1Row], ownedBy owner: String) -> [V1Row] {
        rows.filter { $0.owner == owner }
    }
}

// MARK: - The person's choices about a node's rows

/// The panel's choices about one node row, as the panel shows it.
public struct PanelRowChoice: Equatable, Sendable {
    public var label: String?
    public var hidden: Bool
    public var muted: Bool

    public init(label: String? = nil, hidden: Bool = false, muted: Bool = false) {
        self.label = label
        self.hidden = hidden
        self.muted = muted
    }
}

/// The panel's view of one node's rows: what is compared, sent and merged.
public struct NodePanelView: Equatable, Sendable {
    public var rows: [String: PanelRowChoice]
    /// The node's row ids, in the panel's order.
    public var order: [String]

    public init(rows: [String: PanelRowChoice] = [:], order: [String] = []) {
        self.rows = rows
        self.order = order
    }
}

/// One node row as the panel knows it: its session id and the key the panel's
/// preferences are stored under.
public struct NodeRowKey: Equatable, Sendable {
    public let id: String
    public let key: String
    /// When it last became something to read (green): a read from the phone
    /// older than this is about an earlier answer.
    public let readySince: Date?

    public init(id: String, key: String, readySince: Date? = nil) {
        self.id = id
        self.key = key
        self.readySince = readySince
    }
}

/// The panel and `lampd` keep the person's choices about a node's rows in step
/// (§2.12): the panel's changes go to the node as `v1` commands, the node's
/// come back and change the panel, and once, the panel's own copy is merged in.
public enum NodeChoices {

    /// The panel's view of `rows`, from its preferences.
    public static func view(rows: [NodeRowKey], rowNames: [String: String], hidden: Set<String>, muted: Set<String>,
                            rowOrder: [String]) -> NodePanelView {
        var choices: [String: PanelRowChoice] = [:]
        for row in rows {
            choices[row.id] = PanelRowChoice(label: rowNames[row.key], hidden: hidden.contains(row.key), muted: muted.contains(row.key))
        }
        let place = Dictionary(rowOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = rows.filter { place[$0.key] != nil }.sorted { (place[$0.key]!, $0.id) < (place[$1.key]!, $1.id) }.map(\.id)
        return NodePanelView(rows: choices, order: ordered)
    }

    /// The commands that bring the node from `old` to `new`. A row that was not
    /// in `old` sends nothing: the migration carried it. Read, unread and taken
    /// off are acts, not states the panel keeps: the app sends them as they
    /// happen (`StateStore`'s choices), not from here.
    public static func commands(from old: NodePanelView, to new: NodePanelView) -> [V1Command] {
        var out: [V1Command] = []
        for id in new.rows.keys.sorted() {
            guard let before = old.rows[id], let after = new.rows[id] else { continue }
            if before.label != after.label { out.append(V1Command(action: .rename, session: id, name: after.label ?? "")) }
            if before.hidden != after.hidden { out.append(V1Command(action: .hide, session: id, on: after.hidden)) }
            if before.muted != after.muted { out.append(V1Command(action: .mute, session: id, on: after.muted)) }
        }
        // The order only when rows both views know moved: a row arriving in
        // the panel's order is not a reordering.
        if new.order.filter(old.order.contains) != old.order.filter(new.order.contains) {
            out.append(V1Command(action: .order, ids: new.order))
        }
        return out.filter { $0.problem == nil }
    }

    /// The panel's own copy as the node keeps choices, for the one-time merge.
    /// The panel kept no dates for names, hidden, mute and order: they carry
    /// `.distantPast`, so wherever the node has a value of its own — written from
    /// the phone — the node's wins, and the panel's fills only what the node never
    /// had. No read state and nothing taken off: the panel keeps no time for
    /// the first, and the second leaves no row behind to name.
    public static func migration(_ view: NodePanelView) -> RowPreferences {
        var out = RowPreferences()
        let past = Date.distantPast
        for (id, choice) in view.rows {
            if let label = choice.label { out.apply(V1Command(action: .rename, session: id, name: label), at: past) }
            if choice.hidden { out.apply(V1Command(action: .hide, session: id, on: true), at: past) }
            if choice.muted { out.apply(V1Command(action: .mute, session: id, on: true), at: past) }
        }
        if !view.order.isEmpty { out.apply(V1Command(action: .order, ids: view.order), at: past) }
        return out
    }

    /// What the node's choices change in the panel.
    public struct PanelUpdate: Equatable, Sendable {
        /// Per key: the name to keep, or `nil` to clear it.
        public var names: [String: String?] = [:]
        public var hidden: [String: Bool] = [:]
        public var muted: [String: Bool] = [:]
        /// Session ids to mark read, or unread, in the panel.
        public var read: [String] = []
        public var unread: [String] = []

        public init() {}

        public var isEmpty: Bool { names.isEmpty && hidden.isEmpty && muted.isEmpty && read.isEmpty && unread.isEmpty }
    }

    /// The panel's changes for `node`'s choices about `rows`, given what the
    /// panel shows (`view`). `applied` remembers the read stamps already
    /// carried out, so a stamp is applied once.
    public static func panelUpdate(from node: RowPreferences, rows: [NodeRowKey], view: NodePanelView,
                                   applied: inout [String: Date]) -> PanelUpdate {
        var update = PanelUpdate()
        for row in rows {
            let choices = node.row(row.id)
            let shown = view.rows[row.id] ?? PanelRowChoice()
            if let label = choices.label {
                let wanted: String? = label.value.isEmpty ? nil : label.value
                if wanted != shown.label { update.names[row.key] = .some(wanted) }
            }
            if let hidden = choices.hidden, hidden.value != shown.hidden { update.hidden[row.key] = hidden.value }
            if let muted = choices.muted, muted.value != shown.muted { update.muted[row.key] = muted.value }
            if let read = choices.readAt, read.at > (applied[row.id] ?? .distantPast) {
                applied[row.id] = read.at
                if let readAt = read.value {
                    // A read of an earlier answer does not put out a new one.
                    if row.readySince.map({ readAt >= $0 }) ?? true { update.read.append(row.id) }
                } else {
                    update.unread.append(row.id)
                }
            }
        }
        return update
    }
}

// MARK: - The Mac's last word before it sleeps

public enum MacSleepNote {
    /// The one notification before the Mac sleeps (§2.6 «Sonno»), or `nil`
    /// when nothing waits for the person: a sleep with nothing to say is silent.
    public static func text(waiting: Int, mac: String) -> (title: String, body: String)? {
        guard waiting > 0 else { return nil }
        let sessions = waiting == 1 ? "1 session is" : "\(waiting) sessions are"
        return (mac, "The Mac is going to sleep; \(sessions) waiting for you")
    }
}
