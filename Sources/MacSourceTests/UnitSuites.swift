import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
import LampBoardNodeLink
import TestKit

/// What the phone may ask of the Mac, read and refused before anything runs.
enum MacRequestSuite {
    static let suite = TestSuite("The Mac's requests", [

        TestCase("Every request the phone makes reads back as itself") { t in
            let job = "a1b2c3d4"
            let requests: [MacRequest] = [
                .v1, .pair, .background, .palette,
                .attach(.tmux(session: "alpha")), .attach(.job(job)), .attach(.shell(root: "/work/app")),
                .action(.end(session: MacFixtures.sid(1), tmux: "alpha")),
                .action(.browse(path: "/work")), .action(.look),
                .action(.start(folder: "/work/app", name: "app", launch: NewSession.newLaunchTag(),
                               start: .new(sessionId: MacFixtures.sid(2)))),
                .action(.message(session: MacFixtures.sid(3), text: "hello")),
            ]
            for request in requests {
                guard let line = request.line else { t.fail("no line for \(request)"); continue }
                t.expectEqual(MacRequest.parse(line), request, line)
            }
        },

        TestCase("A command, a shell, a path or an unnamed action is not a request") { t in
            let refused = [
                "", "sh", "/bin/sh -c id", "v1 extra", "attach", "attach alpha", "action", "pair now",
                "attach " + Data(#"{"tmux":"alpha:0.1"}"#.utf8).base64EncodedString(),
                "attach " + Data(#"{"tmux":"alpha\nid"}"#.utf8).base64EncodedString(),
                "attach " + Data(#"{"tmux":"alpha","job":"a1"}"#.utf8).base64EncodedString(),
                "attach " + Data(#"{"shell":"relative/dir"}"#.utf8).base64EncodedString(),
                "action " + Data(#"{"name":"projects"}"#.utf8).base64EncodedString(),
                "action " + Data(#"{"name":"attachments","root":"/work/app"}"#.utf8).base64EncodedString(),
                "action " + Data(#"{"name":"rm -rf"}"#.utf8).base64EncodedString(),
                "action " + Data(#"{"name":"end"}"#.utf8).base64EncodedString(),
                "action not-base64!",
                String(repeating: "v", count: 20_000),
            ]
            for line in refused { t.expectNil(MacRequest.parse(line), "refused: \(line.prefix(60))") }
        },

        TestCase("Arguments a node would refuse are refused on the Mac too") { t in
            // A folder that is not absolute: NodeAction gives no command for it.
            let call = MacActionCall(.browse(path: "relative"))
            let line = "action " + (try! JSONEncoder().encode(call)).base64EncodedString()
            if let request = MacRequest.parse(line), case .action(let action) = request {
                t.expect((try? action.command().get()) == nil, "no command for a relative folder")
            } else {
                t.fail("the call should read, and its command be refused")
            }
        },

        TestCase("Random lines never read as a request (fuzz, 20 000 lines)") { t in
            var generator = SystemRandomNumberGenerator()
            var accepted: [String] = []
            for _ in 0..<20_000 {
                let length = Int.random(in: 0...64, using: &generator)
                let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
                let line = String(decoding: bytes, as: UTF8.self)
                if let request = MacRequest.parse(line), request != .v1, request != .pair,
                   request != .background, request != .palette { accepted.append(line) }
            }
            t.expectEqual(accepted, [], "nothing random is an attach or an action")
        },

        TestCase("The QR code's invitation round-trips, and a bad one is refused") { t in
            let invitation = MacPairingInvitation(name: "Example Mac", hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample",
                                                  addresses: ["example-mac.local", "192.0.2.10"], port: 52_000,
                                                  code: MacPairingCode.make())
            t.expectEqual(MacPairingInvitation(url: invitation.url), invitation, "round trip")
            t.expectNil(MacPairingInvitation(url: invitation.url.replacingOccurrences(of: "lampboard://", with: "https://")), "scheme")
            t.expectNil(MacPairingInvitation(url: invitation.url.replacingOccurrences(of: invitation.code, with: "123456")), "code shape")
            t.expect(MacPairingCode.isWellFormed(MacPairingCode.make()), "a made code is well formed")
        },

        TestCase("A pairing request needs a name and two different P-256 keys") { t in
            let read = ReadKey.generate().publicKey, action = ActionKey.generate().publicKey
            t.expectNil(MacPairingRequest(name: "Example iPhone", readKey: read, actionKey: action).problem, "good")
            t.expectNotNil(MacPairingRequest(name: "Example iPhone", readKey: read, actionKey: read).problem, "same key twice")
            t.expectNotNil(MacPairingRequest(name: "", readKey: read, actionKey: action).problem, "no name")
            t.expectNotNil(MacPairingRequest(name: "x", readKey: "ssh-ed25519 AAAA", actionKey: action).problem, "not P-256")
        },
    ])
}

/// Who may do what: the whole matrix, so a door opened by mistake is a red line.
enum MacPolicySuite {
    static let suite = TestSuite("Who may ask what of the Mac", [

        TestCase("The read key opens v1 and nothing else, switch or not") { t in
            let reader = MacPeer.device(id: "dev-1", role: .read)
            for on in [false, true] {
                t.expectEqual(MacPolicy.decide(.v1, from: reader, terminalsOn: on, hasTerminal: false), .allow, "v1")
                for request in [MacRequest.attach(.tmux(session: "a")), .action(.look), .background, .palette, .pair] {
                    t.expect(MacPolicy.decide(request, from: reader, terminalsOn: on, hasTerminal: true) != .allow, "\(request)")
                    t.expect(MacPolicy.decide(request, from: reader, terminalsOn: on, hasTerminal: false) != .allow, "\(request)")
                }
                t.expect(!MacPolicy.mayAskForTerminal(reader, terminalsOn: on), "no pty for the read key")
            }
        },

        TestCase("With the switch off the action key opens v1 only (Q17)") { t in
            let actor = MacPeer.device(id: "dev-1", role: .action)
            t.expectEqual(MacPolicy.decide(.v1, from: actor, terminalsOn: false, hasTerminal: false), .allow, "v1, for the devices")
            t.expectEqual(MacPolicy.decide(.attach(.tmux(session: "a")), from: actor, terminalsOn: false, hasTerminal: true),
                          .refuse(MacPolicy.offWords), "no terminal")
            t.expectEqual(MacPolicy.decide(.action(.look), from: actor, terminalsOn: false, hasTerminal: false),
                          .refuse(MacPolicy.offWords), "no action")
            t.expect(!MacPolicy.mayAskForTerminal(actor, terminalsOn: false), "no pty")
        },

        TestCase("With the switch on: a terminal after a pty-req, an action without one") { t in
            let actor = MacPeer.device(id: "dev-1", role: .action)
            t.expectEqual(MacPolicy.decide(.attach(.job("a1")), from: actor, terminalsOn: true, hasTerminal: true), .allow, "attach")
            t.expect(MacPolicy.decide(.attach(.job("a1")), from: actor, terminalsOn: true, hasTerminal: false) != .allow, "attach without pty")
            t.expectEqual(MacPolicy.decide(.action(.look), from: actor, terminalsOn: true, hasTerminal: false), .allow, "action")
            t.expect(MacPolicy.decide(.action(.look), from: actor, terminalsOn: true, hasTerminal: true) != .allow, "action with a pty")
            t.expect(MacPolicy.decide(.v1, from: actor, terminalsOn: true, hasTerminal: true) != .allow, "v1 on a terminal")
            t.expect(MacPolicy.decide(nil, from: actor, terminalsOn: true, hasTerminal: false) != .allow, "an unnamed request")
            t.expect(MacPolicy.mayAskForTerminal(actor, terminalsOn: true), "pty")
        },

        TestCase("The pairing account pairs and does nothing else") { t in
            t.expectEqual(MacPolicy.decide(.pair, from: .pairing, terminalsOn: true, hasTerminal: false), .allow, "pair")
            for request in [MacRequest.v1, .attach(.tmux(session: "a")), .action(.look), .background, .palette] {
                t.expect(MacPolicy.decide(request, from: .pairing, terminalsOn: true, hasTerminal: false) != .allow, "\(request)")
            }
            t.expect(MacPolicy.decide(.pair, from: .device(id: "d", role: .action), terminalsOn: true, hasTerminal: false) != .allow,
                     "a device does not pair again")
            t.expect(!MacPolicy.mayAskForTerminal(.pairing, terminalsOn: true), "no pty")
        },
    ])
}

enum MacPairingSuite {
    static let suite = TestSuite("The pairing window", [

        TestCase("One code, once, inside two minutes") { t in
            let window = MacPairingWindow()
            t.expectEqual(window.attempt("anything", at: MacFixtures.t0), .refused("no pairing window is open"), "closed by default")
            let (code, closes) = window.open(at: MacFixtures.t0)
            t.expectEqual(closes, MacFixtures.t0.addingTimeInterval(120), "two minutes")
            t.expectEqual(window.attempt(code, at: MacFixtures.t0.addingTimeInterval(119)), .accepted, "in time")
            t.expectEqual(window.attempt(code, at: MacFixtures.t0.addingTimeInterval(119)), .refused("this code was used already"), "once")
        },

        TestCase("Late, or after three wrong codes, the right code is refused") { t in
            let window = MacPairingWindow()
            let (code, _) = window.open(at: MacFixtures.t0)
            t.expectEqual(window.attempt(code, at: MacFixtures.t0.addingTimeInterval(120)), .refused("the window closed"), "late")
            let (again, _) = window.open(at: MacFixtures.t0)
            for _ in 0..<3 { _ = window.attempt("wrong", at: MacFixtures.t0) }
            t.expectEqual(window.attempt(again, at: MacFixtures.t0), .refused("the window closed after 3 wrong codes"), "three wrong")
            t.expect(!window.isOpen(at: MacFixtures.t0), "and it says so")
        },

        TestCase("Each refusal from one address waits longer; a success forgives it") { t in
            let throttle = MacAuthThrottle(base: 0.25, ceiling: 8)
            t.expectEqual(throttle.delay(for: "192.0.2.1", at: MacFixtures.t0), 0, "the first costs nothing")
            var delays: [TimeInterval] = []
            for _ in 0..<7 {
                throttle.failed("192.0.2.1", at: MacFixtures.t0)
                delays.append(throttle.delay(for: "192.0.2.1", at: MacFixtures.t0))
            }
            t.expectEqual(delays, [0.25, 0.5, 1, 2, 4, 8, 8], "doubling, up to the ceiling")
            t.expectEqual(throttle.delay(for: "192.0.2.2", at: MacFixtures.t0), 0, "another address is not punished")
            throttle.succeeded("192.0.2.1")
            t.expectEqual(throttle.delay(for: "192.0.2.1", at: MacFixtures.t0), 0, "forgiven")
        },
    ])
}

enum MacDevicesSuite {
    static let suite = TestSuite("The paired devices", [

        TestCase("A device pairs, its keys find their roles, and Forget takes them away") { t in
            let devices = MacDevices(directory: MacFixtures.temporaryDirectory("devices"))
            let read = ReadKey.generate(), action = ActionKey.generate()
            guard let device = try? devices.add(MacPairingRequest(name: "Example iPhone", readKey: read.publicKey,
                                                                  actionKey: action.publicKey), at: MacFixtures.t0) else {
                return t.fail("the device was not added")
            }
            t.expect(device.id.hasPrefix("dev-"), "an id of the Mac's")
            t.expectEqual(devices.role(ofOpenSSH: read.publicKey)?.role, .read, "the read key reads")
            t.expectEqual(devices.role(ofOpenSSH: action.publicKey)?.role, .action, "the action key acts")
            let mode = (try? FileManager.default.attributesOfItem(atPath: devices.path))?[.posixPermissions] as? Int
            t.expectEqual(mode, 0o600, "the file is the person's alone")
            t.expectEqual((try? devices.revoke(device.id)), true, "revoked")
            t.expectNil(devices.role(ofOpenSSH: read.publicKey), "and its key is a stranger again")
        },

        TestCase("A key paired once cannot pair a second device; Forget all leaves none") { t in
            let devices = MacDevices(directory: MacFixtures.temporaryDirectory("devices"))
            let read = ReadKey.generate().publicKey
            _ = try? devices.add(MacPairingRequest(name: "One", readKey: read, actionKey: ActionKey.generate().publicKey), at: MacFixtures.t0)
            t.expectNil(try? devices.add(MacPairingRequest(name: "Two", readKey: read, actionKey: ActionKey.generate().publicKey),
                                         at: MacFixtures.t0), "the same read key twice")
            try? devices.forgetAll()
            t.expect(devices.isEmpty, "none")
        },

        TestCase("The same device pairing again with both its keys keeps its id and its nodes; half a match is refused") { t in
            let devices = MacDevices(directory: MacFixtures.temporaryDirectory("devices"))
            let read = ReadKey.generate().publicKey, action = ActionKey.generate().publicKey
            guard let first = try? devices.add(MacPairingRequest(name: "Example iPhone", readKey: read, actionKey: action),
                                               at: MacFixtures.t0) else { return t.fail("the device was not added") }
            try? devices.setNodes(first.id, ["example-node": "lampd-1"])
            let again = try? devices.add(MacPairingRequest(name: "Example iPhone (2)", readKey: read, actionKey: action,
                                                           relayCapability: "cap"), at: MacFixtures.t0.addingTimeInterval(60))
            t.expectEqual(again?.id, first.id, "the phone forgot this Mac, not its keys: the same device")
            t.expectEqual(again?.name, "Example iPhone (2)", "under the name it gives now")
            t.expectEqual(again?.relayCapability, "cap", "with its capability of now")
            t.expectEqual(again?.nodes, ["example-node": "lampd-1"], "what Forget must revoke on the nodes is kept")
            t.expectEqual(devices.all.count, 1, "one device, never two rows for one phone")
            t.expectNil(try? devices.add(MacPairingRequest(name: "Half", readKey: read, actionKey: ActionKey.generate().publicKey),
                                         at: MacFixtures.t0), "one key of a device beside a new one")
        },

        TestCase("A device removed from the file by hand is refused at once") { t in
            let devices = MacDevices(directory: MacFixtures.temporaryDirectory("devices"))
            let read = ReadKey.generate()
            _ = try? devices.add(MacPairingRequest(name: "One", readKey: read.publicKey, actionKey: ActionKey.generate().publicKey),
                                 at: MacFixtures.t0)
            t.expectNotNil(devices.role(ofOpenSSH: read.publicKey), "known")
            Thread.sleep(forTimeInterval: 0.02)
            try? Data("[]".utf8).write(to: URL(fileURLWithPath: devices.path))
            t.expectNil(devices.role(ofOpenSSH: read.publicKey), "the file decides")
        },
    ])
}

enum MacSourceSuite {
    static let suite = TestSuite("The Mac's column as a v1 source", [

        TestCase("Rows that did not change on the wire make no event; a change makes one") { t in
            let source = MacFixtures.source()
            let rows = MacRows.rows([MacFixtures.snapshot(1), MacFixtures.snapshot(2)], mac: MacFixtures.mac)
            source.update(rows, at: MacFixtures.t0)
            t.expectEqual(source.status(at: MacFixtures.t0).seq, 2, "two rows, two events")
            source.update(rows, at: MacFixtures.t0.addingTimeInterval(5))
            t.expectEqual(source.status(at: MacFixtures.t0).seq, 2, "the same rows again: nothing")
            source.update(MacRows.rows([MacFixtures.snapshot(1, status: "ready")], mac: MacFixtures.mac), at: MacFixtures.t0)
            guard case .events(let events) = source.events(after: 2) else { return t.fail("the journal reaches back") }
            t.expectEqual(events.map(\.rowId), [MacFixtures.sid(2), MacFixtures.sid(1)], "one gone, one changed")
        },

        TestCase("Before the column is known the state says null, never an empty column") { t in
            let source = MacFixtures.source()
            t.expectNil(source.snapshot(at: MacFixtures.t0).rows, "unknown")
            source.update([], at: MacFixtures.t0)
            t.expectEqual(source.snapshot(at: MacFixtures.t0).rows, [], "known and empty")
        },

        TestCase("The Mac's rows are its own; a node's rows name the node and the Mac owns them until lampd does") { t in
            let rows = MacRows.rows([MacFixtures.snapshot(1), MacFixtures.snapshot(2, host: "example-node")], mac: MacFixtures.mac,
                                    hosts: ["example-node": .init(probedAt: MacFixtures.t0, reachable: true)])
            t.expectEqual(rows[0].source, MacFixtures.mac, "this Mac")
            t.expectEqual(rows[1].source, V1SourceIdentity(kind: .node, name: "example-node"), "the node")
            t.expectEqual(rows[1].owner, MacFixtures.mac.name, "notified by the Mac")
            t.expectEqual(rows[1].extras.hostReachable, true, "with its age")
            let owned = MacRows.rows([MacFixtures.snapshot(2, host: "example-node")], mac: MacFixtures.mac, nodesWithLampd: ["example-node"])
            t.expectEqual(owned[0].owner, "example-node", "a node with lampd owns its rows")
        },

        TestCase("A transcript only for a row the column shows") { t in
            let directory = MacFixtures.temporaryDirectory("transcript")
            let path = directory + "/t.jsonl"
            let lines = [
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Checking the build."}]},"timestamp":"2026-10-15T20:00:00Z"}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The build is green."}]},"timestamp":"2026-10-15T20:00:05Z"}"#,
            ]
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            let source = MacFixtures.source()
            source.update(MacRows.rows([MacFixtures.snapshot(1, transcript: path)], mac: MacFixtures.mac), at: MacFixtures.t0)
            let transcript = source.transcript(session: MacFixtures.sid(1), limit: 1)
            t.expectEqual(transcript?.messages.map(\.text), ["The build is green."], "the last answer")
            t.expectEqual(transcript?.notSent, 1, "and one not sent")
            t.expectNil(source.transcript(session: MacFixtures.sid(9), limit: 5), "no row, no transcript")
        },

        TestCase("A command for a row that is not there never reaches the app") { t in
            let recorder = MacFixtures.Recorder()
            let source = MacFixtures.source(recorder)
            source.update(MacRows.rows([MacFixtures.snapshot(1)], mac: MacFixtures.mac), at: MacFixtures.t0)
            let peer = V1Peer(device: "dev-1", role: .read)
            t.expectEqual(source.perform(V1Command(action: .markSeen, session: MacFixtures.sid(9)), by: peer, at: MacFixtures.t0)?.code,
                          .notFound, "refused")
            t.expectNil(source.perform(V1Command(action: .markSeen, session: MacFixtures.sid(1)), by: peer, at: MacFixtures.t0), "done")
            t.expectEqual(recorder.commands.map(\.action), [.markSeen], "only the one that could be done")
        },
    ])
}

/// The two Mac defects W3 left to 2.4, and the badge that replaced `R`.
enum MacPanelSuite {
    static let suite = TestSuite("The Mac's own Move lock and the machine's initial", [

        TestCase("The panel's Move and a phone's Move take the same lock") { t in
            let home = MacFixtures.temporaryDirectory("move")
            let session = MacFixtures.sid(5)
            t.expect(MoveLock.take(session: session, home: home), "the panel takes it")
            t.expect(!MoveLock.take(session: session, home: home), "a second Move from the panel is refused")
            // The phone's Move through the bridge: the node's script, run on this Mac.
            guard let script = RemoteMove.lockedScript(pid: 999_999, procStart: "Mon Oct 12 10:00:00 2026", session: session) else {
                return t.fail("no script")
            }
            let phone = MacProcess.run(["/usr/bin/env", "python3", "-B", "-c", script], environment: ["HOME=" + home, "PATH=/usr/bin:/bin"])
            t.expectEqual(phone.output.trimmingCharacters(in: .whitespacesAndNewlines), "locked", "the phone's Move is told: \(phone.output)")
            MoveLock.release(session: session, home: home)
            let after = MacProcess.run(["/usr/bin/env", "python3", "-B", "-c", script], environment: ["HOME=" + home, "PATH=/usr/bin:/bin"])
            t.expectEqual(after.output.trimmingCharacters(in: .whitespacesAndNewlines), "not-it", "free again: no such process, and nothing ended")
        },

        TestCase("A lock older than five minutes is taken over") { t in
            let home = MacFixtures.temporaryDirectory("move")
            let session = MacFixtures.sid(6)
            t.expect(MoveLock.take(session: session, home: home), "taken")
            t.expect(MoveLock.take(session: session, home: home, now: Date().addingTimeInterval(RemoteMove.lockLasts + 1)),
                     "a Move cut off half-way does not refuse every later one")
        },

        TestCase("A remote row's badge is its machine's initial, not R") { t in
            t.expectEqual(MachineMark.initial(host: "bestia"), "B", "a name")
            t.expectEqual(MachineMark.initial(host: "marco@build.example.com"), "B", "the account is not the machine")
            t.expectEqual(MachineMark.initial(host: "dev-box"), "D", "a dash")
            t.expectEqual(MachineMark.initial(host: "192.0.2.10"), "1", "an address")
            t.expectEqual(MachineMark.initial(host: "@"), "R", "nothing to take: R, as before")
        },
    ])
}
