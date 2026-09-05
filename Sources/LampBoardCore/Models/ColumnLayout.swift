import Foundation

/// One row drawn in the column.
///
/// It does not map one-to-one onto a session: when grouping is on, a row
/// represents a **project**, and all of its sessions live inside it.
public struct ColumnRow: Sendable, Equatable, Identifiable {
    /// Stable across redraws: the project path when grouping, the session id
    /// otherwise. If it moved, SwiftUI would rebuild the rows from scratch on
    /// every update and the panel would flicker.
    public let id: String

    public let workspace: Workspace

    /// The row's sessions, most urgent first.
    public let sessions: [SessionState]

    /// The row's keyboard slot: its position in the user's order, 1-based, for
    /// the first `AppConfig.maxSlots` positions; `nil` below them.
    ///
    /// A slot is what makes a row **addressable**: bind a key to slot 3 and it
    /// keeps meaning the same project tomorrow. The column does not reorder
    /// itself (D23), so the position *is* the address — the same list decides
    /// where the row is drawn and what the key opens, and the two cannot disagree.
    public let slot: Int?

    /// The name the user gave this row, if any (`RowNames`).
    public let alias: String?

    /// The row's conversations, named and in the order they were opened.
    ///
    /// Computed once here rather than on every read, because resolving a name
    /// walks three levels and the panel asks for this on every redraw.
    public let members: [RowSession]

    public init(
        id: String,
        workspace: Workspace,
        sessions: [SessionState],
        slot: Int? = nil,
        alias: String? = nil,
        names: [String: String] = [:],
        order: [String] = []
    ) {
        self.id = id
        self.workspace = workspace
        self.sessions = sessions
        self.slot = slot
        self.alias = alias?.trimmed.nilIfEmpty
        self.members = RowSession.list(of: sessions, in: names, order: order)
    }

    /// The most urgent state the dot is **covering**, if any.
    ///
    /// The dot shows the most urgent state in the row, which is right and is also
    /// how a project went green while one of its sessions was still working. This
    /// is the other half: the most urgent of what the colour is hiding, so the row
    /// can say "and something in here still needs you" without a second row.
    ///
    /// `idle` is never recalled. The recall exists to say something still needs
    /// you, a session at rest needs nobody, and the row has one mark to spend.
    public var recalledStatus: SessionStatus? {
        let dominant = status
        return sessions
            .map(\.status)
            .filter { $0 != dominant && $0 != .idle }
            .min { $0.urgencyRank < $1.urgencyRank }
    }

    /// The state the dot shows: the most urgent one in the group.
    public var status: SessionStatus { primary.status }

    /// The session a click opens.
    ///
    /// The most urgent one, not the most recent: if one session in a project is
    /// waiting for a permission and another has finished, the click has to take
    /// you where something is blocked.
    public var primary: SessionState {
        sessions.first ?? SessionState(
            id: id, status: .idle, workspace: workspace, updatedAt: .distantPast,
            statusSince: .distantPast
        )
    }

    /// How many sessions it contains.
    public var count: Int { sessions.count }

    /// `true` when the row's place is a terminal tab, not an editor window.
    public var isTerminal: Bool { primary.origin == .terminal }

    /// `true` when "New conversation here" is a thing this row can honestly do.
    ///
    /// Three ways it cannot: the folder is on another machine, the place is a
    /// terminal with no tab to open one in, or the surface does not host a
    /// Claude Code conversation at all. See `DeepLinkPolicy.opensNewConversation`
    /// for what the third one did before anybody asked it.
    public var hostsNewConversation: Bool {
        guard !workspace.isRemote, !isTerminal else { return false }
        return DeepLinkPolicy.opensNewConversation(
            harness: primary.harness, entrypoint: primary.entrypoint
        )
    }

    /// What a person reads on the row.
    ///
    /// The name the user gave it wins. Otherwise a row holding one session is
    /// named the way that session is (its title, for a terminal one); a row
    /// holding several is the folder — one name for three conversations would
    /// be a lie about two of them.
    ///
    /// The machine is **not** part of it. A row on another machine used to read
    /// `AWorld Events @minisforum`, and in a field that fits about twenty
    /// characters the host took half of them and left `AWeve…isforum` — a name
    /// nobody can pick out of a column, repeated identically on every row of that
    /// node. Where it is has one mark on the row and a sentence in the tooltip;
    /// what it is called gets the whole line back.
    public var displayName: String {
        alias ?? (sessions.count == 1 ? primary.displayName : workspace.name)
    }

    /// How full the context is of the session a click would open.
    ///
    /// The **primary** session's, not the fullest of the group and not a sum:
    /// contexts do not add up — three sessions at 40% are three sessions with
    /// room, not one at 120% — and the row already means "the session a click
    /// opens" everywhere else, from the colour to the timestamp. A row holding
    /// several says so in its tooltip, one line per session.
    public var context: ContextReading? { primary.context }

    /// Sum of the active subagents in the row.
    public var activeSubagents: Int { sessions.reduce(0) { $0 + $1.activeSubagents } }

    /// The moment since which the row has been in its current state.
    public var statusSince: Date { primary.statusSince }

    /// How many listeners are registered behind this row.
    ///
    /// Counted across every session of the row, not only the one whose colour
    /// wins: with grouping on, a project where one session left a monitor and
    /// another has an answer ready is a project where something is still
    /// listening, and the ring is the only thing that says so.
    public var listeners: Int {
        sessions.reduce(0) { total, session in
            total + session.waitingOn.filter {
                AppConfig.backgroundTaskTypesThatOnlyListen.contains($0.lowercased())
            }.count
        }
    }

    /// The most recent activity seen in the row.
    public var updatedAt: Date { sessions.map(\.updatedAt).max() ?? primary.updatedAt }

    /// The sessions a click must clear.
    ///
    /// Only the ones that were **in the most urgent state**, not all of them.
    /// Without this limit, opening a project where one session is waiting for a
    /// permission and another has an answer ready would mark both as seen, and
    /// the unread answer would vanish without ever being read: grouping would
    /// become a loss of information instead of a reduction in noise.
    public var sessionIdsToClear: [String] {
        let urgent = status
        return sessions.filter { $0.status == urgent }.map(\.id)
    }
}

/// How the rows should be laid out.
public struct ColumnOptions: Sendable, Equatable {
    public let onlyWaiting: Bool

    /// Project paths in the user's order. Position `i` is drawn `i`-th and is
    /// slot `i + 1`.
    ///
    /// An ordered list and not a set, because the order is the feature: it is
    /// where the rows are and what a bound key addresses. A `Set` would have made
    /// both depend on hashing, which is the definition of a place you cannot rely on.
    public let order: [String]

    public let hidden: Set<String>

    /// The names the user gave to folders (`RowNames`).
    public let names: [String: String]

    /// The order the user put the conversations of a project in, by project.
    ///
    /// Kept by **session id**, and that is the honest bargain rather than an
    /// oversight: a conversation has no identity that outlives its process, so a
    /// place given to one lasts exactly as long as the conversation does. A new
    /// one arrives at the end, in the order it was opened, rather than in a spot
    /// somebody would have to go looking for.
    public let conversationOrder: [String: [String]]

    public init(
        onlyWaiting: Bool = false,
        order: [String] = [],
        hidden: Set<String> = [],
        names: [String: String] = [:],
        conversationOrder: [String: [String]] = [:]
    ) {
        self.onlyWaiting = onlyWaiting
        self.order = order
        self.hidden = hidden
        self.names = names
        self.conversationOrder = conversationOrder
    }

    /// The name to show a row. The row is a project, so this is the project's.
    func name(for path: String) -> String? {
        RowNames.name(of: path, in: names)
    }

    /// The slot a project holds, 1-based, or `nil`.
    func slot(for path: String) -> Int? {
        RowOrder.slot(of: path, in: order, limit: AppConfig.maxSlots)
    }

    /// Where a project sorts; unknown ones after every known one.
    func position(for path: String) -> Int {
        RowOrder.position(of: path, in: order)
    }
}

/// What stays out of the column, summarized in a single row.
public struct HiddenSummary: Sendable, Equatable {
    /// How many sessions were set aside.
    public let sessionCount: Int

    /// The most urgent state among the hidden ones.
    public let status: SessionStatus

    /// The projects involved, by name, in order.
    public let workspaceNames: [String]

    /// `true` when something in there is asking for attention.
    ///
    /// Not a nicety: it is what stops "hide" from causing the very harm the panel
    /// exists to prevent. Without this row, hiding a project would mean no longer
    /// knowing when it needs you.
    public var needsAttention: Bool { status.clearsOnFocus }
}

/// The result of the computation: what is visible and what was set aside.
public struct ColumnRendering: Sendable, Equatable {
    public let rows: [ColumnRow]
    public let hidden: HiddenSummary?

    /// How many sessions the "only what's waiting" filter excluded.
    /// Worth stating, rather than letting you believe there are no others.
    public let filteredOut: Int

    public static let empty = ColumnRendering(rows: [], hidden: nil, filteredOut: 0)

    /// The row a bound key should open, or `nil` when that slot is empty.
    ///
    /// Empty is a normal outcome, not an error: a project can hold a place in the
    /// order and have no live session right now. The caller has to say "slot 3 is
    /// empty" rather than open something else — opening the neighbor would be the
    /// worst possible behavior for a key you press without looking.
    ///
    /// With grouping off several rows share a slot; the most urgent wins, which
    /// is what `sorted` already put first and what a click on the group does.
    public func row(inSlot slot: Int) -> ColumnRow? {
        rows.first { $0.slot == slot }
    }

    /// The slots that currently have a row, in order, one entry per slot.
    ///
    /// Deduplicated on purpose: with grouping off a project has several rows and
    /// they all carry its slot, but the listing has to answer "what does key 3
    /// open", which is one thing.
    public var occupiedSlots: [(slot: Int, row: ColumnRow)] {
        var seen = Set<Int>()
        return rows.compactMap { row in
            guard let slot = row.slot, seen.insert(slot).inserted else { return nil }
            return (slot: slot, row: row)
        }
    }
}

/// Turns the state into the list of rows to draw.
///
/// A pure function: same state and same options, same rows. All the logic of the
/// "scale" phase lives here, where it can be verified without drawing anything.
public enum ColumnLayout {

    public static func render(
        _ state: TrafficLightState,
        options: ColumnOptions
    ) -> ColumnRendering {
        let all = state.ordered
        guard !all.isEmpty else { return .empty }

        let visible = all.filter { !options.hidden.contains($0.workspace.key) }
        let putAside = all.filter { options.hidden.contains($0.workspace.key) }

        let grouped = group(visible, options: options)

        let filtered = options.onlyWaiting
            ? grouped.filter { $0.status.clearsOnFocus }
            : grouped

        let removed = grouped.filter { row in !filtered.contains { $0.id == row.id } }

        return ColumnRendering(
            rows: sorted(filtered, options: options),
            hidden: summary(of: putAside, options: options),
            filteredOut: removed.reduce(0) { $0 + $1.count }
        )
    }

    // MARK: - Building the rows

    /// Rows, one per project.
    ///
    /// Grouping exists because of a measurement: 22 sessions across 12 windows
    /// drew 22 targets for 12 raisable windows, and ten of those targets led where
    /// another already led. The sessions were **interchangeable destinations**,
    /// and one dot for them was the whole point.
    ///
    /// For one day this keyed on the project **and the agent**, because a folder
    /// that held Claude and Codex at once went green while Claude was still
    /// working: `ready` outranks `working`, and the half the dot hid was the half
    /// that says *do not start anything here yet*. Two rows fixed it by giving
    /// each agent a dot of its own.
    ///
    /// It keys on the project again, and what changed is not the danger but what a
    /// row can say. One dot could not say two things. A row can now say four: the
    /// dominant state, the state that state is **covering** (`recalledStatus`), how
    /// many sessions are inside, and the whole list when it is opened. So a folder
    /// goes back to being one place, which is what a folder is, and the agent moves
    /// down to the line that actually belongs to it.
    private static func group(_ sessions: [SessionState], options: ColumnOptions) -> [ColumnRow] {
        var byProject: [String: [SessionState]] = [:]
        var order: [String] = []
        for session in sessions {
            let key = session.workspace.key
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(session)
        }

        return order.compactMap { key in
            guard let members = byProject[key] else { return nil }
            // `state.ordered` arrives already sorted by urgency, and grouping
            // preserves that order: the first one is the most urgent.
            return ColumnRow(
                id: key,
                workspace: members[0].workspace,
                sessions: members,
                slot: options.slot(for: key),
                alias: options.name(for: key),
                names: options.names,
                order: options.conversationOrder[key] ?? []
            )
        }
    }

    // MARK: - Ordering

    /// The user's order, and nothing else moves a row.
    ///
    /// Urgency stays out of this on purpose (D23). A column that re-sorts itself
    /// has to be re-read every time it changes, a green that jumps to the top
    /// pushes every other row down by one, and a row that moves under the pointer
    /// is how the wrong session gets opened. A row that needs you still lights up
    /// — where it always is.
    ///
    /// A project not yet in the order — possible for one render, before the store
    /// gives it a place — sorts after every known one, by name. With grouping
    /// off a project has several rows at the same position; among them the most
    /// urgent comes first, so the click and the key agree about which one they
    /// mean, then the longest wait, then the id, so nothing jitters between updates.
    private static func sorted(_ rows: [ColumnRow], options: ColumnOptions) -> [ColumnRow] {
        rows.sorted { lhs, rhs in
            let left = options.position(for: lhs.workspace.key)
            let right = options.position(for: rhs.workspace.key)
            if left != right { return left < right }
            if lhs.workspace.key != rhs.workspace.key {
                let byName = lhs.workspace.name.localizedStandardCompare(rhs.workspace.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.workspace.key < rhs.workspace.key
            }
            if lhs.status.urgencyRank != rhs.status.urgencyRank {
                return lhs.status.urgencyRank < rhs.status.urgencyRank
            }
            if lhs.statusSince != rhs.statusSince { return lhs.statusSince < rhs.statusSince }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Summary of what's hidden

    private static func summary(of sessions: [SessionState], options: ColumnOptions) -> HiddenSummary? {
        guard !sessions.isEmpty else { return nil }

        let mostUrgent = sessions
            .map(\.status)
            .min { $0.urgencyRank < $1.urgencyRank } ?? .idle

        let names = Set(sessions.map {
            options.name(for: $0.workspace.key) ?? $0.displayName
        }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        return HiddenSummary(
            sessionCount: sessions.count,
            status: mostUrgent,
            workspaceNames: names
        )
    }
}
