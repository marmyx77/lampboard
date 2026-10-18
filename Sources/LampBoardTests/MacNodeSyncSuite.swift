import LampBoardCore
import Foundation
import TestKit

/// The Mac's side of a node with `lampd` (W5): the tunnel's port, events that
/// arrive twice, routes a node may not reach, the person's choices carried both
/// ways, the hooks left alone, an ask not held while away, the last word before
/// sleep, and what the Mac hands a phone about a node.
enum MacNodeSyncSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    static func id(_ n: Int) -> String { String(format: "40000000-0000-4000-8000-%012ld", n) }
    static let rows = [NodeRowKey(id: id(1), key: "node:/work/a"), NodeRowKey(id: id(2), key: "node:/work/b")]

    static let suite = TestSuite("Mac and node: port, forwarded events, choices both ways, away, sleep", [

        TestCase("The tunnel binds the hooks' port when free and nothing says lampd") { t in
            t.expectEqual(TunnelPort.choose(primary: 31000, primaryBound: [], secondaryBound: [], lampdInstalled: false, watch: .primary),
                          .bind(31000))
            t.expectEqual(TunnelPort.choose(primary: 31000, primaryBound: [], secondaryBound: [], lampdInstalled: true, watch: .primary),
                          .bind(31000), "lampd installed but the port free: lampd gave up, the Mac takes it")
        },

        TestCase("lampd holding the hooks' port: the tunnel goes next to it at once; a stranger there is waited for") { t in
            t.expectEqual(TunnelPort.choose(primary: 31000, primaryBound: ["127.0.0.1"], secondaryBound: [], lampdInstalled: true,
                                            watch: .primary), .bind(31001))
            t.expectEqual(TunnelPort.choose(primary: 31000, primaryBound: ["127.0.0.1"], secondaryBound: [], lampdInstalled: false,
                                            watch: .primary), .wait("port 31000 is taken there (127.0.0.1)"), "no lampd: a ghost or a stranger")
            if case .wait = TunnelPort.choose(primary: 31000, primaryBound: [], secondaryBound: ["127.0.0.1"], lampdInstalled: true,
                                              watch: .secondary) {} else { t.fail("a taken secondary port is waited for") }
            t.expectEqual(TunnelPort.choose(primary: 31000, primaryBound: [], secondaryBound: [], lampdInstalled: true, watch: .secondary),
                          .bind(31001), "the beats said healthy")
        },

        TestCase("An event lampd forwarded counts once; one without the header is always taken") { t in
            var ledger = EventLedger(capacity: 3)
            t.expectEqual(ForwardedByNode.verdict(path: AppConfig.signalPath, method: "POST", eventId: "j-1", ledger: &ledger), .take)
            t.expectEqual(ForwardedByNode.verdict(path: AppConfig.signalPath, method: "POST", eventId: "j-1", ledger: &ledger), .duplicate)
            t.expectEqual(ForwardedByNode.verdict(path: AppConfig.modPath, method: "POST", eventId: "j-2", ledger: &ledger), .take)
            t.expectEqual(ForwardedByNode.verdict(path: AppConfig.signalPath, method: "POST", eventId: nil, ledger: &ledger), .take)
            t.expectEqual(ForwardedByNode.verdict(path: AppConfig.checkPath, method: "POST", eventId: "j-9", ledger: &ledger), .take,
                          "an ask is not an event: each one is the mod's, held or answered")
            for n in 3...6 { _ = ledger.firstTime("j-\(n)") }
            t.expectEqual(ledger.count, 3, "a bounded memory")
            t.expect(ledger.firstTime("j-1"), "the oldest forgotten")
            t.expect(!EventLedger.isWellFormed("j 1\n"), "an id is a word")
        },

        TestCase("Gate «Il nodo non comanda il Mac» on the Mac: its own routes refused when lampd forwarded them") { t in
            var ledger = EventLedger()
            for path in [AppConfig.nextPath, AppConfig.openPath, AppConfig.newConversationPath, AppConfig.chatPath,
                         AppConfig.checkAnswerPath, AppConfig.lampMasterPath] {
                if case .refuse = ForwardedByNode.verdict(path: path, method: "POST", eventId: "j-1", ledger: &ledger) {} else {
                    t.fail("\(path) forwarded by a node is refused")
                }
                t.expectEqual(ForwardedByNode.verdict(path: path, method: "POST", eventId: nil, ledger: &ledger), .take,
                              "\(path) from this Mac itself is the route it always was")
            }
            if case .refuse = ForwardedByNode.verdict(path: AppConfig.checkPath, method: "GET", eventId: "x", ledger: &ledger) {} else {
                t.fail("the list of asks is the panel's")
            }
        },

        TestCase("The panel's renames, hides, mutes and reorders go to the node as commands; a new row sends nothing") { t in
            let before = NodeChoices.view(rows: rows, rowNames: [:], hidden: [], muted: [], rowOrder: ["node:/work/a", "node:/work/b"])
            let after = NodeChoices.view(rows: rows, rowNames: ["node:/work/a": "api"], hidden: ["node:/work/b"],
                                         muted: ["node:/work/a"], rowOrder: ["node:/work/b", "node:/work/a"])
            let commands = NodeChoices.commands(from: before, to: after)
            t.expect(commands.contains(V1Command(action: .rename, session: id(1), name: "api")), "rename")
            t.expect(commands.contains(V1Command(action: .hide, session: id(2), on: true)), "hide")
            t.expect(commands.contains(V1Command(action: .mute, session: id(1), on: true)), "mute")
            t.expect(commands.contains(V1Command(action: .order, ids: [id(2), id(1)])), "order")
            t.expectEqual(NodeChoices.commands(from: after, to: after), [], "nothing changed, nothing sent")
            let grown = NodeChoices.view(rows: rows + [NodeRowKey(id: id(3), key: "node:/work/c")], rowNames: ["node:/work/a": "api"],
                                         hidden: ["node:/work/b"], muted: ["node:/work/a"],
                                         rowOrder: ["node:/work/b", "node:/work/a", "node:/work/c"])
            t.expectEqual(NodeChoices.commands(from: after, to: grown), [], "a row arriving is not a change")
        },

        TestCase("The migration: the panel's choices undated, so the node's own win wherever it has them") { t in
            let panel = NodeChoices.view(rows: rows, rowNames: ["node:/work/a": "from the panel"], hidden: ["node:/work/b"],
                                         muted: [], rowOrder: [])
            var node = RowPreferences()
            node.apply(V1Command(action: .rename, session: id(1), name: "from the phone"), at: t0)
            let merged = node.merged(with: NodeChoices.migration(panel))
            t.expectEqual(merged.row(id(1)).label?.value, "from the phone", "the phone's choice is kept")
            t.expectEqual(merged.row(id(2)).hidden?.value, true, "what only the panel had comes over")
            let wire = RowPreferencesWire(NodeChoices.migration(panel))
            t.expectEqual(wire.preferences, NodeChoices.migration(panel), "undated values survive the wire")
        },

        TestCase("Read both ways: a read on the phone reads in the panel once, never a newer answer") { t in
            var node = RowPreferences()
            node.apply(V1Command(action: .markSeen, session: id(1)), at: t0 + 10)
            node.apply(V1Command(action: .markUnread, session: id(2)), at: t0 + 10)
            let ready = [NodeRowKey(id: id(1), key: "node:/work/a", readySince: t0), NodeRowKey(id: id(2), key: "node:/work/b")]
            var applied: [String: Date] = [:]
            let update = NodeChoices.panelUpdate(from: node, rows: ready, view: NodePanelView(), applied: &applied)
            t.expectEqual(update.read, [id(1)], "read on the phone after it went green")
            t.expectEqual(update.unread, [id(2)], "and marked unread")
            t.expect(NodeChoices.panelUpdate(from: node, rows: ready, view: NodePanelView(), applied: &applied).isEmpty,
                     "the same stamps once only")
            var fresh: [String: Date] = [:]
            let later = [NodeRowKey(id: id(1), key: "node:/work/a", readySince: t0 + 60)]
            t.expectEqual(NodeChoices.panelUpdate(from: node, rows: later, view: NodePanelView(), applied: &fresh).read, [],
                          "a read of an earlier answer does not put out the newer one")
        },

        TestCase("The node's names, hides and mutes change the panel; what already matches changes nothing") { t in
            var node = RowPreferences()
            node.apply(V1Command(action: .rename, session: id(1), name: "api"), at: t0)
            node.apply(V1Command(action: .rename, session: id(2), name: ""), at: t0)
            node.apply(V1Command(action: .mute, session: id(2), on: true), at: t0)
            let view = NodeChoices.view(rows: rows, rowNames: ["node:/work/b": "old"], hidden: [], muted: [], rowOrder: [])
            var applied: [String: Date] = [:]
            let update = NodeChoices.panelUpdate(from: node, rows: rows, view: view, applied: &applied)
            t.expectEqual(update.names["node:/work/a"], .some("api"))
            t.expectEqual(update.names["node:/work/b"], .some(nil), "an empty name clears the panel's")
            t.expectEqual(update.muted, ["node:/work/b": true])
        },

        TestCase("D48 with lampd on the node: the repair rewrites nothing") { t in
            let stale = HookRepair.Verdict.stale(HookRepair.Shape(includeToolEvents: false, includeMessageDelivery: false))
            t.expectEqual(HookRepair.remote(stale, lampdInstalled: false), stale, "a node of before: repaired as always")
            t.expectNil(HookRepair.remote(stale, lampdInstalled: true), "lampd adopted the token: hook.sh and token untouched")
        },

        TestCase("An ask is held for the panel only while the person is at the Mac") { t in
            t.expect(PermissionGate.holds(away: false), "at the Mac: the panel's 55 seconds")
            t.expect(!PermissionGate.holds(away: true), "away: its dialog at once, for the phone")
        },

        TestCase("The last word before sleep: only when something waits") { t in
            t.expectNil(MacSleepNote.text(waiting: 0, mac: "Example Mac"))
            t.expectEqual(MacSleepNote.text(waiting: 2, mac: "Example Mac")?.body, "The Mac is going to sleep; 2 sessions are waiting for you")
            t.expectEqual(MacSleepNote.text(waiting: 1, mac: "Example Mac")?.body, "The Mac is going to sleep; 1 session is waiting for you")
        },

        TestCase("A node handed to the phone: where the Mac's ssh goes, and only the host keys it trusts") { t in
            let resolved = MacSSHFacts.resolved("user dev\nhostname node.example.com\nport 2222\nuser other\n")
            t.expectEqual(resolved?.address, "node.example.com")
            t.expectEqual(resolved?.port, 2222)
            t.expectEqual(resolved?.user, "dev", "the first value is ssh's")
            t.expectEqual(MacSSHFacts.knownHostsName(address: "node.example.com", port: 2222), "[node.example.com]:2222")
            let key = Data(repeating: 7, count: 51).base64EncodedString()
            let found = MacSSHFacts.hostKeys("# Host node found: line 3\n|1|aGFzaA==|aGFzaA== ssh-ed25519 \(key)\n"
                + "@revoked node ssh-ed25519 \(Data(repeating: 8, count: 51).base64EncodedString())\nnode ssh-ed25519 \(key)\n")
            t.expectEqual(found, ["ssh-ed25519 \(key)"], "once, and never a revoked one")
            let old = try? JSONDecoder().decode(MacPairingReply.self, from: Data(#"{"ok":true,"device":"dev-1","mac":"Example Mac"}"#.utf8))
            t.expectEqual(old?.nodes, nil, "a Mac one version behind says no nodes")
        },
    ])
}
