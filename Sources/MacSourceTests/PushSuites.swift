#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
import TestKit

/// The Mac as the relay's client (W5, §2.6, §2.9): only the rows it owns ring,
/// only when the person is away, its registrations kept 0600, and its last word
/// before sleep. The gate «Nessuna doppia notifica» on the Mac's side.
enum MacPushesSuite {

    final class FakeRelay: RelayTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [RelayPushRequest] = []
        var pushes: [RelayPushRequest] { lock.lock(); defer { lock.unlock() }; return all }

        func exchange(method: String, url: URL, body: Data?) async throws -> RelayHTTPResponse { record(url, body) }

        private func record(_ url: URL, _ body: Data?) -> RelayHTTPResponse {
            lock.lock()
            defer { lock.unlock() }
            if url.path == "/v1/push", let body, let request = try? V1Codec.decoder().decode(RelayPushRequest.self, from: body) {
                all.append(request)
            }
            return RelayHTTPResponse(status: 200, body: Data(#"{"outcome":"ok","status":"ok"}"#.utf8))
        }

        func alerts() -> [RelayPushRequest] { pushes.filter { $0.kind == .alert } }
    }

    static let t0 = MacFixtures.t0
    static let phoneKey = Curve25519.KeyAgreement.PrivateKey()
    static let node = "example-node"

    static func registration(liveActivity: Bool = false) -> V1PushRegistration {
        V1PushRegistration(capability: "Y2FwYWJpbGl0eQ==", token: String(repeating: "ab", count: 32), environment: .sandbox,
                           envelopeKey: phoneKey.publicKey.rawRepresentation.base64EncodedString(),
                           liveActivityToken: liveActivity ? String(repeating: "cd", count: 40) : nil,
                           liveActivityCapability: liveActivity ? "bGl2ZQ==" : nil, preferences: nil)
    }

    static func pushes(_ relay: FakeRelay, directory: String? = nil) -> MacPushes {
        MacPushes(identity: MacFixtures.mac, directory: directory ?? MacFixtures.temporaryDirectory("push"),
                  relay: RelayClient(base: URL(string: "https://relay.example.com")!, transport: relay))
    }

    /// One row of the Mac (`n`) and one of a node (`n + 1`), in `status`, the
    /// node's owned by its `lampd` when `lampd` is healthy.
    static func rows(_ status: SessionStatus, since: Date, lampd: Bool) -> [V1Row] {
        let mine = MacFixtures.snapshot(1, status: status.rawValue, at: since)
        let theirs = MacFixtures.snapshot(2, status: status.rawValue, host: node, at: since)
        return MacRows.rows([mine, theirs], mac: MacFixtures.mac, nodesWithLampd: lampd ? [node] : [])
    }

    /// Working at t0, amber from t0+5, looked at again at t0+10: one spell.
    static func amberSpell(_ pushes: MacPushes, lampd: Bool) {
        pushes.after(rows: rows(.working, since: t0, lampd: lampd), at: t0)
        pushes.after(rows: rows(.awaiting, since: t0 + 5, lampd: lampd), at: t0 + 5)
        pushes.after(rows: rows(.awaiting, since: t0 + 5, lampd: lampd), at: t0 + 10)
        _ = pushes.drain()
    }

    static let suite = TestSuite("The Mac's notifications: owned rows only, away only, the last word before sleep", [

        TestCase("Away, the Mac's amber row rings once; the node's row, owned by its lampd, never") { t in
            let relay = FakeRelay()
            let pushes = pushes(relay)
            _ = pushes.register(registration(), device: "phone-1", at: t0)
            pushes.presence = .away
            amberSpell(pushes, lampd: true)
            t.expectEqual(relay.alerts().count, 1, "one alert: the Mac's own row")
        },

        TestCase("Gate «Nessuna doppia notifica» bites: with the owner rule gone the node's row rings from the Mac too") { t in
            // The same spell with the node's lampd not healthy: the Mac owns both rows.
            let relay = FakeRelay()
            let pushes = pushes(relay)
            _ = pushes.register(registration(), device: "phone-1", at: t0)
            pushes.presence = .away
            amberSpell(pushes, lampd: false)
            t.expectEqual(relay.alerts().count, 2, "without a healthy lampd the Mac notifies the node's row as well")
        },

        TestCase("At the Mac nothing rings on the phone (Q8); leaving with the row still waiting rings then") { t in
            let relay = FakeRelay()
            let pushes = pushes(relay)
            _ = pushes.register(registration(), device: "phone-1", at: t0)
            pushes.presence = .here
            amberSpell(pushes, lampd: true)
            t.expectEqual(relay.alerts().count, 0, "the panel shows it and rings itself")
            pushes.presence = .away
            pushes.after(rows: rows(.awaiting, since: t0 + 5, lampd: true), at: t0 + 80)
            _ = pushes.drain()
            t.expectEqual(relay.alerts().count, 1, "still waiting when the person left: it rings now")
        },

        TestCase("The counts the Mac sends are its own rows' only: a node's lampd counts its own") { t in
            let relay = FakeRelay()
            let pushes = pushes(relay)
            _ = pushes.register(registration(liveActivity: true), device: "phone-1", at: t0)
            pushes.presence = .away
            amberSpell(pushes, lampd: true)
            let live = relay.pushes.filter { $0.kind == .liveactivity }
            t.expect(!live.isEmpty, "the Live Activity is fed")
            t.expect(relay.pushes.allSatisfy { !$0.envelope.contains("example-node") }, "nothing readable of the node")
        },

        TestCase("Before sleep: one alert when something waits, and the Live Activity grey at once") { t in
            let relay = FakeRelay()
            let pushes = pushes(relay)
            _ = pushes.register(registration(liveActivity: true), device: "phone-1", at: t0)
            t.expect(pushes.sleeping(rows: rows(.awaiting, since: t0, lampd: true), at: t0 + 60), "the relay answered in time")
            t.expectEqual(relay.alerts().count, 1, "the last word")
            t.expectEqual(pushes.presence, .asleep)
            let grey = relay.pushes.filter { $0.kind == .liveactivity }
            t.expectEqual(grey.count, 1, "one Live Activity push")
            t.expectEqual(grey.first?.staleDate.map { Int($0.timeIntervalSince1970) }, Int((t0 + 60).timeIntervalSince1970),
                          "stale now: grey on the Lock Screen")
        },

        TestCase("Before sleep with nothing waiting: silent, the Live Activity still grey") { t in
            let relay = FakeRelay()
            let pushes = pushes(relay)
            _ = pushes.register(registration(liveActivity: true), device: "phone-1", at: t0)
            pushes.sleeping(rows: rows(.working, since: t0, lampd: true), at: t0 + 60)
            t.expectEqual(relay.alerts().count, 0, "a sleep with nothing to say says nothing")
            t.expectEqual(relay.pushes.filter { $0.kind == .liveactivity }.count, 1, "grey all the same")
        },

        TestCase("Registrations are kept 0600 across launches, the envelope key once; Forget drops one") { t in
            let directory = MacFixtures.temporaryDirectory("push-keep")
            let relay = FakeRelay()
            let first = pushes(relay, directory: directory)
            guard case .success(let accepted) = first.register(registration(), device: "phone-1", at: t0) else {
                return t.fail("the registration was refused")
            }
            let mode = (try? FileManager.default.attributesOfItem(atPath: first.devicesFile))?[.posixPermissions] as? Int
            t.expectEqual(mode, 0o600, "tokens and capabilities are the person's")
            let again = pushes(relay, directory: directory)
            t.expectEqual(again.registeredDevices, ["phone-1"], "kept")
            guard case .success(let second) = again.register(registration(), device: "phone-1", at: t0) else {
                return t.fail("refused the second time")
            }
            t.expectEqual(second.envelopeKey, accepted.envelopeKey, "the same half of the key")
            again.forget(device: "phone-1")
            t.expectEqual(pushes(relay, directory: directory).registeredDevices, [], "forgotten for good")
        },
    ])
}
