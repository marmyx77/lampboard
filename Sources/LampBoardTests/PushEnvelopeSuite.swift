#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LampBoardCore
import Foundation
import TestKit

/// The envelope a notification travels in through the relay, and what the
/// phone does with one that is late, repeated or not its own (§2.8).
enum PushEnvelopeSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private static let phone = Curve25519.KeyAgreement.PrivateKey()
    private static let mac = Curve25519.KeyAgreement.PrivateKey()

    private static func content(seq: Int = 1, at: Date = t0) -> PushContent {
        PushContent(source: "Example Mac", seq: seq, at: at, title: "project-alpha",
                    body: "A session is asking to run a command", session: "00000000-0000-4000-8000-000000000001")
    }

    private static func keys() -> (mac: SymmetricKey, phone: SymmetricKey)? {
        guard let a = try? PushEnvelope.key(mine: mac, theirs: phone.publicKey, source: "mac-1", device: "phone-1"),
              let b = try? PushEnvelope.key(mine: phone, theirs: mac.publicKey, source: "mac-1", device: "phone-1")
        else { return nil }
        return (a, b)
    }

    private static let capability = RelayCapability(cap: "Y2Fw", token: String(repeating: "ab", count: 32), environment: .sandbox)

    static let suite = TestSuite("Push envelopes", [

        TestCase("The source seals, the phone opens: the same key on both sides") { t in
            guard let pair = keys(), case let (sending, receiving) = (pair.mac, pair.phone),
                  let sealed = try? PushEnvelope.seal(content(), with: sending) else { t.expect(false, "no key"); return }
            t.expectEqual(PushEnvelope.open(sealed, with: receiving), content(), "what was sealed")
        },

        TestCase("An envelope for another pair does not open") { t in
            guard let sending = keys()?.mac,
                  let sealed = try? PushEnvelope.seal(content(), with: sending),
                  let other = try? PushEnvelope.key(mine: phone, theirs: mac.publicKey, source: "mac-2", device: "phone-1")
            else { t.expect(false, "no key"); return }
            t.expectNil(PushEnvelope.open(sealed, with: other), "the key is bound to the source and the device")
        },

        TestCase("A damaged or forged envelope does not open") { t in
            guard let pair = keys(), case let (sending, receiving) = (pair.mac, pair.phone),
                  let sealed = try? PushEnvelope.seal(content(), with: sending),
                  var bytes = Data(base64Encoded: sealed) else { t.expect(false, "no envelope"); return }
            bytes[bytes.count / 2] ^= 0x01
            t.expectNil(PushEnvelope.open(bytes.base64EncodedString(), with: receiving), "one bit")
            t.expectNil(PushEnvelope.open("not base64", with: receiving), "garbage")
        },

        TestCase("The phone shows an envelope once, and never a late one") { t in
            var guardian = PushReplayGuard(maxAge: 600)
            t.expectEqual(guardian.admit(content(seq: 4), at: t0), .fresh, "the first")
            t.expectEqual(guardian.admit(content(seq: 4), at: t0), .replayed, "the same again")
            t.expectEqual(guardian.admit(content(seq: 3), at: t0), .replayed, "an older one")
            t.expectEqual(guardian.admit(content(seq: 5, at: t0.addingTimeInterval(-601)), at: t0), .stale, "eleven minutes late")
            t.expectEqual(guardian.admit(content(seq: 6, at: t0.addingTimeInterval(120)), at: t0), .stale, "from the future")
            t.expectEqual(guardian.admit(content(seq: 5), at: t0), .fresh, "the late one's number is still free")
        },

        TestCase("The relay gets the envelope and nothing a person wrote") { t in
            guard let sending = keys()?.mac,
                  let sealed = try? PushEnvelope.seal(content(), with: sending),
                  let request = try? RelayPushRequest.make(capability: capability, kind: .alert, urgent: true, sealed: sealed, content: content()),
                  let wire = try? V1Codec.encoder().encode(request) else { t.expect(false, "no request"); return }
            let text = String(decoding: wire, as: UTF8.self)
            t.expect(!text.contains("project-alpha") && !text.contains("asking"), "no title or body in the request")
            t.expectEqual(request.priority, 10, "a permission rings now")
        },

        TestCase("A push that was never sealed is refused before it leaves") { t in
            // The relay must not be able to read: an envelope carrying the text in
            // clear is a seal that did not happen, and the source does not send it.
            let unsealed = ((try? V1Codec.encoder().encode(content())) ?? Data()).base64EncodedString()
            t.expectThrows(RelayPushRequest.Refusal.readable) {
                _ = try RelayPushRequest.make(capability: capability, kind: .alert, urgent: false, sealed: unsealed, content: content())
            }
        },

        TestCase("A push the relay would refuse is refused here") { t in
            let huge = Data(repeating: 9, count: 4000).base64EncodedString()
            t.expectThrows(RelayPushRequest.Refusal.tooLarge) {
                _ = try RelayPushRequest.make(capability: capability, kind: .alert, urgent: false, sealed: huge, content: content())
            }
            guard let sending = keys()?.mac, let sealed = try? PushEnvelope.seal(content(), with: sending) else { return }
            t.expectThrows(RelayPushRequest.Refusal.badPriority) {
                _ = try RelayPushRequest.make(capability: capability, kind: .background, urgent: true, sealed: sealed, content: content())
            }
        },
    ])
}
