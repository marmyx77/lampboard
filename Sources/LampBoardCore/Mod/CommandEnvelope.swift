import CryptoKit
import Foundation

/// A command the panel sends to one session's companion mod (D152): a message
/// to submit, a turn to stop, a slash command to run, a model or effort for that
/// session alone, a stream to follow.
///
/// Signed with the panel's Ed25519 key, whose private half stays in the
/// Keychain. The permission key of D80 is a file any process of the user's can
/// read, and a session whose prompt was injected could read it too and "type" in
/// every other session; a public key on disk lets the mod check a command and
/// gives nobody the power to make one. The mod verifies before it reads a field:
/// the signature covers the payload's exact bytes, which travel as a string.
public struct CommandEnvelope: Codable, Equatable, Sendable {

    /// The payload as canonical JSON (sorted keys): the bytes the signature covers.
    public let payload: String
    /// The Ed25519 signature of `payload`'s UTF-8 bytes, lowercase hex.
    public let sig: String

    public init(payload: String, sig: String) {
        self.payload = payload
        self.sig = sig
    }

    /// What a command says once its signature holds.
    public struct Payload: Codable, Equatable, Sendable {
        public let v: Int
        /// The one session it is for: a command copied to another is refused there.
        public let sid: String
        /// Random, once: a command replayed within the window is refused.
        public let nonce: String
        /// When the panel made it, in milliseconds since 1970.
        public let ts: Int64
        public let op: String
        public let args: [String: String]
    }

    /// The line the panel wakes a mod with through its session's message box;
    /// the mod consumes it, unread by the session, and collects.
    public static let wakeLine = "LampBoard wake [v2]"

    /// The payload's version, which the mod checks before anything else.
    public static let version = 2
    /// How far a command's time may be from the receiver's clock, either way.
    public static let window: Int64 = 60_000
    /// The commands there are. Anything else is refused, signed or not.
    public static let ops: Set<String> = ["submit", "abort", "command", "model", "effort", "stream"]

    public enum Refusal: Error, Equatable, Sendable {
        case malformed, badSignature, otherSession, stale, replayed, unknownOp
    }

    /// A new command for `sid`, signed by `sign` (the panel's key).
    public static func seal(
        sid: String, op: String, args: [String: String] = [:],
        nonce: String = CommandEnvelope.newNonce(), now: Date = Date(),
        sign: (Data) throws -> Data
    ) throws -> CommandEnvelope {
        let payload = Payload(v: version, sid: sid, nonce: nonce, ts: millis(now), op: op, args: args)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        guard let text = String(data: bytes, encoding: .utf8) else { throw Refusal.malformed }
        return CommandEnvelope(payload: text, sig: hex(try sign(Data(text.utf8))))
    }

    /// The command, if `publicKey` signed it for `session` within the window
    /// and it was not `seen` before: what the mod checks, written here too so
    /// both sides hold to one rule and the tests can say it.
    public static func open(
        _ envelope: CommandEnvelope, publicKey: Curve25519.Signing.PublicKey,
        session: String, now: Date = Date(), seen: Set<String> = []
    ) -> Result<Payload, Refusal> {
        guard let signature = bytes(fromHex: envelope.sig), signature.count == 64 else { return .failure(.malformed) }
        guard publicKey.isValidSignature(signature, for: Data(envelope.payload.utf8)) else { return .failure(.badSignature) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(envelope.payload.utf8)),
              payload.v == version, !payload.nonce.isEmpty
        else { return .failure(.malformed) }
        guard payload.sid == session else { return .failure(.otherSession) }
        guard abs(payload.ts - millis(now)) <= window else { return .failure(.stale) }
        guard !seen.contains(payload.nonce) else { return .failure(.replayed) }
        guard ops.contains(payload.op) else { return .failure(.unknownOp) }
        return .success(payload)
    }

    /// Sixteen random bytes, hex.
    public static func newNonce() -> String {
        hex(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func bytes(fromHex text: String) -> Data? {
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// The commands waiting for each session's mod to collect them (`GET /mod/inbox`).
///
/// A command older than the window is dropped, since the mod would refuse it;
/// a session collects only its own; fifty at most wait per session, the oldest
/// making room, so a mod that never comes cannot grow the panel.
public struct ModInboxQueue: Sendable {

    public static let limit = 50

    private var waiting: [String: [(envelope: CommandEnvelope, at: Date)]] = [:]

    public init() {}

    public mutating func put(_ envelope: CommandEnvelope, for session: String, at now: Date = Date()) {
        var list = fresh(for: session, at: now)
        list.append((envelope, now))
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        waiting[session] = list
    }

    /// What waits for `session`, oldest first, taken out of the queue.
    public mutating func take(for session: String, at now: Date = Date()) -> [CommandEnvelope] {
        let list = fresh(for: session, at: now)
        waiting[session] = nil
        return list.map(\.envelope)
    }

    public func count(for session: String) -> Int { waiting[session]?.count ?? 0 }

    private func fresh(for session: String, at now: Date) -> [(envelope: CommandEnvelope, at: Date)] {
        let horizon = now.addingTimeInterval(-Double(CommandEnvelope.window) / 1000)
        return (waiting[session] ?? []).filter { $0.at >= horizon }
    }
}
