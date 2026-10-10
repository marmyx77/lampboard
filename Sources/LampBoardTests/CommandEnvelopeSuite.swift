import CryptoKit
import Foundation
import LampBoardCore
import TestKit

/// The commands the panel signs for a session's mod (D152): only the panel's
/// key makes one, only the session named takes it, only once, only now.
enum CommandEnvelopeSuite {

    private static let session = "8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f"
    private static let other = "1f2e3d4c-5b6a-4987-8a7b-6c5d4e3f2a1b"
    private static let start = Date(timeIntervalSince1970: 1_791_000_000)

    private static func sealed(
        _ key: Curve25519.Signing.PrivateKey, sid: String = session, op: String = "submit",
        args: [String: String] = ["text": "hello", "asUser": "true"], nonce: String = "n1", at: Date = start
    ) -> CommandEnvelope? {
        try? CommandEnvelope.seal(sid: sid, op: op, args: args, nonce: nonce, now: at) { try key.signature(for: $0) }
    }

    static let suite = TestSuite("Commands signed for a session's mod", [

        TestCase("A command the panel signed opens for its session, with its fields") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key) else { return t.fail("not sealed") }
            let opened = CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start)
            guard case .success(let payload) = opened else { return t.fail("refused: \(opened)") }
            t.expectEqual(payload.op, "submit")
            t.expectEqual(payload.args["text"], "hello")
            t.expectEqual(payload.v, CommandEnvelope.version)
        },

        TestCase("The payload is canonical JSON, so the mod verifies the bytes the panel signed") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key, args: ["z": "1", "a": "2"]) else { return t.fail("not sealed") }
            t.expect(envelope.payload.hasPrefix("{\"args\":{\"a\":\"2\",\"z\":\"1\"}"), envelope.payload)
            t.expectEqual(envelope.sig.count, 128)
        },

        TestCase("A command changed after signing is refused") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key) else { return t.fail("not sealed") }
            let changed = CommandEnvelope(payload: envelope.payload.replacingOccurrences(of: "hello", with: "rm -rf"), sig: envelope.sig)
            t.expectEqual(CommandEnvelope.open(changed, publicKey: key.publicKey, session: session, now: start), .failure(.badSignature))
        },

        TestCase("A command signed by any other key is refused: reading a file no longer makes one") { t in
            let panel = Curve25519.Signing.PrivateKey()
            let intruder = Curve25519.Signing.PrivateKey()
            guard let forged = sealed(intruder) else { return t.fail("not sealed") }
            t.expectEqual(CommandEnvelope.open(forged, publicKey: panel.publicKey, session: session, now: start), .failure(.badSignature))
        },

        TestCase("A command for one session is refused by another") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key, sid: other) else { return t.fail("not sealed") }
            t.expectEqual(CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start), .failure(.otherSession))
        },

        TestCase("A command older or newer than a minute is refused") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key) else { return t.fail("not sealed") }
            t.expectEqual(CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start.addingTimeInterval(61)), .failure(.stale))
            t.expectEqual(CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start.addingTimeInterval(-61)), .failure(.stale))
            guard case .success = CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start.addingTimeInterval(59)) else {
                return t.fail("refused inside the window")
            }
        },

        TestCase("A command already taken is refused the second time") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key, nonce: "once") else { return t.fail("not sealed") }
            t.expectEqual(CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start, seen: ["once"]), .failure(.replayed))
        },

        TestCase("A signed command the mod does not know is refused") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key, op: "shell") else { return t.fail("not sealed") }
            t.expectEqual(CommandEnvelope.open(envelope, publicKey: key.publicKey, session: session, now: start), .failure(.unknownOp))
        },

        TestCase("A signature that is not 64 bytes of hex is malformed, not checked") { t in
            let key = Curve25519.Signing.PrivateKey()
            guard let envelope = sealed(key) else { return t.fail("not sealed") }
            for sig in ["", "zz", String(envelope.sig.dropLast(2))] {
                t.expectEqual(CommandEnvelope.open(CommandEnvelope(payload: envelope.payload, sig: sig), publicKey: key.publicKey, session: session, now: start), .failure(.malformed), sig)
            }
        },

        TestCase("Each session collects only its own commands, once, oldest first") { t in
            var queue = ModInboxQueue()
            let a = CommandEnvelope(payload: "a", sig: "1"), b = CommandEnvelope(payload: "b", sig: "2"), c = CommandEnvelope(payload: "c", sig: "3")
            queue.put(a, for: session, at: start)
            queue.put(c, for: other, at: start)
            queue.put(b, for: session, at: start.addingTimeInterval(1))
            t.expectEqual(queue.take(for: session, at: start.addingTimeInterval(2)), [a, b])
            t.expectEqual(queue.take(for: session, at: start.addingTimeInterval(2)), [])
            t.expectEqual(queue.take(for: other, at: start.addingTimeInterval(2)), [c])
        },

        TestCase("A command nobody collected within the window is dropped") { t in
            var queue = ModInboxQueue()
            queue.put(CommandEnvelope(payload: "late", sig: "1"), for: session, at: start)
            t.expectEqual(queue.take(for: session, at: start.addingTimeInterval(61)), [])
        },

        TestCase("Fifty commands wait at most per session, the oldest making room") { t in
            var queue = ModInboxQueue()
            for i in 0..<60 { queue.put(CommandEnvelope(payload: "\(i)", sig: "\(i)"), for: session, at: start) }
            let taken = queue.take(for: session, at: start)
            t.expectEqual(taken.count, ModInboxQueue.limit)
            t.expectEqual(taken.first?.payload, "10")
        },
    ])
}
