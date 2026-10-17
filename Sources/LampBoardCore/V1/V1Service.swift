import Foundation

/// The source's side of one `v1` connection: bytes in, bytes out.
///
/// It knows nothing of the transport. `lampd v1-stdio` feeds it what sshd
/// passes on stdin; the Mac's ssh server what arrives on a channel; the tests
/// and the demo mode a buffer. Each of them calls `receive` with what came in,
/// `poll` on a timer and whenever its source changed, `close` when it stops,
/// and writes what they return — cut with `V1Frame.pieces`.
///
/// The rules it keeps, whatever the source:
/// - `hello` first, and a client older than `minClient` is told so and closed;
/// - an event stream starts with no gap: what the client holds, then the
///   journal after it, or a whole state when the journal cannot say;
/// - a ping every interval, carrying the last number sent;
/// - only the low-power actions, validated here and not in each source (R4);
/// - the devices only for the action key.
public struct V1Service {

    public let peer: V1Peer
    public private(set) var isClosed = false

    private let source: V1Source
    private var reader = V1FrameReader()
    private var greeted = false
    private var stream: Stream?

    private struct Stream {
        var journal: String
        var cursor: Int
        let interval: TimeInterval
        var lastPingAt: Date
    }

    public init(source: V1Source, peer: V1Peer) {
        self.source = source
        self.peer = peer
    }

    /// What came in from the client; returns what to write back.
    public mutating func receive(_ bytes: [UInt8], at now: Date) -> [UInt8] {
        guard !isClosed else { return [] }
        reader.push(bytes)
        var out: [V1ServerMessage] = []
        while !isClosed {
            let frame: [UInt8]?
            do {
                frame = try reader.next()
            } catch {
                // Out of step: nothing after this can be read, so say why and stop.
                out.append(V1ServerMessage(re: nil, .error(V1Failure(.badFrame, "the stream is out of step (\(error))"))))
                isClosed = true
                break
            }
            guard let frame else { break }
            out += answer(frame, at: now)
        }
        return Self.write(out)
    }

    /// New events since the last call, and a ping when one is due.
    public mutating func poll(at now: Date) -> [UInt8] {
        guard !isClosed, var current = stream else { return [] }
        var out = catchUp(&current, at: now)
        if now.timeIntervalSince(current.lastPingAt) >= current.interval {
            out.append(V1ServerMessage(re: nil, .ping(V1Ping(seq: current.cursor, at: now))))
            current.lastPingAt = now
        }
        stream = current
        return Self.write(out)
    }

    /// The goodbye of an orderly stop (E10: without it a client still attached
    /// held every restart of the service for 90 seconds).
    public mutating func close(reason: String) -> [UInt8] {
        guard !isClosed else { return [] }
        isClosed = true
        return Self.write([V1ServerMessage(re: nil, .bye(reason: reason))])
    }

    // MARK: - Requests

    private mutating func answer(_ frame: [UInt8], at now: Date) -> [V1ServerMessage] {
        let message: V1ClientMessage
        switch V1Codec.decodeRequest(frame) {
        case .failure(let failure):
            return [V1ServerMessage(re: failure.id, .error(failure.failure))]
        case .success(let decoded):
            message = decoded
        }
        let re = message.id
        func refuse(_ code: V1Failure.Code, _ text: String) -> [V1ServerMessage] {
            [V1ServerMessage(re: re, .error(V1Failure(code, text)))]
        }

        if case .hello(let version, _) = message.request {
            guard version >= V1Protocol.minClient else {
                isClosed = true
                return refuse(.clientTooOld, "this source answers protocol \(V1Protocol.minClient) and later; update the app")
            }
            greeted = true
            return [V1ServerMessage(re: re, .hello(hello(at: now)))]
        }
        guard greeted else { return refuse(.helloFirst, "send hello first") }

        switch message.request {
        case .hello:
            return []
        case .state:
            return [V1ServerMessage(re: re, .state(source.snapshot(at: now)))]
        case .events(let since, let journal, let ping):
            return startStream(re: re, since: since, journal: journal, ping: ping, at: now)
        case .transcript(let session, let limit):
            guard V1Validation.isSessionId(session) else { return refuse(.badRequest, "not a session id") }
            let count = min(max(limit ?? V1Protocol.defaultTranscriptLimit, 1), V1Protocol.maxTranscriptLimit)
            guard let transcript = source.transcript(session: session, limit: count) else {
                return refuse(.notFound, "no conversation for \(session)")
            }
            // Bounded here, not trusted to each source: the newest `count`, and
            // the rest counted as not sent.
            let kept = Array(transcript.messages.suffix(count))
            let bounded = V1Transcript(
                session: transcript.session, messages: kept,
                notSent: max(0, transcript.notSent) + transcript.messages.count - kept.count
            )
            return [V1ServerMessage(re: re, .transcript(bounded))]
        case .command(let command):
            if let problem = command.problem { return refuse(.badRequest, problem) }
            if let failure = source.perform(command, by: peer, at: now) { return [V1ServerMessage(re: re, .error(failure))] }
            return [V1ServerMessage(re: re, .result(V1Result(op: "cmd")))]
        case .pushRegister(let registration):
            if let problem = registration.problem { return refuse(.badRequest, problem) }
            if let failure = source.register(registration, by: peer, at: now) { return [V1ServerMessage(re: re, .error(failure))] }
            return [V1ServerMessage(re: re, .result(V1Result(op: "push.register")))]
        case .devices(let request):
            guard peer.role == .action else { return refuse(.forbidden, "the devices need the action key") }
            if let problem = request.problem { return refuse(.badRequest, problem) }
            switch source.devices(request, by: peer, at: now) {
            case .success(let devices): return [V1ServerMessage(re: re, .devices(devices))]
            case .failure(let failure): return [V1ServerMessage(re: re, .error(failure))]
            }
        }
    }

    private func hello(at now: Date) -> V1Hello {
        let status = source.status(at: now)
        return V1Hello(
            version: status.version, source: source.identity, startedAt: status.startedAt,
            binaryModifiedAt: status.binaryModifiedAt, configModifiedAt: status.configModifiedAt,
            stateAge: V1StateAge(seq: status.seq, lastEventAt: status.lastEventAt, lastProbeAt: status.lastProbeAt, at: now),
            relay: status.relay, role: peer.role, mode: status.mode
        )
    }

    // MARK: - The event stream

    /// The acknowledgement, then either the journal after what the client holds
    /// or a whole state — chosen here, in one step, so nothing falls between.
    private mutating func startStream(re: Int?, since: Int?, journal: String?, ping: TimeInterval?, at now: Date) -> [V1ServerMessage] {
        let status = source.status(at: now)
        let interval = V1Protocol.pingInterval(asked: ping)
        if let since, journal == status.journal, since >= 0, since <= status.seq,
           case .events(let replay) = source.events(after: since) {
            let events = replay.filter { $0.seq > since }
            stream = Stream(journal: status.journal, cursor: events.last?.seq ?? since, interval: interval, lastPingAt: now)
            let ack = V1EventsAck(journal: status.journal, since: since, replayed: events.count, resync: false, ping: interval)
            return [V1ServerMessage(re: re, .events(ack))] + events.map { V1ServerMessage(re: nil, .event($0)) }
        }
        let state = source.snapshot(at: now)
        stream = Stream(journal: state.journal, cursor: state.seq, interval: interval, lastPingAt: now)
        let ack = V1EventsAck(journal: state.journal, since: since, replayed: 0, resync: true, ping: interval)
        return [V1ServerMessage(re: re, .events(ack)), V1ServerMessage(re: nil, .state(state))]
    }

    /// What the journal holds past the cursor. A journal that started again, or
    /// was trimmed past the cursor, is answered with a whole state.
    private func catchUp(_ current: inout Stream, at now: Date) -> [V1ServerMessage] {
        if source.status(at: now).journal == current.journal, case .events(let events) = source.events(after: current.cursor) {
            let fresh = events.filter { $0.seq > current.cursor }
            current.cursor = fresh.last?.seq ?? current.cursor
            return fresh.map { V1ServerMessage(re: nil, .event($0)) }
        }
        let state = source.snapshot(at: now)
        current.journal = state.journal
        current.cursor = state.seq
        return [V1ServerMessage(re: nil, .state(state))]
    }

    // MARK: - Writing

    /// The frames of `messages`, in order. A message that cannot be written — a
    /// cost that is not a number has no JSON — becomes a refusal saying so,
    /// rather than a silence the client would read as nothing to say.
    static func write(_ messages: [V1ServerMessage]) -> [UInt8] {
        messages.flatMap { message -> [UInt8] in
            if let json = try? V1Codec.encode(message) { return V1Frame.encode(json) }
            let failure = V1ServerMessage(re: message.re, .error(V1Failure(.unavailable, "could not write a \(message.reply.type)")))
            return (try? V1Codec.encode(failure)).map(V1Frame.encode) ?? []
        }
    }
}
