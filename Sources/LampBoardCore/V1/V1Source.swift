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

    /// A device's push registration, already validated.
    func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> V1Failure?

    /// The paired devices, or a revocation. Only ever called for the action key.
    func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure>
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

    public init(
        version: String, startedAt: Date, binaryModifiedAt: Date? = nil, configModifiedAt: Date? = nil,
        journal: String, seq: Int, lastEventAt: Date?, lastProbeAt: Date?, relay: V1RelayHealth? = nil
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
    }
}

public enum V1Replay: Equatable, Sendable {
    case events([V1Event])
    /// The journal was trimmed past the point asked for: only a whole state
    /// brings the client back.
    case unreachable
}
