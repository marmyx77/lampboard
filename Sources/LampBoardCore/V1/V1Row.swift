import Foundation

/// One row of the column as a source sends it: the read endpoint's session
/// snapshot, the fields the phone needs beyond it, and whose row it is.
///
/// Flat on the wire. The snapshot's keys and these sit side by side in one JSON
/// object, so a reader of `GET /sessions` already knows most of a `v1` row, and
/// the snapshot stays the one place its fields are defined.
public struct V1Row: Codable, Equatable, Sendable {

    public let session: SessionSnapshot
    /// The machine the row comes from.
    public let source: V1SourceIdentity
    /// The source that notifies for this row (§2.9): the node's `lampd` for its
    /// own sessions, the Mac for its own and for nodes without `lampd`. One
    /// owner per row, so that one transition rings once.
    public let owner: String
    public let extras: V1RowExtras

    public var id: String { session.id }

    public init(session: SessionSnapshot, source: V1SourceIdentity, owner: String? = nil, extras: V1RowExtras = V1RowExtras()) {
        self.session = session
        self.source = source
        self.owner = owner ?? source.name
        self.extras = extras
    }

    public func with(session: SessionSnapshot) -> V1Row {
        V1Row(session: session, source: source, owner: owner, extras: extras)
    }

    public func with(extras: V1RowExtras) -> V1Row {
        V1Row(session: session, source: source, owner: owner, extras: extras)
    }

    private enum Keys: String, CodingKey {
        case source, owner
    }

    public init(from decoder: Decoder) throws {
        session = try SessionSnapshot(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        source = try container.decode(V1SourceIdentity.self, forKey: .source)
        owner = try container.decode(String.self, forKey: .owner)
        extras = try V1RowExtras(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        // Three writers into the same object: JSON keeps one container per level,
        // which is what makes the row flat.
        try session.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(source, forKey: .source)
        try container.encode(owner, forKey: .owner)
        try extras.encode(to: encoder)
    }
}

/// What a `v1` row says beyond the read endpoint's snapshot (§2.2): what the
/// panel shows and the snapshot never had to carry, and the person's choices
/// about the row, which the phone both reads and changes.
///
/// Every field has a value meaning "nothing to say", so a source that does not
/// know one yet sends a row a client can still read.
public struct V1RowExtras: Codable, Equatable, Sendable {
    /// Minutes left on the prompt cache, when the source can tell.
    public var cacheMinutes: Int?
    /// Since when a working session has shown no sign of life.
    public var stuckSince: Date?
    /// The tool running now, by name.
    public var runningTool: String?
    /// A file another session is also editing.
    public var fileConflict: String?
    public var hidden: Bool
    public var folded: Bool
    /// The person's place for the row in the column; `nil` for the default order.
    public var order: Int?
    /// When the last answer was read; `nil` while it has not been.
    public var readAt: Date?
    /// When the row's machine was last asked, and whether it answered: a row
    /// from a machine that did not answer is sent with its age, never dropped
    /// (D21: `nil` is not `[]`).
    public var hostProbedAt: Date?
    public var hostReachable: Bool?
    /// Where the session can be reached by a terminal: `tmux:<session>`, or
    /// `nil` for one with no way in.
    public var terminal: String?
    /// The Remote Control session id, when the session has one.
    public var bridgeSessionId: String?
    /// The permission mode the session runs in (D169).
    public var permissionMode: String?
    /// A permission question the Mac is holding in process (D80, M9).
    public var heldByMac: Bool
    /// How the row's state was learned, when not from the session's own hooks:
    /// what the phone can and cannot trust in it (D176). `nil` is the usual
    /// case, a source that hears the session.
    public var stateBasis: V1StateBasis?

    public init(
        cacheMinutes: Int? = nil,
        stuckSince: Date? = nil,
        runningTool: String? = nil,
        fileConflict: String? = nil,
        hidden: Bool = false,
        folded: Bool = false,
        order: Int? = nil,
        readAt: Date? = nil,
        hostProbedAt: Date? = nil,
        hostReachable: Bool? = nil,
        terminal: String? = nil,
        bridgeSessionId: String? = nil,
        permissionMode: String? = nil,
        heldByMac: Bool = false,
        stateBasis: V1StateBasis? = nil
    ) {
        self.cacheMinutes = cacheMinutes
        self.stuckSince = stuckSince
        self.runningTool = runningTool
        self.fileConflict = fileConflict
        self.hidden = hidden
        self.folded = folded
        self.order = order
        self.readAt = readAt
        self.hostProbedAt = hostProbedAt
        self.hostReachable = hostReachable
        self.terminal = terminal
        self.bridgeSessionId = bridgeSessionId
        self.permissionMode = permissionMode
        self.heldByMac = heldByMac
        self.stateBasis = stateBasis
    }

    private enum Keys: String, CodingKey {
        case cacheMinutes, stuckSince, runningTool, fileConflict, hidden, folded, order, readAt
        case hostProbedAt, hostReachable, terminal, bridgeSessionId, permissionMode, heldByMac, stateBasis
    }

    /// Lenient on the flags: a row from a source one version behind, which did
    /// not send them yet, reads as a row with nothing hidden or held.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cacheMinutes = try c.decodeIfPresent(Int.self, forKey: .cacheMinutes)
        stuckSince = try c.decodeIfPresent(Date.self, forKey: .stuckSince)
        runningTool = try c.decodeIfPresent(String.self, forKey: .runningTool)
        fileConflict = try c.decodeIfPresent(String.self, forKey: .fileConflict)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        folded = try c.decodeIfPresent(Bool.self, forKey: .folded) ?? false
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        hostProbedAt = try c.decodeIfPresent(Date.self, forKey: .hostProbedAt)
        hostReachable = try c.decodeIfPresent(Bool.self, forKey: .hostReachable)
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal)
        bridgeSessionId = try c.decodeIfPresent(String.self, forKey: .bridgeSessionId)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        heldByMac = try c.decodeIfPresent(Bool.self, forKey: .heldByMac) ?? false
        // A basis this build does not know reads as none: the row is still shown.
        stateBasis = try c.decodeIfPresent(String.self, forKey: .stateBasis).flatMap(V1StateBasis.init(rawValue:))
    }

    /// The flags always, the rest when there is something to say.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(cacheMinutes, forKey: .cacheMinutes)
        try c.encodeIfPresent(stuckSince, forKey: .stuckSince)
        try c.encodeIfPresent(runningTool, forKey: .runningTool)
        try c.encodeIfPresent(fileConflict, forKey: .fileConflict)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(folded, forKey: .folded)
        try c.encodeIfPresent(order, forKey: .order)
        try c.encodeIfPresent(readAt, forKey: .readAt)
        try c.encodeIfPresent(hostProbedAt, forKey: .hostProbedAt)
        try c.encodeIfPresent(hostReachable, forKey: .hostReachable)
        try c.encodeIfPresent(terminal, forKey: .terminal)
        try c.encodeIfPresent(bridgeSessionId, forKey: .bridgeSessionId)
        try c.encodeIfPresent(permissionMode, forKey: .permissionMode)
        try c.encode(heldByMac, forKey: .heldByMac)
        try c.encodeIfPresent(stateBasis, forKey: .stateBasis)
    }
}

/// How a row's state was learned when no hook of the session reached the
/// source (D176).
public enum V1StateBasis: String, Codable, Sendable, CaseIterable {
    /// From Claude Code's own session file and the tail of its transcript, read
    /// over ssh on the machine where they are: needs you (amber: `waiting` in
    /// the file), working, paused on background work (blue: a background shell,
    /// or busy with the turn ended in the tail) or idle, the context of the last
    /// reply, when the session last spoke, where tmux holds it. The file says
    /// that something waits for the person, never the question, so an amber row
    /// read this way has nothing to answer from the list. An answer to read
    /// (green) and a failure (red) are told only by hooks, and never show.
    case sessionFile

    /// Heard from the hooks as they happen, on a machine whose `lampd` holds
    /// the hooks' port (W5): green, red and the question as the Mac has them.
    /// The file still lights a row the hooks left at rest and rests one they
    /// left working (D177). A client one version behind reads no basis.
    case hooks

    /// What the phone does not know of a row read this way, in words it can show.
    public var unknowns: [String] {
        switch self {
        case .hooks:
            return []
        case .sessionFile:
            return [
                "read from the session's own file, not heard: an answer to read and a failure do not show",
                "needs you, working, paused or resting as Claude Code's file and the transcript's last turn say",
                "a wait for you comes without its question: answer it in the session",
                "the time is when the session last spoke",
            ]
        }
    }
}

extension SessionSnapshot {
    /// The same snapshot with another label or mute: what a rename or a mute from
    /// the phone changes, and nothing else.
    public func with(label: String? = nil, muted: Bool? = nil) -> SessionSnapshot {
        SessionSnapshot(
            id: id, status: status, workspace: workspace, path: path,
            updatedAt: updatedAt, statusSince: statusSince, activeSubagents: activeSubagents,
            harness: harness, pendingAsk: pendingAsk, waitingOn: waitingOn,
            contextPercent: contextPercent, contextTokens: contextTokens, contextWindow: contextWindow,
            contextModel: contextModel, contextConfidence: contextConfidence, costUSD: costUSD,
            failureReason: failureReason, lastMessage: lastMessage, muted: muted ?? self.muted,
            slot: slot, transcriptPath: transcriptPath, git: git, host: host, entrypoint: entrypoint,
            origin: origin, title: title, jobId: jobId, summary: summary, needs: needs,
            unreadAnswers: unreadAnswers, label: label ?? self.label
        )
    }
}
