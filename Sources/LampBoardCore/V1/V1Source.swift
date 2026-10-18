import Foundation

/// What a machine provides so that `V1Service` can serve it (§2.2): its state,
/// its numbered journal, and the few things a phone may ask of it.
///
/// `lampd` implements it over its reducer and journal, the Mac over its
/// `StateStore`. Neither writes the protocol: the service turns this into
/// messages, the same way for both, and the conformance suite holds every
/// implementation to the same bytes.
///
/// Called from one connection's thread at a time; an implementation that
/// serves several connections guards its own state.
public protocol V1Source: AnyObject {

    var identity: V1SourceIdentity { get }

    /// What `hello` says of the source, at `now`.
    func status(at now: Date) -> V1SourceStatus

    /// The whole state, and the journal point it stands at.
    func snapshot(at now: Date) -> V1State

    /// The events after `seq` in the current journal, oldest first, or
    /// `.unreachable` when the journal no longer goes back that far.
    func events(after seq: Int) -> V1Replay

    /// The last messages of a session's conversation, or `nil` when the source
    /// has no such session or no conversation for it.
    func transcript(session: String, limit: Int) -> V1Transcript?

    /// One low-power action, already validated (`V1Command.problem`).
    func perform(_ command: V1Command, by peer: V1Peer, at now: Date) -> V1Failure?

    /// A device's push registration, already validated; the source's half of
    /// the envelope key when it takes it (§2.8, point 2).
    func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> Result<V1PushAccepted, V1Failure>

    /// The paired devices, or a revocation. Only ever called for the action key.
    func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure>

    /// «While you were away» for that device, said once in its `hello`.
    func away(for peer: V1Peer, at now: Date) -> String?
}

extension V1Source {
    /// A source that keeps no ledger says nothing.
    public func away(for peer: V1Peer, at now: Date) -> String? { nil }
}

/// What `hello` reports of a source.
public struct V1SourceStatus: Equatable, Sendable {
    public let version: String
    public let startedAt: Date
    public let binaryModifiedAt: Date?
    public let configModifiedAt: Date?
    public let journal: String
    public let seq: Int
    public let lastEventAt: Date?
    public let lastProbeAt: Date?
    public let relay: V1RelayHealth?
    /// How the source is serving this connection, when it can serve it two ways
    /// (`lampd`: its service, or the files read by the connection itself).
    public let mode: V1ServingMode?
    /// The Mac's settings the phone needs for this source (W5, §2.12): the Mac's
    /// own, or the copy it wrote into a node's `lampd`. Absent until written.
    public let settings: MacNodeSettings?

    public init(
        version: String, startedAt: Date, binaryModifiedAt: Date? = nil, configModifiedAt: Date? = nil,
        journal: String, seq: Int, lastEventAt: Date?, lastProbeAt: Date?, relay: V1RelayHealth? = nil,
        mode: V1ServingMode? = nil, settings: MacNodeSettings? = nil
    ) {
        self.version = version
        self.startedAt = startedAt
        self.binaryModifiedAt = binaryModifiedAt
        self.configModifiedAt = configModifiedAt
        self.journal = journal
        self.seq = seq
        self.lastEventAt = lastEventAt
        self.lastProbeAt = lastProbeAt
        self.relay = relay
        self.mode = mode
        self.settings = settings
    }
}

public enum V1Replay: Equatable, Sendable {
    case events([V1Event])
    /// The journal was trimmed past the point asked for: only a whole state
    /// brings the client back.
    case unreachable
}

/// How a source that can serve a connection two ways is serving this one.
///
/// A node's `lampd` serves from its running service: one journal for every
/// connection, numbered events kept across restarts, the person's choices
/// written as they are made. When the service is stopped, the same command a
/// read key is forced to run still answers, reading Claude Code's files itself
/// for as long as the connection lasts (E10 as amended on 17 October 2026): the
/// lights stay on, and the phone says so instead of asking for Face ID.
public enum V1ServingMode: String, Codable, Sendable, CaseIterable {
    /// The service is running and this connection is its.
    case live
    /// The service is not running: this connection reads the files itself.
    case files
}
