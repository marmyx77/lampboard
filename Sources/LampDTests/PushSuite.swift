#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import LampBoardCore
import LampDKit
import TestKit

/// `lampd` as the relay's client (W4): registrations kept on disk, alerts on
/// transitions from the files, sealed for the device, the relay's answers in
/// `hello`, a gone token dropped, a quota respected.
enum PushSuite {

    /// The relay as the test wants it to answer; keeps what it was sent.
    final class FakeRelay: RelayTransport, @unchecked Sendable {
        private let lock = NSLock()
        var answer: RelayHTTPResponse
        private(set) var pushes: [RelayPushRequest] = []
        private(set) var healthChecks = 0

        init(_ answer: RelayHTTPResponse = RelayHTTPResponse(status: 200, body: Data(#"{"outcome":"ok","status":"ok"}"#.utf8))) {
            self.answer = answer
        }

        /// How many of the next pushes find no relay (the transport throws).
        var unanswered = 0
        private(set) var attempts = 0

        struct NoAnswer: Error {}

        func exchange(method: String, url: URL, body: Data?) async throws -> RelayHTTPResponse {
            if url.path == "/v1/push", takeUnanswered() { throw NoAnswer() }
            return record(url, body)
        }

        private func takeUnanswered() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            guard unanswered > 0 else { return false }
            unanswered -= 1
            return true
        }

        private func record(_ url: URL, _ body: Data?) -> RelayHTTPResponse {
            lock.lock()
            defer { lock.unlock() }
            if url.path == "/health" { healthChecks += 1 }
            if url.path == "/v1/push", let body, let request = try? V1Codec.decoder().decode(RelayPushRequest.self, from: body) {
                pushes.append(request)
            }
            return answer
        }

        func alerts() -> [RelayPushRequest] {
            lock.lock()
            defer { lock.unlock() }
            return pushes.filter { $0.kind == .alert }
        }
    }

    static let token = String(repeating: "ab", count: 32)
    static let phoneKey = Curve25519.KeyAgreement.PrivateKey()

    static func registration(finished: Bool = false) -> V1PushRegistration {
        V1PushRegistration(capability: "Y2FwYWJpbGl0eQ==", token: token, environment: .sandbox,
                           envelopeKey: phoneKey.publicKey.rawRepresentation.base64EncodedString(),
                           preferences: V1PushPreferences(finished: finished))
    }

    static func live(_ paths: LampDPaths, _ relay: FakeRelay) -> NodeSource {
        NodeSource(identity: F.node, mode: .live, paths: paths, version: "test", startedAt: F.t0,
                   relay: RelayClient(base: URL(string: "http://127.0.0.1:9")!, transport: relay))
    }

    static let device = V1Peer(device: "test-phone", role: .read)

    /// Looks: busy at 0, amber from 10 on.
    static func amberLooks(_ source: NodeSource) {
        source.absorb(F.look([F.record(F.a, pid: 10, status: "busy")], at: F.t0))
        for seconds in [10.0, 15, 20] {
            source.absorb(F.look([F.record(F.a, pid: 10, status: "waiting")], at: F.t0 + seconds))
        }
        _ = source.pushes.drain()
    }

    static let suite = TestSuite("lampd: notifications through the relay", [

        TestCase("A registration taken by a forced command is kept 0600 and sent to by the service only") { t in
            let paths = F.home("push-files")
            defer { F.remove(paths) }
            let relay = FakeRelay()
            let reading = NodeSource(identity: F.node, mode: .files, paths: paths, version: "test", startedAt: F.t0,
                                     relay: RelayClient(base: URL(string: "http://127.0.0.1:9")!, transport: relay))
            guard case .success(let accepted) = reading.register(registration(), by: device, at: F.t0) else {
                t.expect(false, "refused"); return
            }
            t.expectEqual(accepted.device, "test-phone", "the device by the name its key was added with")
            t.expectEqual(accepted.source, "example-node", "the machine by its name")
            var info = stat()
            t.expect(stat(paths.pushDevicesFile, &info) == 0 && info.st_mode & 0o777 == 0o600, "the registrations are 0600")
            t.expect(stat(paths.pushKeyFile, &info) == 0 && info.st_mode & 0o777 == 0o600, "the key is 0600")
            amberLooks(reading)
            t.expectEqual(relay.alerts().count, 0, "a forced command never sends")
            let service = live(paths, relay)
            for seconds in [22.0, 25] { service.absorb(F.look([F.record(F.a, pid: 10, status: "waiting")], at: F.t0 + seconds)) }
            _ = service.pushes.drain()
            t.expectEqual(relay.alerts().count, 0, "amber already at the service's first look is not news")
            service.absorb(F.look([F.record(F.a, pid: 10, status: "busy")], at: F.t0 + 30))
            for seconds in [40.0, 45, 50] {
                service.absorb(F.look([F.record(F.a, pid: 10, status: "waiting")], at: F.t0 + seconds))
            }
            _ = service.pushes.drain()
            t.expectEqual(relay.alerts().count, 1, "a new amber spell: one alert, from the service")
        },

        TestCase("The alert is sealed for the device: the relay sees no word of it, the phone opens it") { t in
            let paths = F.home("push-seal")
            defer { F.remove(paths) }
            let relay = FakeRelay()
            let service = live(paths, relay)
            guard case .success(let accepted) = service.register(registration(), by: device, at: F.t0) else { t.expect(false, "refused"); return }
            amberLooks(service)
            guard let alert = relay.alerts().first else { t.expect(false, "no alert: \(relay.pushes.map(\.kind))"); return }
            t.expectEqual(alert.priority, 10, "a question is urgent")
            let wire = (try? V1Codec.encoder().encode(alert)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            t.expect(!wire.contains("project") && !wire.contains(F.a), "no project and no session id on the wire")
            guard let theirs = Data(base64Encoded: accepted.envelopeKey).flatMap({ try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }),
                  let key = try? PushEnvelope.key(mine: phoneKey, theirs: theirs, source: accepted.source, device: accepted.device),
                  let content = PushEnvelope.open(alert.envelope, with: key)
            else { t.expect(false, "the phone cannot open it"); return }
            t.expectEqual(content.event, .waiting, "waiting")
            t.expectEqual(content.session, F.a, "the row, for the tap")
            t.expectEqual(content.counts?.waiting, 1, "the counts for the badge")
            t.expectEqual(relay.pushes.filter { $0.kind == .background }.count, 1, "and the counts for the widget, once")
        },

        TestCase("A push the relay did not answer is tried once more, and only once") { t in
            let paths = F.home("push-retry")
            defer { F.remove(paths) }
            let relay = FakeRelay()
            relay.unanswered = 1
            let service = live(paths, relay)
            _ = service.register(registration(), by: device, at: F.t0)
            amberLooks(service)
            t.expectEqual(relay.alerts().count, 1, "the alert arrived on the second try")
            t.expectEqual(service.pushes.sent.first { $0.kind == .alert }?.outcome, .ok, "and its outcome is the second try's")

            let paths2 = F.home("push-retry-twice")
            defer { F.remove(paths2) }
            let silent = FakeRelay()
            silent.unanswered = 100
            let again = live(paths2, silent)
            _ = again.register(registration(), by: device, at: F.t0)
            amberLooks(again)
            let pushes = again.pushes.sent.count
            t.expectEqual(silent.attempts, pushes * 2, "two tries for each push, never a third")
            guard case .unreachable? = again.pushes.sent.first(where: { $0.kind == .alert })?.outcome else {
                t.expect(false, "a relay that never answers stays unreachable"); return
            }
        },

        TestCase("A gone token is dropped; a quota holds the next alerts back and hello says until when") { t in
            let paths = F.home("push-gone")
            defer { F.remove(paths) }
            let relay = FakeRelay(RelayHTTPResponse(status: 429, headers: ["Retry-After": "900"], body: Data(#"{"outcome":"quota"}"#.utf8)))
            let service = live(paths, relay)
            _ = service.register(registration(), by: device, at: F.t0)
            amberLooks(service)
            let health = service.status(at: F.t0 + 20).relay
            t.expectEqual(health?.outcome, "quota", "hello says quota")
            t.expectEqual(health?.retryAfter, 900, "and how long")
            let before = relay.pushes.count
            service.absorb(F.look([F.record(F.a, pid: 10, status: "busy")], at: F.t0 + 30))
            for seconds in [40.0, 45] { service.absorb(F.look([F.record(F.a, pid: 10, status: "waiting")], at: F.t0 + seconds)) }
            _ = service.pushes.drain()
            t.expectEqual(relay.pushes.count, before, "nothing sent while the relay asked to wait")
            relay.answer = RelayHTTPResponse(status: 410, body: Data(#"{"outcome":"refused","reason":"Unregistered"}"#.utf8))
            let later = live(paths, relay)
            later.absorb(F.look([F.record(F.b, pid: 11, status: "busy")], at: F.t0 + 2000))
            for seconds in [2010.0, 2015, 2020] { later.absorb(F.look([F.record(F.b, pid: 11, status: "waiting")], at: F.t0 + seconds)) }
            _ = later.pushes.drain()
            t.expectEqual(later.pushes.registeredDevices, [], "410: the token is dropped")
            let file = FileManager.default.contents(atPath: paths.pushDevicesFile).map { String(decoding: $0, as: UTF8.self) } ?? ""
            t.expect(!file.contains(token), "and gone from the file")
        },

        TestCase("The Live Activity follows the wait for the person at once, the work at most once a minute") { t in
            let paths = F.home("push-live")
            defer { F.remove(paths) }
            let relay = FakeRelay()
            let service = live(paths, relay)
            let r = registration()
            let withActivity = V1PushRegistration(capability: r.capability, token: r.token, environment: r.environment,
                                                  envelopeKey: r.envelopeKey, liveActivityToken: String(repeating: "cd", count: 40),
                                                  liveActivityCapability: "bGl2ZQ==", preferences: r.preferences)
            _ = service.register(withActivity, by: device, at: F.t0)
            // Work that comes and goes every five seconds, for a minute and a half.
            for step in 0..<18 {
                service.absorb(F.look([F.record(F.a, pid: 10, status: step % 2 == 0 ? "busy" : "idle")], at: F.t0 + Double(step) * 5))
            }
            _ = service.pushes.drain()
            let quiet = relay.pushes.filter { $0.kind == .liveactivity }.count
            t.expect(quiet <= 3, "work alone: at most once a minute, not every look (\(quiet) in 90 s)")
            service.absorb(F.look([F.record(F.a, pid: 10, status: "waiting")], at: F.t0 + 91))
            _ = service.pushes.drain()
            t.expectEqual(relay.pushes.filter { $0.kind == .liveactivity }.count, quiet + 1, "a session waiting for you: at once")
            t.expect(relay.pushes.filter { $0.kind == .liveactivity }.allSatisfy { $0.staleDate != nil }, "every one with a stale date")
        },

        TestCase("The envelope key is made once, whichever process makes it") { t in
            let paths = F.home("push-key")
            defer { F.remove(paths) }
            let a = F.source(paths, mode: .files), b = live(paths, FakeRelay())
            guard case .success(let one) = a.register(registration(), by: device, at: F.t0),
                  case .success(let two) = b.register(registration(), by: device, at: F.t0)
            else { t.expect(false, "refused"); return }
            t.expectEqual(one.envelopeKey, two.envelopeKey, "one key for the machine")
        },

        TestCase("With nothing sent, hello still says how the relay is (/health)") { t in
            let paths = F.home("push-health")
            defer { F.remove(paths) }
            let relay = FakeRelay()
            let service = live(paths, relay)
            service.absorb(F.look([F.record(F.a, pid: 10, status: "idle")], at: F.t0))
            _ = service.pushes.drain()
            t.expectEqual(relay.healthChecks, 1, "asked once")
            t.expectEqual(service.status(at: F.t0).relay?.outcome, "ok", "and said in hello")
        },

        TestCase("While you were away is said once, to the device that was away") { t in
            let paths = F.home("push-away")
            defer { F.remove(paths) }
            let service = live(paths, FakeRelay())
            _ = service.register(registration(), by: device, at: F.t0)
            service.absorb(F.look([F.record(F.a, pid: 10, status: "busy")], at: F.t0))
            service.absorb(F.look([F.record(F.a, pid: 10, status: "idle", tail: F.ended)], at: F.t0 + 600))
            let line = service.away(for: device, at: F.t0 + 900)
            t.expect(line?.hasPrefix("While you were away (15m): 1 turn finished") == true, "the line: \(line ?? "nil")")
            t.expectNil(service.away(for: device, at: F.t0 + 901), "once")
        },

        TestCase("The machine is named once, and every other setting stays as it was") { t in
            let paths = F.home("name")
            defer { F.remove(paths) }
            t.expectEqual(LampDConfig.load(paths.configFile).config.name, "Linux", "no name: never the host name")
            try? LampDPaths.makeDirectory(paths.configDirectory)
            try? AtomicFile.write(Data(#"{"probeInterval": 7, "notifications": false}"#.utf8), to: paths.configFile)
            t.expectEqual(try? LampDConfig.setName("  Bestia ", at: paths.configFile), "Bestia", "trimmed")
            let config = LampDConfig.load(paths.configFile).config
            t.expectEqual(config.name, "Bestia", "named")
            t.expectEqual(config.identity.name, "Bestia", "and so it says in hello")
            t.expectEqual(config.probeInterval, 7, "the rest kept")
            t.expectEqual(config.notifications, false, "the rest kept")
            t.expectThrows(LampDError.invalid("a name is 1 to 40 characters, with no control characters"), "a bad name") {
                _ = try LampDConfig.setName(String(repeating: "x", count: 41), at: paths.configFile)
            }
            t.expectEqual(LampDConfig.load(paths.configFile).config.name, "Bestia", "and a bad name changes nothing")
        },

        TestCase("The relay's address: https, or http only to a private network") { t in
            t.expectNotNil(LampDConfig.validRelay("https://push.lampboard.site"), "the public one")
            t.expectNotNil(LampDConfig.validRelay("http://172.17.0.1:18080"), "a check's own, on a private network")
            t.expectNotNil(LampDConfig.validRelay("http://100." + "101.102.103:18080"), "or on the tailnet")
            t.expectNil(LampDConfig.validRelay("http://100.20.0.1:18080"), "but not the rest of 100/8")
            t.expectNil(LampDConfig.validRelay("http://push.example.com"), "never http to the Internet")
            t.expectNil(LampDConfig.validRelay("https://push.example.com/v1/push?x=1"), "never a path or a query")
            t.expectNil(LampDConfig.validRelay("file:///etc/passwd"), "never a file")
        },
    ])
}
