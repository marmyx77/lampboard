import CryptoKit
import Foundation
import LampBoardCore

/// Where the Hub's commands to a session's mod wait, signed (D152).
///
/// The Hub calls `send`: the command is signed with the panel's key, queued for
/// that session, and the session is woken through its message box so the mod
/// collects it at once (`GET /mod/inbox`) instead of at its next round. The wake
/// carries nothing but its line: a message box is readable by the user's other
/// processes, and a command is not.
final class HubCommandDesk: @unchecked Sendable {

    /// The line the panel wakes a mod with; the mod consumes it and collects.
    static let wakeLine = CommandEnvelope.wakeLine

    private let key: Curve25519.Signing.PrivateKey
    private let lock = NSLock()
    private var queue = ModInboxQueue()
    private let wake: (String) -> Void

    init(key: Curve25519.Signing.PrivateKey, wake: @escaping (String) -> Void = HubCommandDesk.wakeLocally) {
        self.key = key
        self.wake = wake
    }

    /// Signs, queues and wakes. `false` when the command could not be signed.
    @discardableResult
    func send(session: String, op: String, args: [String: String] = [:], now: Date = Date()) -> Bool {
        guard ModReport.isSessionId(session),
              let envelope = try? CommandEnvelope.seal(sid: session, op: op, args: args, now: now, sign: { try self.key.signature(for: $0) })
        else { return false }
        lock.lock()
        queue.put(envelope, for: session, at: now)
        lock.unlock()
        wake(session)
        return true
    }

    /// `GET /mod/inbox`: what waits for the session, as JSON, taken out.
    func collect(session: String, now: Date = Date()) -> Data {
        lock.lock()
        let taken = queue.take(for: session, at: now)
        lock.unlock()
        return (try? JSONEncoder().encode(taken)) ?? Data("[]".utf8)
    }

    /// `GET /mod/hello`: the panel's public key and its signature of the mod's
    /// nonce, so the mod sends a stream's text only to the panel that holds the key.
    func hello(nonce: String) -> Data? {
        guard Self.isNonce(nonce),
              let signature = try? key.signature(for: Data(Self.helloText(nonce).utf8))
        else { return nil }
        let body: [String: String] = [
            "pub": CommandEnvelope.hex(key.publicKey.rawRepresentation),
            "sig": CommandEnvelope.hex(signature),
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func helloText(_ nonce: String) -> String { "lampboard-hello:" + nonce }

    static func isNonce(_ text: String) -> Bool {
        (16...128).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A local session's box: the wake goes off the main actor, and a session
    /// without a box is collected at the mod's next round instead.
    static func wakeLocally(_ session: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PeerSender().send(content: wakeLine, to: session)
        }
    }
}
