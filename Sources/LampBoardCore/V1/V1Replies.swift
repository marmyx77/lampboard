import Foundation

/// What a source says. Each reply is one JSON object with a `type`; an answer
/// to a request carries the request's `id` as `re`, and what the source sends
/// of its own accord — events, pings, the goodbye — carries none.
public enum V1Reply: Equatable, Sendable {
    case hello(V1Hello)
    case state(V1State)
    case events(V1EventsAck)
    case event(V1Event)
    case ping(V1Ping)
    case transcript(V1Transcript)
    case result(V1Result)
    case devices([V1Device])
    case error(V1Failure)
    /// The source is going away (an orderly stop): the client reconnects later.
    case bye(reason: String)

    /// Every `type` this build knows.
    public static let types: Set<String> = [
        "hello", "state", "events", "event", "ping", "transcript", "result", "devices", "error", "bye",
    ]

    public var type: String {
        switch self {
        case .hello: return "hello"
        case .state: return "state"
        case .events: return "events"
        case .event: return "event"
        case .ping: return "ping"
        case .transcript: return "transcript"
        case .result: return "result"
        case .devices: return "devices"
        case .error: return "error"
        case .bye: return "bye"
        }
    }
}

/// The answer to `hello`: what the source is and **how old its state is**.
///
/// The age is there for the failure this project's Linux machine is known for:
/// a service that is alive and answering, from a state nobody has refreshed in
/// days (`~/AGENTS.md`). A liveness check cannot see it; an age can.
public struct V1Hello: Codable, Equatable, Sendable {
    public let `protocol`: Int
    public let minClient: Int
    /// The source's own version, e.g. `2.4.0`.
    public let version: String
    public let source: V1SourceIdentity
    public let startedAt: Date
    /// When the running binary and its configuration were last written: a
    /// process older than either is running yesterday's code or settings.
    public let binaryModifiedAt: Date?
    public let configModifiedAt: Date?
    public let stateAge: V1StateAge
    /// The last answer from the push relay, when there was one (§2.8).
    public let relay: V1RelayHealth?
    /// What this connection's key may do.
    public let role: V1Role
    /// How a source that can serve two ways serves this connection; absent for
    /// one that serves only one way. A client one version behind ignores it.
    public let mode: V1ServingMode?
    /// What happened while this device was away from the app, once (§5.8);
    /// absent when nothing the column does not show.
    public let away: String?

    public init(
        protocol: Int = V1Protocol.version, minClient: Int = V1Protocol.minClient, version: String,
        source: V1SourceIdentity, startedAt: Date, binaryModifiedAt: Date? = nil, configModifiedAt: Date? = nil,
        stateAge: V1StateAge, relay: V1RelayHealth? = nil, role: V1Role, mode: V1ServingMode? = nil, away: String? = nil
    ) {
        self.protocol = `protocol`
        self.minClient = minClient
        self.version = version
        self.source = source
        self.startedAt = startedAt
        self.binaryModifiedAt = binaryModifiedAt
        self.configModifiedAt = configModifiedAt
        self.stateAge = stateAge
        self.relay = relay
        self.role = role
        self.mode = mode
        self.away = away
    }
}

public struct V1StateAge: Codable, Equatable, Sendable {
    /// The last event in the journal.
    public let seq: Int
    /// When the last event was reduced, and when the source last looked at the
    /// disk itself (its five-second probe).
    public let lastEventAt: Date?
    public let lastProbeAt: Date?
    /// Seconds since the newer of the two, as the source counts them when it
    /// answers; `nil` when it has done neither yet.
    public let seconds: Double?

    public init(seq: Int, lastEventAt: Date?, lastProbeAt: Date?, at now: Date) {
        self.seq = seq
        self.lastEventAt = lastEventAt
        self.lastProbeAt = lastProbeAt
        let newest = [lastEventAt, lastProbeAt].compactMap { $0 }.max()
        self.seconds = newest.map { max(0, (now.timeIntervalSince($0) * 10).rounded() / 10) }
    }
}

public struct V1RelayHealth: Codable, Equatable, Sendable {
    /// `ok`, or what went wrong: `refused`, `quota`, `unreachable`.
    public let outcome: String
    public let at: Date
    /// For `quota`: the seconds the relay asked to wait (`Retry-After`), which
    /// the phone's strip says (§2.8, point 5).
    public let retryAfter: Int?
    /// The relay's own sentence, when it gave one: never a token.
    public let reason: String?

    public init(outcome: String, at: Date, retryAfter: Int? = nil, reason: String? = nil) {
        self.outcome = outcome
        self.at = at
        self.retryAfter = retryAfter
        self.reason = reason
    }

    /// Until when the relay asked this source to hold back, if it did.
    public var holdUntil: Date? {
        guard outcome == "quota", let retryAfter, retryAfter > 0 else { return nil }
        return at.addingTimeInterval(TimeInterval(retryAfter))
    }
}

/// A source's whole state at one point of its journal.
public struct V1State: Codable, Equatable, Sendable {
    /// The journal this state belongs to. A source whose journal started again
    /// (a restart with nothing kept) has a new one, and a client holding numbers
    /// from the old one starts over instead of asking for numbers that now mean
    /// something else.
    public let journal: String
    /// The last event this state includes.
    public let seq: Int
    public let source: V1SourceIdentity
    /// The rows; `null` when the source has never known them, never `[]` for
    /// "could not look" (D21). A source that lost sight of a machine sends that
    /// machine's last rows with `rowsAt`, their age.
    public let rows: [V1Row]?
    public let rowsAt: Date?
    public let at: Date

    public init(journal: String, seq: Int, source: V1SourceIdentity, rows: [V1Row]?, rowsAt: Date?, at: Date) {
        self.journal = journal
        self.seq = seq
        self.source = source
        self.rows = rows
        self.rowsAt = rowsAt
        self.at = at
    }

    /// Always written, `null` included: an absent key and a `null` would read
    /// the same to a client, and the contract says which one a source sends.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(journal, forKey: .journal)
        try c.encode(seq, forKey: .seq)
        try c.encode(source, forKey: .source)
        try c.encode(rows, forKey: .rows)
        try c.encodeIfPresent(rowsAt, forKey: .rowsAt)
        try c.encode(at, forKey: .at)
    }
}

/// The answer to `events`, before anything it announces.
public struct V1EventsAck: Codable, Equatable, Sendable {
    public let journal: String
    /// What the client said it held; `nil` for nothing.
    public let since: Int?
    /// How many events follow from the journal before the stream is live.
    public let replayed: Int
    /// `true` when a whole state follows instead: the client held nothing, held
    /// numbers of another journal, or held numbers the journal no longer reaches.
    public let resync: Bool
    /// Seconds between pings on this stream.
    public let ping: TimeInterval

    public init(journal: String, since: Int?, replayed: Int, resync: Bool, ping: TimeInterval) {
        self.journal = journal
        self.since = since
        self.replayed = replayed
        self.resync = resync
        self.ping = ping
    }
}

/// One numbered change to a source's state.
public struct V1Event: Equatable, Sendable {
    public let seq: Int
    public let at: Date
    public let change: Change

    public enum Change: Equatable, Sendable {
        /// A row appeared or changed: the whole row, never a patch.
        case row(V1Row)
        /// A row is gone.
        case gone(id: String)
    }

    public init(seq: Int, at: Date, change: Change) {
        self.seq = seq
        self.at = at
        self.change = change
    }

    /// Every `kind` of event this build knows.
    public static let kinds: Set<String> = ["row", "gone"]

    public var rowId: String {
        switch change {
        case .row(let row): return row.id
        case .gone(let id): return id
        }
    }
}

extension V1Event: Codable {
    private enum Keys: String, CodingKey { case seq, at, kind, row, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decode(Date.self, forKey: .at)
        switch try c.decode(String.self, forKey: .kind) {
        case "row": change = .row(try c.decode(V1Row.self, forKey: .row))
        case "gone": change = .gone(id: try c.decode(String.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown event kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(at, forKey: .at)
        switch change {
        case .row(let row):
            try c.encode("row", forKey: .kind)
            try c.encode(row, forKey: .row)
        case .gone(let id):
            try c.encode("gone", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

/// Sent every interval on an event stream. It carries the last number sent, so
/// a client that holds less knows it missed something, even with nothing new.
public struct V1Ping: Codable, Equatable, Sendable {
    public let seq: Int
    public let at: Date

    public init(seq: Int, at: Date) {
        self.seq = seq
        self.at = at
    }
}

/// The tail of a conversation, and always how much of it was left out.
public struct V1Transcript: Codable, Equatable, Sendable {
    public let session: String
    public let messages: [Message]
    /// The messages before these that were not sent. Never omitted: a reader
    /// that shows the tail as the whole is reading a different conversation.
    public let notSent: Int

    public struct Message: Codable, Equatable, Sendable {
        /// `user` or `assistant`.
        public let role: String
        public let text: String
        public let at: Date?

        public init(role: String, text: String, at: Date?) {
            self.role = role
            self.text = text
            self.at = at
        }
    }

    public init(session: String, messages: [Message], notSent: Int) {
        self.session = session
        self.messages = messages
        self.notSent = notSent
    }
}

public struct V1Result: Codable, Equatable, Sendable {
    /// The request it answers, by `op`.
    public let op: String
    /// For `push.register`: what the device needs to open this source's
    /// envelopes.
    public let push: V1PushAccepted?

    public init(op: String, push: V1PushAccepted? = nil) {
        self.op = op
        self.push = push
    }
}

/// A source's answer to `push.register`: its half of the envelope key and the
/// names the key is bound to (`PushEnvelope.key(mine:theirs:source:device:)`).
///
/// The device learns its own name here: it is the one the source gave it at
/// pairing (`lampd devices add`), which the phone was never told.
public struct V1PushAccepted: Codable, Equatable, Sendable {
    /// The source's X25519 public key, base64.
    public let envelopeKey: String
    /// The source's name in the key derivation.
    public let source: String
    /// The device's name in the key derivation.
    public let device: String

    public init(envelopeKey: String, source: String, device: String) {
        self.envelopeKey = envelopeKey
        self.source = source
        self.device = device
    }
}

public struct V1Device: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let pairedAt: Date
    public let lastSeenAt: Date?

    public init(id: String, name: String, pairedAt: Date, lastSeenAt: Date?) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// A refusal, with a code a client can act on and a sentence a person can read.
public struct V1Failure: Codable, Equatable, Sendable, Error {
    public let code: Code
    public let message: String

    public enum Code: String, Codable, Sendable {
        /// Not a JSON object with an `op`.
        case malformed
        case unknownOp
        /// A known `op` with fields that do not fit it.
        case badRequest
        /// Anything before `hello`.
        case helloFirst
        /// The client is older than the source's `minClient`; the source closes.
        case clientTooOld
        /// The connection's key may not do this.
        case forbidden
        case notFound
        /// The bytes are out of step; the source closes.
        case badFrame
        /// The source cannot do it now (a machine it cannot reach).
        case unavailable
    }

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}
