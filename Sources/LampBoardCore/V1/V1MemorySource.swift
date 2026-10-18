#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The reference source: rows and a journal held in memory, and the
/// low-power actions carried out on them.
///
/// It is the source the conformance suite is first run against, the one the
/// client is tested with, and the one the demo mode will serve (§2.14). It is
/// deliberately plain: whatever it does is what `lampd` and the Mac are held to.
///
/// Not thread-safe by itself: one connection at a time, or a lock outside.
public final class V1MemorySource: V1Source {

    public let identity: V1SourceIdentity
    public let version: String
    public let startedAt: Date
    public private(set) var journal: String
    public private(set) var lastProbeAt: Date?
    public var relay: V1RelayHealth?

    /// What was asked of it, in order: the tests read it to see that a refused
    /// command never got this far.
    public private(set) var performed: [V1Command] = []
    public private(set) var registrations: [String: V1PushRegistration] = [:]
    /// When each device last said it was in use (`focus`): what decides which
    /// one rings (Q9).
    public private(set) var focusedAt: [String: Date] = [:]
    /// Its half of every envelope key: one per run, enough for a reference.
    public let pushKey = Curve25519.KeyAgreement.PrivateKey()

    private var rows: [String: V1Row] = [:]
    private var known: Bool
    private var rowsAt: Date?
    private var log: [V1Event] = []
    private var seq = 0
    private let retention: Int
    private var transcripts: [String: [V1Transcript.Message]] = [:]
    private var paired: [V1Device]

    /// - Parameters:
    ///   - retention: how many events the journal keeps; older numbers are
    ///     answered with a whole state.
    ///   - known: `false` for a source that has never seen its rows: its state
    ///     says `null`, not an empty column.
    public init(
        identity: V1SourceIdentity, version: String = "test", startedAt: Date, journal: String,
        retention: Int = 1000, known: Bool = true, devices: [V1Device] = []
    ) {
        self.identity = identity
        self.version = version
        self.startedAt = startedAt
        self.journal = journal
        self.retention = max(1, retention)
        self.known = known
        self.paired = devices
    }

    // MARK: - Changing it, as hooks and probes change a real one

    /// A row appears or changes: one event.
    public func upsert(_ row: V1Row, at now: Date) {
        known = true
        rows[row.id] = row
        rowsAt = now
        append(.row(row), at: now)
    }

    /// A row goes: one event, and nothing for a row that was not there.
    public func remove(id: String, at now: Date) {
        guard rows.removeValue(forKey: id) != nil else { return }
        rowsAt = now
        append(.gone(id: id), at: now)
    }

    /// The source looked at its disk and found nothing new.
    public func probed(at now: Date) {
        lastProbeAt = now
    }

    /// The rows are known, and are as they were at `rowsAt`: a source that
    /// asked and found nothing has an empty column, not an unknown one, and one
    /// that lost sight of its machine says how old its rows are (D21).
    public func confirm(rowsAt: Date) {
        known = true
        self.rowsAt = rowsAt
    }

    /// A restart that kept nothing: a new journal, numbered from zero.
    public func restartJournal(_ name: String) {
        journal = name
        log = []
        seq = 0
    }

    public func setTranscript(session: String, messages: [V1Transcript.Message]) {
        transcripts[session] = messages
    }

    public func row(_ id: String) -> V1Row? { rows[id] }

    private func append(_ change: V1Event.Change, at now: Date) {
        seq += 1
        log.append(V1Event(seq: seq, at: now, change: change))
        if log.count > retention { log.removeFirst(log.count - retention) }
    }

    // MARK: - V1Source

    public func status(at now: Date) -> V1SourceStatus {
        V1SourceStatus(
            version: version, startedAt: startedAt, journal: journal, seq: seq,
            lastEventAt: log.last?.at, lastProbeAt: lastProbeAt, relay: relay
        )
    }

    public func snapshot(at now: Date) -> V1State {
        let ordered = rows.values.sorted { ($0.extras.order ?? Int.max, $0.id) < ($1.extras.order ?? Int.max, $1.id) }
        return V1State(journal: journal, seq: seq, source: identity, rows: known ? ordered : nil, rowsAt: rowsAt, at: now)
    }

    public func events(after since: Int) -> V1Replay {
        if since >= seq { return .events([]) }
        // The first number the journal still holds; anything before it is gone.
        guard let first = log.first?.seq, since >= first - 1 else { return .unreachable }
        return .events(log.filter { $0.seq > since })
    }

    public func transcript(session: String, limit: Int) -> V1Transcript? {
        guard let messages = transcripts[session] else { return nil }
        let tail = Array(messages.suffix(limit))
        return V1Transcript(session: session, messages: tail, notSent: messages.count - tail.count)
    }

    public func perform(_ command: V1Command, by peer: V1Peer, at now: Date) -> V1Failure? {
        performed.append(command)
        if command.action == .focus {
            focusedAt[peer.device] = now
            return nil
        }
        if command.action == .order {
            for (place, id) in (command.ids ?? []).enumerated() {
                guard let row = rows[id] else { continue }
                var extras = row.extras
                extras.order = place
                upsert(row.with(extras: extras), at: now)
            }
            return nil
        }
        guard let id = command.session, let row = rows[id] else {
            return V1Failure(.notFound, "no row \(command.session ?? "")")
        }
        var extras = row.extras
        switch command.action {
        case .markSeen: extras.readAt = now
        case .markUnread: extras.readAt = nil
        case .hide: extras.hidden = command.on ?? true
        case .rename: upsert(row.with(session: row.session.with(label: command.name ?? "")), at: now); return nil
        case .mute: upsert(row.with(session: row.session.with(muted: command.on ?? true)), at: now); return nil
        case .dismiss: remove(id: id, at: now); return nil
        // Calming a blink changes how the panel draws a row, not what the row says.
        case .calmBlink, .focus, .order: return nil
        }
        upsert(row.with(extras: extras), at: now)
        return nil
    }

    public func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> Result<V1PushAccepted, V1Failure> {
        registrations[peer.device] = registration
        return .success(V1PushAccepted(envelopeKey: pushKey.publicKey.rawRepresentation.base64EncodedString(),
                                       source: identity.name, device: peer.device))
    }

    public func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure> {
        switch request.action {
        case .list:
            return .success(paired)
        case .revoke:
            guard let id = request.device, paired.contains(where: { $0.id == id }) else {
                return .failure(V1Failure(.notFound, "no device \(request.device ?? "")"))
            }
            paired.removeAll { $0.id == id }
            registrations[id] = nil
            return .success(paired)
        }
    }
}
