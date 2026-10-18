#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LampBoardCore
import LampDKit
import ProtocolConformance
import TestKit

/// What the Mac tells this machine (W5, `lampd mac-link`), what it changes, and
/// the files' last word on a yellow the hooks cannot end (D177).
enum MacLinkSuite {

    static func line(_ presence: MacPresence, at: Date) -> MacToNode { MacToNode(presence: presence, at: at) }

    /// A source with a registered phone, a session gone amber, and the Mac as told.
    static func amber(macSays presence: MacPresence?, linkSeen: Bool = true) -> (alerts: Int, paths: LampDPaths) {
        let paths = F.home("mac")
        let relay = PushSuite.FakeRelay()
        let source = PushSuite.live(paths, relay)
        _ = source.register(PushSuite.registration(), by: PushSuite.device, at: F.t0)
        if let presence { _ = MacLines.apply(line(presence, at: F.t0), paths: paths) }
        if linkSeen { source.macLinkSeen(at: F.t0 + 15) }
        PushSuite.amberLooks(source)
        return (relay.alerts().count, paths)
    }

    static let suite = TestSuite("lampd: what the Mac says, and the files' last word", [

        TestCase("The Mac at the desk: an amber of this machine does not ring the phone (Q8, no double notification)") { t in
            let here = amber(macSays: .here)
            defer { F.remove(here.paths) }
            t.expectEqual(here.alerts, 0, "the Mac's banner rings; the phone stays quiet")
        },

        TestCase("The Mac away or asleep: the same amber rings the phone") { t in
            for presence in [MacPresence.away, .asleep] {
                let away = amber(macSays: presence)
                t.expectEqual(away.alerts, 1, "\(presence.rawValue): the phone rings")
                F.remove(away.paths)
            }
            let never = amber(macSays: nil, linkSeen: false)
            t.expectEqual(never.alerts, 1, "a Mac never heard is no reason to keep quiet")
            F.remove(never.paths)
        },

        TestCase("A here with no link for a minute, or older than the stale limit, is away") { t in
            var state = MacState()
            state.take(line(.here, at: F.t0))
            t.expect(state.isHere(at: F.t0 + 30, linkSeenAt: F.t0 + 29), "fresh, with its link")
            t.expect(!state.isHere(at: F.t0 + 200, linkSeenAt: F.t0 + 100), "the link gone past its grace")
            t.expect(!state.isHere(at: F.t0 + MacNodeLink.presenceStaleAfter + 1, linkSeenAt: F.t0 + MacNodeLink.presenceStaleAfter),
                     "a here never repeated: a Mac that vanished without a word")
            t.expect(!state.isHere(at: F.t0 + 1, linkSeenAt: nil), "no link at all")
        },

        TestCase("The Mac's settings are kept across a restart and reach hello") { t in
            let paths = F.home("settings")
            defer { F.remove(paths) }
            let settings = MacNodeSettings(permissionMode: "bypass", sendMessages: true, palette: #"{"theme":"dark"}"#)
            if case .failure(let error) = MacLines.apply(MacToNode(settings: settings, at: F.t0), paths: paths) { t.fail("\(error)") }
            let source = F.source(paths)
            t.expectEqual(source.status(at: F.t0).settings, settings, "what the phone reads in hello")
            let stream = V1LoopbackStream(source: source, peer: V1Peer(device: "p", role: .read), clock: V1ManualClock(F.t0))
            let hello = try? V1Codec.encode(V1ClientMessage(id: 1, .hello(protocol: 1, client: "test")))
            try? stream.write(V1Frame.encode(hello ?? []))
            var reader = V1FrameReader()
            reader.push((try? stream.read(timeout: 1)) ?? [])
            let object = ((try? reader.next()) ?? nil).flatMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            let carried = object?["settings"] as? [String: Any]
            t.expectEqual(carried?["permissionMode"] as? String, "bypass", "hello carries them")
            t.expectEqual(carried?["sendMessages"] as? Bool, true, "Send messages too")
            t.expectEqual(V1WireContract.violations(of: object ?? [:]), [], "within the contract")
        },

        TestCase("A read from the panel is kept as a phone's would be; a focus from the Mac is refused") { t in
            let paths = F.home("cmd")
            defer { F.remove(paths) }
            let source = F.source(paths)
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle", tail: F.ended)]))
            let rename = MacToNode(command: V1Command(action: .rename, session: F.a, name: "from the panel"), at: F.t0 + 5)
            if case .failure(let error) = source.takeFromMac(rename, at: F.t0 + 5) { t.fail("\(error)") }
            t.expectEqual(source.currentRows.first?.session.label, "from the panel", "published at once")
            if case .success = MacLines.apply(MacToNode(command: V1Command(action: .focus), at: F.t0), paths: paths) {
                t.fail("a focus is a device's, never the Mac's")
            }
        },

        TestCase("The migration merges once: the phone's later rename stays, a field only the panel set comes over") { t in
            let paths = F.home("migration")
            defer { F.remove(paths) }
            try? LampDPaths.makeDirectory(paths.stateDirectory)
            _ = try? PreferencesFile(path: paths.preferencesFile).update {
                $0.apply(V1Command(action: .rename, session: F.a, name: "from the phone"), at: F.t0 + 60)
            }
            var panel = RowPreferences()
            panel.apply(V1Command(action: .rename, session: F.a, name: "from the panel"), at: F.t0)
            panel.apply(V1Command(action: .hide, session: F.a, on: true), at: F.t0)
            _ = MacLines.apply(MacToNode(migration: RowPreferencesWire(panel), at: F.t0 + 120), paths: paths)
            let merged = PreferencesFile(path: paths.preferencesFile).load().row(F.a)
            t.expectEqual(merged.label?.value, "from the phone")
            t.expectEqual(merged.hidden?.value, true)
            t.expectNotNil(MacStateFile(path: paths.macStateFile).load().migratedAt, "and the migration is remembered")
        },

        TestCase("mac-link beats «not serving» with a reason when no service answers, and sends the choices when they change") { t in
            let paths = F.home("link")
            defer { F.remove(paths) }
            var written: [String] = []
            let client = MacLinkClient(paths: paths) { written.append($0); return true }
            client.beat(at: F.t0)
            let first = written.compactMap { MacNodeLink.decode(NodeToMac.self, $0) }
            t.expectEqual(first.first?.serving, false, "nobody serving")
            t.expectEqual(first.first?.reason, "lampd is not running")
            t.expectNotNil(first.last?.preferences, "the choices once at the start")
            written = []
            client.beat(at: F.t0 + 0.3)
            t.expectEqual(written.count, 1, "unchanged choices are not sent again")
            try? LampDPaths.makeDirectory(paths.stateDirectory)
            _ = try? PreferencesFile(path: paths.preferencesFile).update { $0.apply(V1Command(action: .markSeen, session: F.a), at: F.t0) }
            written = []
            client.beat(at: F.t0 + 0.6)
            let changed = written.compactMap { MacNodeLink.decode(NodeToMac.self, $0) }.compactMap(\.preferences).first
            t.expectNotNil(changed?.preferences.row(F.a).readAt, "a read on the phone reaches the panel")
            // A line while the service is down: kept on the files.
            client.take(MacNodeLink.encode(line(.away, at: F.t0))!)
            t.expectEqual(MacStateFile(path: paths.macStateFile).load().presence, .away, "kept for the service's next start")
        },

        TestCase("LAMPD_HOOK_PORT is taken in a check's home only (the fake node isolated)") { t in
            let real = LampDPaths(home: "/srv/elsewhere", stateDirectory: "/tmp/x", configDirectory: "/tmp/x", runtimeDirectory: "/tmp/x")
            if case .success = HookPortOverride.port(environment: ["LAMPD_HOOK_PORT": "31000", "HOME": "/srv/elsewhere"], paths: real) {
                t.fail("a real home's port taken by a check")
            }
            let check = F.home("override")
            defer { F.remove(check) }
            if case .success(let port) = HookPortOverride.port(environment: ["LAMPD_HOOK_PORT": "41000", "LAMPBOARD_HOME": check.home], paths: check) {
                t.expectEqual(port, 41000)
            } else { t.fail("refused in a check's home") }
        },

        // MARK: D177 on this machine

        TestCase("A yellow the hooks cannot end rests when the file has said idle for a minute (idle compaction)") { t in
            let hooks = NodeHooks()
            let start = F.t0
            hooks.signal(HookSignal(sessionId: F.a, event: .userPromptSubmit, cwd: "/home/dev/project", entrypoint: "cli"), at: start)
            t.expectEqual(hooks.overlaid([MacLinkSuite.fileRow()], at: start + 200).first?.session.status, SessionStatus.working.rawValue,
                          "yellow from the hooks before the files speak")
            // The turn's Stop never came (a compaction took the turn guard): only the file can say it is over.
            let idle = MacLinkSuite.liveIdle(since: start + 120)
            hooks.reconcile(with: [idle], at: start + 200)
            let row = hooks.overlaid([MacLinkSuite.fileRow()], at: start + 200).first
            t.expectEqual(row?.session.status, SessionStatus.idle.rawValue, "at rest, as the Mac rests it (D177)")
        },

        TestCase("The idle compaction's hook rests a row the file lit, and is not green") { t in
            let hooks = NodeHooks()
            let start = F.t0
            hooks.signal(HookSignal(sessionId: F.a, event: .userPromptSubmit, cwd: "/home/dev/project", entrypoint: "cli"), at: start)
            hooks.signal(HookSignal(sessionId: F.a, event: .stop, cwd: "/home/dev/project", entrypoint: "cli"), at: start + 10)
            hooks.markSeen(F.a, at: start + 20)
            hooks.reconcile(with: [MacLinkSuite.liveBusy()], at: start + 3000)
            t.expectEqual(hooks.overlaid([fileRow()], at: start + 3000).first?.session.status, SessionStatus.working.rawValue,
                          "the file's busy lights it (D141)")
            hooks.signal(HookSignal(sessionId: F.a, event: .sessionStart, cwd: "/home/dev/project", entrypoint: "cli", sessionSource: "compact"),
                         at: start + 3060)
            t.expectEqual(hooks.overlaid([fileRow()], at: start + 3060).first?.session.status, SessionStatus.idle.rawValue,
                          "the compaction ends: at rest, no new answer")
        },
    ])

    static func fileRow() -> V1Row {
        let session = SessionSnapshot(id: F.a, status: "idle", workspace: "project", path: "/home/dev/project",
                                      updatedAt: F.t0, statusSince: F.t0, entrypoint: "cli", origin: "terminal")
        return V1Row(session: session, source: F.node, extras: V1RowExtras(stateBasis: .sessionFile))
    }

    static func live(_ record: [String: Any]) -> LiveSession {
        F.reading([record]).report.sessions[0]
    }

    static func liveIdle(since: Date) -> LiveSession {
        var record = F.record(F.a, pid: 10, status: "idle", tail: F.ended)
        record["statusUpdatedAt"] = since.timeIntervalSince1970 * 1000
        return live(record)
    }

    static func liveBusy() -> LiveSession { live(F.record(F.a, pid: 10, status: "busy")) }
}
