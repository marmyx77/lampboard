#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LampBoardCore
import Foundation
import TestKit

/// The relay's routes from the side of a source and of the phone (§2.8): what
/// is sent, and what each answer becomes in `hello` (`V1RelayHealth`).
enum RelayClientSuite {

    /// Answers each request with what the test says, and keeps what was sent.
    final class FakeRelay: RelayTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [RelayHTTPResponse?]
        private(set) var sent: [(method: String, path: String, body: [String: Any]?)] = []

        init(_ answers: [RelayHTTPResponse?]) { self.answers = answers }

        func exchange(method: String, url: URL, body: Data?) async throws -> RelayHTTPResponse {
            guard let next = take(method: method, path: url.path, body: body) else { throw URLErrorStandIn() }
            return next
        }

        private func take(method: String, path: String, body: Data?) -> RelayHTTPResponse? {
            lock.lock()
            defer { lock.unlock() }
            sent.append((method, path, body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }))
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        struct URLErrorStandIn: Error {}
    }

    static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> RelayHTTPResponse {
        RelayHTTPResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static let token = String(repeating: "ab", count: 32)
    static let capability = RelayCapability(cap: "Y2Fw", token: token, environment: .sandbox)
    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    static func sealed() -> (String, PushContent)? {
        let mine = Curve25519.KeyAgreement.PrivateKey(), theirs = Curve25519.KeyAgreement.PrivateKey()
        let content = PushContent(source: "example-node", journal: "j", seq: 1, at: t0, title: "counts", body: "1 0 0 2",
                                  session: nil, event: .counts, counts: PushCounts(waiting: 1, failed: 0, ready: 0, working: 2))
        guard let key = try? PushEnvelope.key(mine: mine, theirs: theirs.publicKey, source: "example-node", device: "phone-1"),
              let sealed = try? PushEnvelope.seal(content, with: key) else { return nil }
        return (sealed, content)
    }

    static func push(_ answers: [RelayHTTPResponse?]) -> (RelayOutcome, FakeRelay)? {
        guard let (sealed, content) = sealed(),
              let request = try? RelayPushRequest.make(capability: capability, kind: .alert, urgent: true, sealed: sealed, content: content)
        else { return nil }
        let fake = FakeRelay(answers)
        let client = RelayClient(base: URL(string: "https://relay.example.com")!, transport: fake)
        guard let outcome = try? Blocking.run(10, { await client.push(request) }) else { return nil }
        return (outcome, fake)
    }

    static let suite = TestSuite("Relay client: requests and outcomes", [

        TestCase("Each answer of the relay is one outcome a source can show") { t in
            t.expectEqual(push([json(200, ["outcome": "ok"])])?.0, .ok, "200")
            t.expectEqual(push([json(410, ["outcome": "refused", "reason": "Unregistered"])])?.0, .gone("Unregistered"), "410 drops the token")
            t.expectEqual(push([json(429, ["outcome": "quota"], headers: ["Retry-After": "1800"])])?.0, .quota(retryAfter: 1800), "429 with Retry-After")
            t.expectEqual(push([json(403, ["outcome": "refused", "reason": "capability does not belong to this token"])])?.0,
                          .refused("capability does not belong to this token"), "403")
            t.expectEqual(push([json(503, ["outcome": "unreachable"])])?.0, .unreachable("status 503"), "503")
            t.expectEqual(push([nil])?.0, .unreachable("the relay could not be reached"), "nothing came back")
        },

        TestCase("The health a source puts in hello says the outcome, the wait and the reason") { t in
            let quota = RelayOutcome.quota(retryAfter: 600).health(at: t0)
            t.expectEqual(quota, V1RelayHealth(outcome: "quota", at: t0, retryAfter: 600), "quota")
            t.expectEqual(quota.holdUntil, t0.addingTimeInterval(600), "held until")
            t.expectEqual(RelayOutcome.gone("Unregistered").health(at: t0).outcome, "refused", "a gone token is a refusal")
            t.expectNil(RelayOutcome.ok.health(at: t0).holdUntil, "ok holds nothing back")
        },

        TestCase("A push goes to /v1/push as the relay's vectors say, and nothing else") { t in
            guard let (_, fake) = push([json(200, ["outcome": "ok"])]), let sent = fake.sent.first else { t.expect(false, "nothing sent"); return }
            t.expectEqual(sent.method, "POST", "POST")
            t.expectEqual(sent.path, "/v1/push", "the route")
            t.expectEqual(Set(sent.body?.keys.map { $0 } ?? []), ["cap", "token", "environment", "kind", "priority", "envelope"],
                          "no Live Activity fields on an alert")
        },

        TestCase("A Live Activity push always carries a stale date; an alert never one") { t in
            guard let (sealed, content) = sealed() else { t.expect(false, "no envelope"); return }
            let live = try? RelayPushRequest.make(capability: capability, kind: .liveactivity, urgent: false, sealed: sealed,
                                                  content: content, now: t0)
            t.expectEqual(live?.staleDate, t0.addingTimeInterval(15 * 60), "fifteen minutes when none is named")
            t.expectEqual(live?.event, .update, "an update by default")
            let ended = try? RelayPushRequest.make(capability: capability, kind: .liveactivity, urgent: false, sealed: sealed,
                                                   content: content, staleDate: t0, event: .end, dismissalDate: t0, now: t0)
            t.expectEqual(ended?.dismissalDate, t0, "an end may say when it leaves")
            t.expectThrows(RelayPushRequest.Refusal.notALiveActivity, "an alert with a stale date") {
                _ = try RelayPushRequest.make(capability: capability, kind: .alert, urgent: false, sealed: sealed,
                                              content: content, staleDate: t0)
            }
            let wire = live.flatMap { try? V1Codec.encoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            t.expect(wire.contains("\"staleDate\":\"2025-10-09T09:08:20Z\""), "ISO 8601, as the relay reads it: \(wire)")
        },

        TestCase("The phone's routes: challenge, capability, the Live Activity's capability") { t in
            let fake = FakeRelay([
                json(202, ["outcome": "ok"]),
                json(200, ["cap": "ZGV2aWNl", "token": token, "environment": "sandbox", "version": 1]),
                json(200, ["cap": "bGl2ZQ==", "token": String(repeating: "cd", count: 40), "environment": "sandbox", "version": 1]),
                json(403, ["outcome": "refused", "reason": "the nonce is not the one sent to this token, or it is too old"]),
            ])
            let client = RelayClient(base: URL(string: "https://relay.example.com")!, transport: fake)
            let challenged = try? Blocking.run(10) { await client.challenge(token: token, environment: .sandbox) }
            t.expectEqual(challenged, .ok, "202")
            let earned = try? Blocking.run(10) {
                await client.capability(token: token, environment: .sandbox, challenge: RelayChallenge(nonce: "n1", issuedAt: 1_760_000_000))
            }
            guard case .success(let device)? = earned else { t.expect(false, "no capability: \(String(describing: earned))"); return }
            t.expectEqual(device.cap, "ZGV2aWNl", "the device's")
            let live = try? Blocking.run(10) { await client.liveActivityCapability(device: device, liveActivityToken: String(repeating: "cd", count: 40)) }
            guard case .success(let activity)? = live else { t.expect(false, "no Live Activity capability"); return }
            t.expectEqual(activity.cap, "bGl2ZQ==", "the activity's")
            let refused = try? Blocking.run(10) {
                await client.capability(token: token, environment: .sandbox, challenge: RelayChallenge(nonce: "wrong", issuedAt: 1))
            }
            if case .failure(let failure)? = refused { t.expectEqual(failure.outcome, .refused("the nonce is not the one sent to this token, or it is too old"), "403") }
            else { t.expect(false, "a wrong nonce earned a capability") }
            t.expectEqual(fake.sent.map(\.path), ["/v1/challenge", "/v1/capability", "/v1/capability/liveactivity", "/v1/capability"], "the routes")
            t.expectEqual(fake.sent[1].body?["issuedAt"] as? Int, 1_760_000_000, "the nonce's time given back untouched")
        },

        TestCase("The challenge is read from the silent push, and nothing else is") { t in
            t.expectEqual(RelayChallenge(userInfo: ["lb": ["challenge": ["nonce": "abc", "issuedAt": 1_760_000_000]]]),
                          RelayChallenge(nonce: "abc", issuedAt: 1_760_000_000), "lb.challenge")
            t.expectNil(RelayChallenge(userInfo: ["lb": ["e": "envelope"]]), "an envelope is not a challenge")
            t.expectNil(RelayChallenge(userInfo: ["lb": ["challenge": ["nonce": "", "issuedAt": 1]]]), "an empty nonce")
        },

        TestCase("A reason the relay gives is kept as one bounded printable line") { t in
            let outcome = RelayClient.outcome(of: json(400, ["reason": "bad\nline\u{0007}" + String(repeating: "x", count: 300)]))
            guard case .refused(let reason) = outcome else { t.expect(false, "not refused"); return }
            t.expect(reason.count <= 120 && !reason.contains("\n"), "bounded, one line: \(reason.count)")
        },

        TestCase("push.register: the source answers with its half of the envelope key and the names it is bound to") { t in
            let source = V1MemorySource(identity: V1SourceIdentity(kind: .node, name: "example-node"), startedAt: t0, journal: "j")
            let phone = Curve25519.KeyAgreement.PrivateKey()
            let registration = V1PushRegistration(capability: "Y2Fw", token: token, environment: .sandbox,
                                                  envelopeKey: phone.publicKey.rawRepresentation.base64EncodedString(),
                                                  preferences: V1PushPreferences(finished: true))
            var service = V1Fixtures.greeted(source)
            let replies = V1Fixtures.replies(service.receive(V1Fixtures.frame(.pushRegister(registration), id: 7), at: t0))
            guard case .result(let result)? = replies.first?.reply, let accepted = result.push else {
                t.expect(false, "no acceptance: \(replies)"); return
            }
            t.expectEqual(accepted.source, "example-node", "the source's name")
            t.expectEqual(accepted.device, "phone-1", "the device's, which the phone was never told")
            guard let theirs = Data(base64Encoded: accepted.envelopeKey).flatMap({ try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }),
                  let phoneKey = try? PushEnvelope.key(mine: phone, theirs: theirs, source: accepted.source, device: accepted.device),
                  let sourceKey = try? PushEnvelope.key(mine: source.pushKey, theirs: phone.publicKey, source: "example-node", device: "phone-1")
            else { t.expect(false, "no key"); return }
            let content = PushContent(source: "example-node", journal: "j", seq: 1, at: t0, title: "t", body: "b", session: nil)
            let opened = (try? PushEnvelope.seal(content, with: sourceKey)).flatMap { PushEnvelope.open($0, with: phoneKey) }
            t.expectEqual(opened, content, "the phone opens what the source seals")
            t.expectEqual(source.registrations["phone-1"]?.preferences?.finished, true, "the preferences kept")
        },

        TestCase("A registration with half a Live Activity, or a bad muted project, is refused") { t in
            let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            let half = V1PushRegistration(capability: "Y2Fw", token: token, environment: .sandbox, envelopeKey: key,
                                          liveActivityToken: String(repeating: "cd", count: 40))
            t.expectNotNil(half.problem, "a token without its capability")
            let bad = V1PushRegistration(capability: "Y2Fw", token: token, environment: .sandbox, envelopeKey: key,
                                         preferences: V1PushPreferences(mutedProjects: ["a\u{0000}b"]))
            t.expectNotNil(bad.problem, "a control character")
            t.expectNotNil(V1Command(action: .focus, session: "../x").problem, "focus names a session id or none")
            t.expectNil(V1Command(action: .focus).problem, "focus alone")
        },
    ])
}
