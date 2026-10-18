import Foundation
import LampBoardCore

/// The Mac as a `v1` source (§2.2): the panel's rows, as the `StateStore`
/// already publishes them for `GET /sessions`, numbered into a journal.
///
/// It writes no protocol and keeps no state of its own beyond the journal: the
/// app hands it the rows each time its column changes (`update`), and the Core's
/// `V1Service` turns it into messages exactly as it does for `lampd`. What the
/// person asks from the phone (`perform`) goes back to the app, which owns the
/// choices, through `MacSourceActions`.
///
/// Thread-safe: the app updates it from the main actor while the server's
/// connections read it from their event loops.
public final class MacV1Source: V1Source, @unchecked Sendable {

    public let identity: V1SourceIdentity
    private let version: String
    private let startedAt: Date
    private let lock = NSLock()
    private let retention: Int
    private var journal: String
    private var rows: [String: V1Row] = [:]
    private var known = false
    private var rowsAt: Date?
    private var log: [V1Event] = []
    private var seq = 0
    private var lastUpdateAt: Date?
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private let actions: MacSourceActions
    /// When each device last said it was in use (`focus`): which one rings (Q9, W4).
    public private(set) var focusedAt: [String: Date] = [:]

    public init(identity: V1SourceIdentity, version: String, startedAt: Date, actions: MacSourceActions,
                retention: Int = 1000) {
        self.identity = identity
        self.version = version
        self.startedAt = startedAt
        self.actions = actions
        self.retention = max(1, retention)
        // A new journal for every run of the app: the Mac keeps no numbers on
        // disk, so a phone holding old ones is sent a whole state.
        journal = "mac-" + String(UInt64.random(in: 0...UInt64.max), radix: 36)
    }

    // MARK: - What the app tells it

    /// The rows the column shows now. One event per row that changed on the
    /// wire, one per row that went; nothing for rows that did not change.
    public func update(_ fresh: [V1Row], at now: Date) {
        let changed: Bool = locked {
            known = true
            rowsAt = now
            lastUpdateAt = now
            let before = seq
            let ids = Set(fresh.map(\.id))
            for id in rows.keys.sorted() where !ids.contains(id) {
                rows[id] = nil
                append(.gone(id: id), at: now)
            }
            for row in fresh where !Self.sameOnTheWire(rows[row.id], row) {
                rows[row.id] = row
                append(.row(row), at: now)
            }
            return seq != before
        }
        if changed { notify() }
    }

    /// Called whenever the journal grows; returns what `stopObserving` takes.
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        locked { observers[id] = callback }
        return id
    }

    public func stopObserving(_ id: UUID) {
        locked { observers[id] = nil }
    }

    public var currentRows: [V1Row] { locked { rows.values.sorted { $0.id < $1.id } } }

    // MARK: - V1Source

    public func status(at now: Date) -> V1SourceStatus {
        locked {
            V1SourceStatus(version: version, startedAt: startedAt, journal: journal, seq: seq,
                           lastEventAt: log.last?.at, lastProbeAt: lastUpdateAt, relay: actions.relayHealth(),
                           settings: actions.settings())
        }
    }

    public func snapshot(at now: Date) -> V1State {
        locked {
            let ordered = rows.values.sorted { ($0.extras.order ?? Int.max, $0.id) < ($1.extras.order ?? Int.max, $1.id) }
            return V1State(journal: journal, seq: seq, source: identity, rows: known ? ordered : nil, rowsAt: rowsAt, at: now)
        }
    }

    public func events(after since: Int) -> V1Replay {
        locked {
            if since >= seq { return .events([]) }
            guard let first = log.first?.seq, since >= first - 1 else { return .unreachable }
            return .events(log.filter { $0.seq > since })
        }
    }

    public func transcript(session: String, limit: Int) -> V1Transcript? {
        // Only a session the column shows: the phone cannot ask for any file.
        let path: String?? = locked { rows[session].map { $0.session.transcriptPath } }
        guard let path else { return nil }
        return actions.transcript(session, path, limit)
    }

    public func perform(_ command: V1Command, by peer: V1Peer, at now: Date) -> V1Failure? {
        if command.action == .focus {
            locked { focusedAt[peer.device] = now }
            actions.focused(peer.device, command.session, now)
            return nil
        }
        if let id = command.session, locked({ rows[id] == nil }) {
            return V1Failure(.notFound, "no row \(id)")
        }
        if command.action == .order, let ids = command.ids, locked({ ids.contains { rows[$0] == nil } }) {
            return V1Failure(.notFound, "a row in the order is not in the column")
        }
        return actions.perform(command, peer)
    }

    public func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> Result<V1PushAccepted, V1Failure> {
        // The seam for W4's relay client: until the Mac sends notifications, it
        // says so rather than taking a registration it would never use.
        actions.register(registration, peer) ?? .failure(V1Failure(.unavailable, "this Mac sends no notifications yet"))
    }

    public func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure> {
        actions.devices(request)
    }

    // MARK: - Inside

    private func append(_ change: V1Event.Change, at now: Date) {
        seq += 1
        log.append(V1Event(seq: seq, at: now, change: change))
        if log.count > retention { log.removeFirst(log.count - retention) }
    }

    private func notify() {
        let callbacks: [@Sendable () -> Void] = locked { Array(observers.values) }
        for callback in callbacks { callback() }
    }

    /// Two rows the phone cannot tell apart: the same bytes on the wire.
    static func sameOnTheWire(_ a: V1Row?, _ b: V1Row) -> Bool {
        guard let a else { return false }
        if a == b { return true }
        let encoder = V1Codec.encoder()
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// What the Mac's source hands back to the app: the person's choices are the
/// app's (§2.12: «idem per le righe del Mac — padrone il Mac»), and so are the
/// transcripts it can read and the devices it paired.
public struct MacSourceActions: Sendable {
    /// A low-power action on a row the column shows, already validated.
    public var perform: @Sendable (V1Command, V1Peer) -> V1Failure?
    /// The last messages of a conversation, from its transcript's path.
    public var transcript: @Sendable (_ session: String, _ path: String?, _ limit: Int) -> V1Transcript?
    /// The paired devices, and a revocation.
    public var devices: @Sendable (V1DevicesRequest) -> Result<[V1Device], V1Failure>
    /// A push registration (W4); `nil` while the Mac sends none.
    public var register: @Sendable (V1PushRegistration, V1Peer) -> Result<V1PushAccepted, V1Failure>?
    /// A device said it is in use (`focus`), in a session or in the column (W5).
    public var focused: @Sendable (_ device: String, _ session: String?, _ at: Date) -> Void
    /// The relay's last word to this Mac, for `hello` (W5).
    public var relayHealth: @Sendable () -> V1RelayHealth?
    /// The Mac's settings the phone needs (W5): the permission mode, *Send
    /// messages*, the palette.
    public var settings: @Sendable () -> MacNodeSettings?

    public init(
        perform: @escaping @Sendable (V1Command, V1Peer) -> V1Failure?,
        transcript: @escaping @Sendable (String, String?, Int) -> V1Transcript? = { session, path, limit in
            path.flatMap { MacTranscripts.read(session: session, path: $0, limit: limit) }
        },
        devices: @escaping @Sendable (V1DevicesRequest) -> Result<[V1Device], V1Failure>,
        register: @escaping @Sendable (V1PushRegistration, V1Peer) -> Result<V1PushAccepted, V1Failure>? = { _, _ in nil },
        focused: @escaping @Sendable (String, String?, Date) -> Void = { _, _, _ in },
        relayHealth: @escaping @Sendable () -> V1RelayHealth? = { nil },
        settings: @escaping @Sendable () -> MacNodeSettings? = { nil }
    ) {
        self.perform = perform
        self.transcript = transcript
        self.devices = devices
        self.register = register
        self.focused = focused
        self.relayHealth = relayHealth
        self.settings = settings
    }
}

/// The last messages of a conversation on this Mac, read with the Core's
/// `TranscriptTail`: what is a message and what is only activity is decided
/// there, as for the live view and for `lampd`.
public enum MacTranscripts {

    /// How much of a transcript is read, from its end.
    public static let window: UInt64 = 32 * 1024 * 1024

    public static func read(session: String, path: String, limit: Int) -> V1Transcript? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: newline)...]) }
        var tail = TranscriptTail()
        var kept: [V1Transcript.Message] = []
        var total = 0
        for entry in tail.consume(String(decoding: data, as: UTF8.self) + "\n") where entry.isConversation {
            total += 1
            kept.append(V1Transcript.Message(role: entry.kind == .human ? "user" : "assistant", text: entry.text, at: entry.timestamp))
            if kept.count > limit { kept.removeFirst(kept.count - limit) }
        }
        return V1Transcript(session: session, messages: kept, notSent: total - kept.count)
    }
}
