import Foundation

/// A request as it travels: the request and the id its answer will repeat.
public struct V1ClientMessage: Equatable, Sendable {
    public let id: Int?
    public let request: V1Request

    public init(id: Int?, _ request: V1Request) {
        self.id = id
        self.request = request
    }
}

/// A reply as it travels: the reply and, for an answer, the request's id.
public struct V1ServerMessage: Equatable, Sendable {
    public let re: Int?
    public let reply: V1Reply

    public init(re: Int?, _ reply: V1Reply) {
        self.re = re
        self.reply = reply
    }
}

/// Why a request could not be read, with the id when it could be found: the
/// refusal goes back to the request that caused it.
public struct V1DecodeFailure: Error, Equatable, Sendable {
    public let id: Int?
    public let failure: V1Failure
}

/// The JSON of every `v1` message, both ways.
///
/// Dates as ISO 8601, like the read endpoint (`SessionsCodec`); keys sorted, so
/// two captures of the same message compare as text.
public enum V1Codec {

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Client to source

    public static func encode(_ message: V1ClientMessage) throws -> [UInt8] {
        Array(try encoder().encode(ClientWire(message)))
    }

    /// The request in `json`, or why it cannot be one.
    public static func decodeRequest(_ json: [UInt8]) -> Result<V1ClientMessage, V1DecodeFailure> {
        let data = Data(json)
        guard let head = try? decoder().decode(Head.self, from: data), let op = head.op else {
            return .failure(V1DecodeFailure(id: nil, failure: V1Failure(.malformed, "not a JSON object with an op")))
        }
        guard V1Request.ops.contains(op) else {
            return .failure(V1DecodeFailure(id: head.id, failure: V1Failure(.unknownOp, "unknown op \(op)")))
        }
        do {
            return .success(try decoder().decode(ClientWire.self, from: data).message)
        } catch {
            return .failure(V1DecodeFailure(id: head.id, failure: V1Failure(.badRequest, "\(op): \(describe(error))")))
        }
    }

    // MARK: - Source to client

    public static func encode(_ message: V1ServerMessage) throws -> [UInt8] {
        Array(try encoder().encode(ServerWire(message)))
    }

    public static func decodeReply(_ json: [UInt8]) throws -> V1ServerMessage {
        try decoder().decode(ServerWire.self, from: Data(json)).message
    }

    /// A reply as a client of this build reads it: one it knows, one a newer
    /// source added, or bytes that are not a reply at all.
    ///
    /// A source one version ahead may send a kind of reply, an event or a
    /// refusal code this build has never heard of. Treating that as bytes out of
    /// step would drop the connection, get the same reply on the next one, and
    /// drop it again for as long as the app is not updated. So what is newer is
    /// named and passed over; only what cannot be a reply ends the connection.
    public static func readReply(_ json: [UInt8]) -> V1ReplyReading {
        if let message = try? decodeReply(json) { return .known(message) }
        let data = Data(json)
        guard let head = try? decoder().decode(TypeHead.self, from: data) else { return .unreadable }
        switch head.type {
        case let type where !V1Reply.types.contains(type):
            return .newer(.kind(type))
        case "event":
            guard let event = try? decoder().decode(EventHead.self, from: data),
                  !V1Event.kinds.contains(event.kind) else { return .unreadable }
            return .newer(.event(seq: event.seq))
        case "error":
            guard let error = try? decoder().decode(ErrorHead.self, from: data),
                  V1Failure.Code(rawValue: error.code) == nil else { return .unreadable }
            return .newer(.refusal(re: error.re, message: error.message))
        default:
            return .unreadable
        }
    }

    private struct TypeHead: Decodable { let type: String }
    private struct EventHead: Decodable { let seq: Int; let kind: String }
    private struct ErrorHead: Decodable { let re: Int?; let code: String; let message: String }

    /// One line of a decoding error, without the coding path's noise.
    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "bad \(path)"
        default: return "\(error)"
        }
    }

    private struct Head: Decodable {
        let op: String?
        let id: Int?
    }
}

/// What `V1Codec.readReply` found.
public enum V1ReplyReading: Equatable, Sendable {
    case known(V1ServerMessage)
    /// Something a newer source says, which this build passes over.
    case newer(V1Newer)
    /// Not a reply: the stream is out of step.
    case unreadable
}

public enum V1Newer: Equatable, Sendable {
    /// A kind of reply this build does not know.
    case kind(String)
    /// An event of a kind this build does not know: its number still counts.
    case event(seq: Int)
    /// A refusal with a code this build does not know: still a refusal.
    case refusal(re: Int?, message: String)
}

/// The request's fields next to `op` and `id`, in one object.
private struct ClientWire: Codable {
    let message: V1ClientMessage

    init(_ message: V1ClientMessage) { self.message = message }

    private enum Keys: String, CodingKey {
        case op, id, `protocol`, client, since, journal, ping, session, limit
        case action, name, on, ids, capability, token, environment, envelopeKey, liveActivityToken, device
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decodeIfPresent(Int.self, forKey: .id)
        let request: V1Request
        switch try c.decode(String.self, forKey: .op) {
        case "hello":
            request = .hello(protocol: try c.decode(Int.self, forKey: .protocol),
                             client: try c.decode(String.self, forKey: .client))
        case "state":
            request = .state
        case "events":
            request = .events(since: try c.decodeIfPresent(Int.self, forKey: .since),
                              journal: try c.decodeIfPresent(String.self, forKey: .journal),
                              ping: try c.decodeIfPresent(Double.self, forKey: .ping))
        case "transcript":
            request = .transcript(session: try c.decode(String.self, forKey: .session),
                                  limit: try c.decodeIfPresent(Int.self, forKey: .limit))
        case "cmd":
            request = .command(try V1Command(from: decoder))
        case "push.register":
            request = .pushRegister(try V1PushRegistration(from: decoder))
        case "devices":
            request = .devices(try V1DevicesRequest(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(other)")
        }
        message = V1ClientMessage(id: id, request)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(message.request.op, forKey: .op)
        try c.encodeIfPresent(message.id, forKey: .id)
        switch message.request {
        case .hello(let version, let client):
            try c.encode(version, forKey: .protocol)
            try c.encode(client, forKey: .client)
        case .state:
            break
        case .events(let since, let journal, let ping):
            try c.encodeIfPresent(since, forKey: .since)
            try c.encodeIfPresent(journal, forKey: .journal)
            try c.encodeIfPresent(ping, forKey: .ping)
        case .transcript(let session, let limit):
            try c.encode(session, forKey: .session)
            try c.encodeIfPresent(limit, forKey: .limit)
        case .command(let command):
            try command.encode(to: encoder)
        case .pushRegister(let registration):
            try registration.encode(to: encoder)
        case .devices(let request):
            try request.encode(to: encoder)
        }
    }
}

/// The reply's fields next to `type` and `re`, in one object.
private struct ServerWire: Codable {
    let message: V1ServerMessage

    init(_ message: V1ServerMessage) { self.message = message }

    private enum Keys: String, CodingKey { case type, re, devices, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let re = try c.decodeIfPresent(Int.self, forKey: .re)
        let reply: V1Reply
        switch try c.decode(String.self, forKey: .type) {
        case "hello": reply = .hello(try V1Hello(from: decoder))
        case "state": reply = .state(try V1State(from: decoder))
        case "events": reply = .events(try V1EventsAck(from: decoder))
        case "event": reply = .event(try V1Event(from: decoder))
        case "ping": reply = .ping(try V1Ping(from: decoder))
        case "transcript": reply = .transcript(try V1Transcript(from: decoder))
        case "result": reply = .result(try V1Result(from: decoder))
        case "devices": reply = .devices(try c.decode([V1Device].self, forKey: .devices))
        case "error": reply = .error(try V1Failure(from: decoder))
        case "bye": reply = .bye(reason: try c.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
        message = V1ServerMessage(re: re, reply)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(message.reply.type, forKey: .type)
        try c.encodeIfPresent(message.re, forKey: .re)
        switch message.reply {
        case .hello(let hello): try hello.encode(to: encoder)
        case .state(let state): try state.encode(to: encoder)
        case .events(let ack): try ack.encode(to: encoder)
        case .event(let event): try event.encode(to: encoder)
        case .ping(let ping): try ping.encode(to: encoder)
        case .transcript(let transcript): try transcript.encode(to: encoder)
        case .result(let result): try result.encode(to: encoder)
        case .devices(let devices): try c.encode(devices, forKey: .devices)
        case .error(let failure): try failure.encode(to: encoder)
        case .bye(let reason): try c.encode(reason, forKey: .reason)
        }
    }
}
