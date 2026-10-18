import Foundation

/// The phone's side of a `v1` connection to one source: what it holds, how old
/// that is, and when to start again.
///
/// Like the service it knows no transport. NodeLink opens a connection and calls
/// `connect`, writes what it returns, hands every byte that arrives to
/// `receive`, calls `tick` on a timer, and drops the connection and calls
/// `connect` again whenever the answer says `.reconnect`.
///
/// Two rules come from measurements, not from taste (S-H v2, E13 of W0):
/// - **A network that disappears does not close the stream.** In six 60-second
///   cuts over two hours neither TCP nor ssh closed anything; only the client's
///   own threshold noticed. So the client declares its state old by itself,
///   after `V1Protocol.staleAfter` without a single message, and comes back
///   with `since=<the last event it holds>`.
/// - **After a suspension the kernel hands over pings it held back**, up to 45.7
///   seconds late. They look fresh and are not. A message that ends a silence
///   longer than the threshold is not used: the state is declared old first,
///   the connection is dropped and taken again, and whatever else arrives on the
///   dropped one is thrown away, never counted twice.
public struct V1Client {

    public enum Event: Equatable, Sendable {
        /// The source answered `hello`.
        case hello(V1Hello)
        /// The rows changed.
        case changed
        /// What the client shows is old: `silence` seconds without a message.
        case stale(silence: TimeInterval)
        /// Drop this connection and call `connect` again.
        case reconnect(reason: String)
        /// The source and this app cannot talk: the app has to be updated.
        case incompatible(String)
        /// A request was refused.
        case refused(re: Int?, V1Failure)
        /// A transcript arrived.
        case transcript(V1Transcript)
        /// An answer to a request with nothing else to show.
        case done(re: Int?)
        /// A source took this device's push registration: its half of the
        /// envelope key (§2.8).
        case pushAccepted(re: Int?, V1PushAccepted)
        /// The source is stopping.
        case bye(String)
    }

    public let name: String
    public let pingInterval: TimeInterval

    /// The rows, in the source's order.
    public private(set) var rows: [V1Row] = []
    /// `false` while the source has never said what its rows are.
    public private(set) var rowsKnown = false
    public private(set) var hello: V1Hello?
    public private(set) var journal: String?
    public private(set) var lastSeq: Int?
    /// `true` from the moment the state is declared old until a new connection
    /// has answered.
    public private(set) var isStale = false
    /// Which connection is current. Bytes for any other are thrown away.
    public private(set) var connection = 0

    private var reader = V1FrameReader()
    private var lastArrival: Date
    private var nextId = 1
    private var live = false

    public init(name: String, pingInterval: TimeInterval = V1Protocol.defaultPingInterval, at now: Date) {
        self.name = name
        self.pingInterval = V1Protocol.pingInterval(asked: pingInterval)
        self.lastArrival = now
    }

    public var staleAfter: TimeInterval { V1Protocol.staleAfter(pingInterval: pingInterval) }

    /// A new connection: its number, and what to write on it first — `hello`,
    /// then the events after what is held, or everything when nothing is.
    public mutating func connect(at now: Date) -> (connection: Int, bytes: [UInt8]) {
        connection += 1
        reader = V1FrameReader()
        lastArrival = now
        live = true
        let first = request(.hello(protocol: V1Protocol.version, client: name))
        let second = request(.events(since: journal == nil ? nil : lastSeq, journal: journal, ping: pingInterval))
        return (connection, first.bytes + second.bytes)
    }

    /// A request on the current connection, with the id its answer will carry.
    public mutating func request(_ request: V1Request) -> (id: Int, bytes: [UInt8]) {
        let id = nextId
        nextId += 1
        let json = (try? V1Codec.encode(V1ClientMessage(id: id, request))) ?? []
        return (id, V1Frame.encode(json))
    }

    /// The transport saw `connection` end.
    public mutating func disconnected(_ connection: Int) {
        if connection == self.connection { live = false }
    }

    /// Bytes from `connection`.
    public mutating func receive(_ bytes: [UInt8], on connection: Int, at now: Date) -> [Event] {
        guard connection == self.connection, live, !bytes.isEmpty else { return [] }
        let silence = now.timeIntervalSince(lastArrival)
        if silence > staleAfter {
            // Held back by a suspension: old before it is read.
            return retire(at: now, silence: silence, reason: "a message after \(Int(silence)) s of silence")
        }
        lastArrival = now
        reader.push(bytes)
        var events: [Event] = []
        while live {
            let frame: [UInt8]?
            do {
                frame = try reader.next()
            } catch {
                return events + retire(at: now, silence: nil, reason: "the stream is out of step")
            }
            guard let frame else { break }
            switch V1Codec.readReply(frame) {
            case .known(let message):
                events += apply(message)
            case .newer(.kind):
                break                                   // a newer source's: passed over
            case .newer(.event(let seq)):
                events += count(seq)
            case .newer(.refusal(let re, let text)):
                events.append(.refused(re: re, V1Failure(.unavailable, text)))
            case .unreadable:
                return events + retire(at: now, silence: nil, reason: "a message this app cannot read")
            }
        }
        return events
    }

    /// The clock moved: the state may have become old.
    public mutating func tick(at now: Date) -> [Event] {
        guard live else { return [] }
        let silence = now.timeIntervalSince(lastArrival)
        guard silence > staleAfter else { return [] }
        return retire(at: now, silence: silence, reason: "no message for \(Int(silence)) s")
    }

    // MARK: - Messages

    private mutating func apply(_ message: V1ServerMessage) -> [Event] {
        switch message.reply {
        case .hello(let hello):
            if hello.minClient > V1Protocol.version {
                live = false
                return [.incompatible("the source needs protocol \(hello.minClient); this app speaks \(V1Protocol.version)")]
            }
            self.hello = hello
            return [.hello(hello)]
        case .events(let ack):
            journal = ack.journal
            isStale = false
            return []
        case .state(let state):
            journal = state.journal
            lastSeq = state.seq
            rows = state.rows ?? []
            rowsKnown = state.rows != nil
            isStale = false
            return [.changed]
        case .event(let event):
            let held = lastSeq ?? 0
            if event.seq <= held { return [] }                 // already held: a replay overlapping
            if event.seq > held + 1 { return count(event.seq) }
            lastSeq = event.seq
            switch event.change {
            case .row(let row):
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row) }
            case .gone(let id):
                rows.removeAll { $0.id == id }
            }
            rowsKnown = true
            return [.changed]
        case .ping(let ping):
            if ping.seq > (lastSeq ?? 0) {
                return retire(at: nil, silence: nil, reason: "the source is at \(ping.seq), this app at \(lastSeq ?? 0)")
            }
            return []
        case .transcript(let transcript):
            return [.transcript(transcript)]
        case .result(let result):
            if let accepted = result.push { return [.pushAccepted(re: message.re, accepted)] }
            return [.done(re: message.re)]
        case .devices:
            return [.done(re: message.re)]
        case .error(let failure):
            if failure.code == .clientTooOld {
                live = false
                return [.incompatible(failure.message)]
            }
            return [.refused(re: message.re, failure)]
        case .bye(let reason):
            live = false
            return [.bye(reason)]
        }
    }

    /// An event's number, for one whose change is not applied: one already
    /// held is nothing, the next is held, one past it is a hole.
    private mutating func count(_ seq: Int) -> [Event] {
        let held = lastSeq ?? 0
        if seq <= held { return [] }
        if seq > held + 1 {
            return retire(at: nil, silence: nil, reason: "events \(held + 1)–\(seq - 1) never arrived")
        }
        lastSeq = seq
        return []
    }

    /// Leaves the current connection: whatever still arrives on it is dropped.
    /// With a silence, the state is also declared old.
    private mutating func retire(at now: Date?, silence: TimeInterval?, reason: String) -> [Event] {
        live = false
        var events: [Event] = []
        if let silence {
            isStale = true
            events.append(.stale(silence: silence))
        }
        events.append(.reconnect(reason: reason))
        return events
    }
}
