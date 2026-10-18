import Foundation

/// The Mac and a node's `lampd`, on the ssh connection the Mac already opens
/// for its tunnel (§2.3, §2.9, §2.12 of the mobile plan, W5).
///
/// The tunnel's ssh runs `lampd mac-link` on the node instead of nothing. Down
/// that connection the Mac writes what `lampd` keeps for the node's rows and
/// cannot learn by itself: where the person is (Q8), the Mac's settings the
/// phone needs for the node (the permission mode of D169, *Send messages*, the
/// palette), the low-power changes made in the panel to the node's rows, and
/// once, the panel's own copy of those choices (the migration). Up it, `lampd`
/// says every `heartbeatInterval` whether it is serving — which decides the
/// tunnel's port and who notifies for the node's rows — and, when they change,
/// the person's choices about the node's rows, so a row read on the phone reads
/// as read in the panel.
///
/// One JSON object per line each way. Nothing in it runs anything, and nothing
/// goes from the node to the Mac but lights and choices (R2): the node never
/// sends the Mac a command.
public enum MacNodeLink {
    /// What the tunnel runs on the node: `lampd mac-link`, or, where `lampd` is
    /// not installed or not this version, a wait that keeps the forward up and
    /// says nothing. Silence is "no healthy `lampd`".
    public static let command = "mac-link"

    /// The node's command line, for `ssh … host <this>`. `lampd` is looked for
    /// where `Scripts/lampd-install.sh` puts it.
    public static let remoteCommand =
        #"L="$HOME/.local/bin/lampd"; if [ -x "$L" ]; then "$L" mac-link; fi; exec tail -f /dev/null"#

    /// How often `lampd mac-link` says how it is (§2.3 point 2: a probe every 0.3 s).
    public static let heartbeatInterval: TimeInterval = 0.3
    /// The tunnel leaves the hooks' port to `lampd` after this many healthy
    /// beats in a row (E2: M = 3)…
    public static let healthyAfter = 3
    /// …and takes it back at the first beat that says `lampd` is not serving,
    /// or after this long without any (N = 1 beat, with a margin for the network).
    public static let silentAfter: TimeInterval = 2

    /// The header `lampd` puts on every hook event it forwards to the Mac (E3):
    /// `<journal>-<n>`. The Mac 2.4 drops one it has already taken, so an event
    /// that arrived both ways during a switch counts once.
    public static let eventHeader = "X-LampBoard-Event"

    /// The tunnel's port on the node when `lampd` holds the hooks' port: the
    /// next one (§2.3 point 4: 31001 next to 31000). `~/.lampboard/port` keeps
    /// the primary, which the hooks always post to.
    public static func secondaryPort(of primary: UInt16) -> UInt16 { primary &+ 1 }

    /// A line in either direction is at most this long; the migration of a
    /// thousand rows fits.
    public static let maxLine = 1 << 20

    public static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = V1Codec.encoder()
        guard let data = try? encoder.encode(value), data.count < maxLine else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ line: String) -> T? {
        guard line.utf8.count < maxLine else { return nil }
        return try? V1Codec.decoder().decode(type, from: Data(line.utf8))
    }
}

/// Where the person is, as the Mac knows it (Q8).
public enum MacPresence: String, Codable, Sendable, CaseIterable {
    /// At the Mac: the panel shows and its banners ring; the phone stays quiet.
    case here
    /// Said away, or the screen locked long enough (D114): the phone rings.
    case away
    /// The Mac is going to sleep: the phone rings, and its last word said so.
    case asleep
}

/// The Mac's settings a node keeps for the phone (§2.12): the phone reads them
/// from the node, where the Mac wrote them.
public struct MacNodeSettings: Codable, Equatable, Sendable {
    /// The permission mode sessions start in (D169), `NewSession.Permissions`'
    /// raw value. Bypass from the start is offered on the node only when the
    /// Mac's own is Bypass.
    public var permissionMode: String?
    /// *Send messages* (D172): `@name` and «Mention in…» to the node's sessions.
    public var sendMessages: Bool?
    /// The terminal's colours, *Like my VS Code* included: the palette request's
    /// answer, as the Mac gives it to the phone.
    public var palette: String?

    public init(permissionMode: String? = nil, sendMessages: Bool? = nil, palette: String? = nil) {
        self.permissionMode = permissionMode
        self.sendMessages = sendMessages
        self.palette = palette
    }

    /// Whether a session may start in Bypass on the node.
    public var bypassAllowed: Bool { permissionMode == NewSession.Permissions.bypass.rawValue }
}

/// One line from the Mac to `lampd mac-link`. Exactly one field is set.
public struct MacToNode: Codable, Equatable, Sendable {
    public var presence: MacPresence?
    public var settings: MacNodeSettings?
    /// A low-power change made in the panel to one of the node's rows. The
    /// node applies it as it applies a phone's, the Mac being the peer `mac`.
    public var command: V1Command?
    /// The panel's own choices about the node's rows, with their dates, merged
    /// once into the node's (`RowPreferences.merged(with:)`): the file's shape.
    public var migration: RowPreferencesWire?
    public var at: Date

    public init(presence: MacPresence? = nil, settings: MacNodeSettings? = nil, command: V1Command? = nil,
                migration: RowPreferencesWire? = nil, at: Date) {
        self.presence = presence
        self.settings = settings
        self.command = command
        self.migration = migration
        self.at = at
    }

    /// Why the line cannot be taken, or `nil`.
    public var problem: String? {
        let set = [presence != nil, settings != nil, command != nil, migration != nil].filter { $0 }.count
        if set != 1 { return "a line from the Mac carries exactly one thing" }
        if let command, let problem = command.problem { return problem }
        if command?.action == .focus { return "focus is a device's, not the Mac's" }
        return nil
    }
}

/// One line from `lampd mac-link` to the Mac.
public struct NodeToMac: Codable, Equatable, Sendable {
    /// Whether the service answered this beat. Present on every heartbeat.
    public var serving: Bool?
    /// The service's journal and last event, when serving.
    public var journal: String?
    public var seq: Int?
    /// Why not, when not serving: "not running", "no answer in 1 s"…
    public var reason: String?
    /// The person's choices about the node's rows, when they changed and once
    /// at the start of the link.
    public var preferences: RowPreferencesWire?
    public var at: Date

    public init(serving: Bool? = nil, journal: String? = nil, seq: Int? = nil, reason: String? = nil,
                preferences: RowPreferencesWire? = nil, at: Date) {
        self.serving = serving
        self.journal = journal
        self.seq = seq
        self.reason = reason
        self.preferences = preferences
        self.at = at
    }
}

/// `RowPreferences` as it travels: the preferences file's own bytes, so the
/// Mac, the node and the file read one shape.
public struct RowPreferencesWire: Codable, Equatable, Sendable {
    public let json: String

    public init(_ preferences: RowPreferences) {
        json = (try? preferences.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public var preferences: RowPreferences { RowPreferences.decode(Data(json.utf8)) }
}

/// What the tunnel does with the heartbeats it reads (§2.3 points 2–3): the
/// port to hold, decided from the beats alone, so the rule is tested without
/// ssh and without a clock.
public struct MacNodeLinkWatch: Equatable, Sendable {
    public enum Port: Equatable, Sendable {
        /// The hooks' port: no healthy `lampd`, the Mac receives the hooks.
        case primary
        /// The next one: `lampd` holds the hooks' port and forwards.
        case secondary
    }

    public private(set) var port: Port
    public private(set) var healthyInARow = 0
    public private(set) var lastBeat: Date?

    public init(port: Port = .primary) { self.port = port }

    /// Whether `lampd` is to be treated as healthy now: it owns the node's rows
    /// (§2.9) and the Mac stops notifying them.
    public func lampdHealthy(at now: Date) -> Bool {
        guard let lastBeat, now.timeIntervalSince(lastBeat) <= MacNodeLink.silentAfter else { return false }
        return healthyInARow >= MacNodeLink.healthyAfter
    }

    /// A beat read. Returns the port the tunnel should hold after it.
    @discardableResult
    public mutating func beat(_ line: NodeToMac, at now: Date) -> Port {
        guard let serving = line.serving else { return port }
        lastBeat = now
        if serving {
            healthyInARow += 1
            if healthyInARow >= MacNodeLink.healthyAfter { port = .secondary }
        } else {
            healthyInARow = 0
            port = .primary
        }
        return port
    }

    /// Time passing without beats: past `silentAfter`, the port goes back.
    @discardableResult
    public mutating func tick(at now: Date) -> Port {
        if let lastBeat, now.timeIntervalSince(lastBeat) > MacNodeLink.silentAfter {
            healthyInARow = 0
            port = .primary
        } else if lastBeat == nil {
            port = .primary
        }
        return port
    }
}

extension MacNodeLink {
    /// The Mac says where the person is at least this often, even when it has
    /// not changed: a node cannot tell a Mac that is still there from one that
    /// vanished without a word (power cut, a connection that died half-way)…
    public static let presenceRefresh: TimeInterval = 60
    /// …so a `here` older than this is taken for away, and the phone rings
    /// again (Q8): a lost Mac must never keep the phone quiet.
    public static let presenceStaleAfter: TimeInterval = 600
    /// A `here` stays good this long after the last `lampd mac-link` of the
    /// Mac went (a tunnel moving between ports, a reconnection); past it, away.
    public static let linkGrace: TimeInterval = 60
}
