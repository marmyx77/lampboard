import Foundation

/// The numbers of the `v1` protocol that both ends must agree on.
///
/// One protocol, written once (§2.2 of the mobile plan): the Mac serves it over
/// its own ssh server, `lampd` behind OpenSSH, and the app reads it — all three
/// with this code, so that a rule cannot be true on one side and not the other.
public enum V1Protocol {

    /// What this build speaks.
    public static let version = 1

    /// The oldest client a source of this build still answers. Raised only on
    /// purpose: an app on the phone is updated when the person updates it, not
    /// when the Mac does.
    public static let minClient = 1

    /// Seconds between two pings on an event stream, unless the client asks.
    public static let defaultPingInterval: TimeInterval = 15

    /// The range a client may ask for. Below it a ping is a busy loop; above it
    /// a dead connection takes minutes to notice.
    public static let pingRange: ClosedRange<TimeInterval> = 0.2...60

    /// The ping interval a source uses for what a client asked.
    public static func pingInterval(asked: TimeInterval?) -> TimeInterval {
        guard let asked, asked.isFinite else { return defaultPingInterval }
        return min(max(asked, pingRange.lowerBound), pingRange.upperBound)
    }

    /// How long a client waits without a single message before it says that
    /// what it shows is old (E13 of W0): two intervals **and five seconds**.
    ///
    /// Two intervals alone was measured to be one ping too few. With a ping every
    /// 15 s, one ping lost on the way leaves a silence of exactly 30.00 s, and in
    /// S-H v2 both clients raised a false alarm on that line and took it back the
    /// same instant. With the margin one lost ping lights nothing and two do.
    public static func staleAfter(pingInterval: TimeInterval) -> TimeInterval {
        2 * pingInterval + 5
    }

    /// How many messages of a transcript a source sends when the client does
    /// not say, and the most it ever sends.
    public static let defaultTranscriptLimit = 50
    public static let maxTranscriptLimit = 500
}

/// Which kind of machine a source is: a Mac running the panel, or a node running
/// `lampd`. Part of every row, because the phone shows rows from both and must
/// know which one a row's actions go to.
public enum V1SourceKind: String, Codable, Sendable, CaseIterable {
    case mac
    case node
}

/// A source as it names itself.
public struct V1SourceIdentity: Codable, Equatable, Sendable {
    public let kind: V1SourceKind
    /// The name the person gave the machine, never its host name: real host
    /// names carry personal data (S-P).
    public let name: String

    public init(kind: V1SourceKind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// What a connection's key may do (§2.4): the read key opens the `v1` channel
/// and nothing else; the action key also manages the paired devices.
public enum V1Role: String, Codable, Sendable {
    case read
    case action
}

/// Who is at the other end of one connection, as the transport established it:
/// `lampd v1-stdio --device <id>` behind a restricted key, or the Mac's server
/// after checking a paired key. Never something the client says of itself.
public struct V1Peer: Equatable, Sendable {
    public let device: String
    public let role: V1Role

    public init(device: String, role: V1Role) {
        self.device = device
        self.role = role
    }
}
