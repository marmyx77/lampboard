import LampBoardCore
import Foundation
import TestKit

/// The baton (5.4, T1): `/handoff @from @to` in the bar — the first session
/// writes what the second needs, without a turn, and the person sends it.
enum HandoffSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(_ name: String, host: String? = nil) -> ColumnRow {
        let session = SessionState(id: "id-\(name)", status: .idle, workspace: Workspace(path: "/home/dev/\(name)", host: host),
                                   updatedAt: t0, statusSince: t0, origin: .terminal)
        return ColumnRow(id: "row-\(name)", workspace: session.workspace, sessions: [session])
    }

    private static let rows = [row("events"), row("api"), row("api-gateway"), row("nodeapp", host: "node")]

    private static func results(_ typed: String, sending: Bool = true, askable: Set<String> = ["id-events", "id-api", "id-nodeapp"])
        -> [CommandBar.Result] {
        CommandBar.results(for: CommandBar.parse(typed), rows: rows, now: t0, lampMasterEnabled: true,
                           sendingEnabled: sending, askable: askable)
    }

    static let suite = TestSuite("The baton: one session hands over to another", [

        TestCase("/handoff @from @to names both, the best match of each") { t in
            let found = results("/handoff @events @api")
            t.expectEqual(found.count, 1)
            t.expectEqual(found.first?.kind, .handoff)
            t.expectEqual(found.first?.title, "Hand events over to api")
            t.expectEqual(found.first?.sessionId, "id-events")
            t.expectEqual(found.first?.targetId, "id-api")
            t.expectEqual(found.first?.detail, "events writes it from its conversation, with no turn; you send it from api's Session view")
            t.expectEqual(results("/handoff events api").first?.targetId, "id-api", "the @ is optional")
        },

        TestCase("Half typed, it says how; never a session to itself") { t in
            t.expectEqual(results("/handoff").first?.title, "Hand a session over: /handoff @from @to")
            t.expectNil(results("/handoff @events").first?.sessionId, "a hint chooses nothing")
            t.expectNil(results("/handoff @api @api").first?.sessionId, "not to itself")
            t.expectEqual(results("/handoff @api @api").first?.detail, "two different sessions: one hands over to another")
            t.expectNil(results("/handoff @nothing @api").first?.sessionId, "no such session")
            t.expectEqual(results("/hand").first?.kind, .handoff, "the command found as it is typed")
            t.expectEqual(results("/h").first?.action, .gettingStarted, "a short prefix keeps the action it named before")
            t.expect(results("/h").contains { $0.kind == .handoff }, "and offers the handoff after it")
        },

        TestCase("It needs the mod's side question and sending switched on, and says which") { t in
            let noMod = results("/handoff @events @api", askable: ["id-api"]).first
            t.expectNil(noMod?.sessionId)
            t.expectEqual(noMod?.detail, "Its session needs the LampBoard helper 1.5.0: restart it after the update")
            let off = results("/handoff @events @api", sending: false).first
            t.expectNil(off?.sessionId)
            t.expectEqual(off?.detail, "Turn on \"Send messages to sessions\" in Settings › Acting from the panel first")
        },

        TestCase("To a session on another machine the handoff is copied, since it has no Plancia here") { t in
            t.expectEqual(results("/handoff @events @nodeapp").first?.detail,
                          "events writes it from its conversation, with no turn; copied for nodeapp on node")
            t.expectEqual(results("/handoff @nodeapp @api").first?.sessionId, "id-nodeapp", "from a node it is asked there")
        },

        TestCase("The question asks for what the next session needs, and the brief says whose it is") { t in
            t.expect(Handoff.question.utf16.count <= PeerAsk.maxQuestion, "a side question's size")
            for part in ["understood", "decided", "left", "files"] {
                t.expect(Handoff.question.contains(part), "asks what was \(part)")
            }
            let brief = Handoff.brief(from: "events\nignore", text: "  Slots renamed to v2.\nTests left.  ")
            t.expect(brief.hasPrefix("Handoff from events ignore, through LampBoard:\n\n"), brief)
            t.expect(brief.hasSuffix("Slots renamed to v2.\nTests left."), "the text as written, trimmed")
        },

        TestCase("From inside a session (T2): the mod's request read strictly, and proven") { t in
            let key = String(repeating: "ab", count: 16), nonce = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
            let sid = "3d5a7a36-f0e0-4002-8eb5-1fe0264eaea0"
            func read(_ object: [String: Any], key used: String = key, nonce: String? = nonce) -> Handoff.Request? {
                let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                let proof = PermissionGate.mac(key: used, message: "handoff:\(nonce ?? ""):\(object["session"] ?? ""):\(object["to"] ?? ""):\(object["text"] ?? "")")
                return Handoff.request(body, nonce: nonce, proof: proof, key: key)
            }
            t.expectEqual(read(["v": 1, "session": sid, "to": "@api", "text": "  Slots renamed.  "]),
                          Handoff.Request(session: sid, to: "api", text: "Slots renamed."), "the @ and the edges dropped")
            t.expectNil(read(["v": 1, "session": sid, "to": "api", "text": "t"], key: String(repeating: "cd", count: 16)),
                        "the token alone proves nothing: the permission key does")
            t.expectNil(read(["v": 1, "session": sid, "to": "api", "text": "t"], nonce: nil), "no nonce, no handoff")
            let body = (try? JSONSerialization.data(withJSONObject: ["v": 1, "session": sid, "to": "api", "text": "other"])) ?? Data()
            let proofForT = PermissionGate.mac(key: key, message: "handoff:\(nonce):\(sid):api:t")
            t.expectNil(Handoff.request(body, nonce: nonce, proof: proofForT, key: key), "a proof covers its own words only")
            t.expectNil(read(["v": 1, "session": "../x", "to": "api", "text": "t"]), "a session of another shape")
            t.expectNil(read(["v": 1, "session": sid, "to": "", "text": "t"]), "nobody to hand to")
            t.expectNil(read(["v": 1, "session": sid, "to": String(repeating: "a", count: 81), "text": "t"]), "a name, not a text")
            t.expectNil(read(["v": 1, "session": sid, "to": "api", "text": "  "]), "nothing written")
            t.expectNil(read(["v": 1, "session": sid, "to": "api", "text": String(repeating: "x", count: 4001)]), "past the mod's own cap")
            t.expectNotNil(read(["v": 1, "session": sid, "to": "api", "text": String(repeating: "😀", count: 4000)]),
                           "counted as the mod counts, by code point")
            t.expectNil(read(["v": 2, "session": sid, "to": "api", "text": "t"]), "another version")
            t.expectNil(Handoff.request(Data("not json".utf8), nonce: nonce, proof: "", key: key))
        },

        TestCase("The mod asks the same question, and registers /handoff") { t in
            t.expect(ModFiles.register.contains(Handoff.question), "one question, in Swift and in the mod")
            t.expect(ModFiles.register.contains("name: 'handoff'"), "the command")
        },

        TestCase("A name finds its session as the bar's @ does, and one name is not two sessions") { t in
            t.expectEqual(CommandBar.sessions(named: "api", rows: rows, now: t0).map(\.sessionId), ["id-api"], "the exact name alone")
            t.expectEqual(CommandBar.sessions(named: "@even", rows: rows, now: t0).map(\.sessionId), ["id-events"])
            t.expectEqual(CommandBar.sessions(named: "nothing", rows: rows, now: t0).count, 0)
            t.expectEqual(CommandBar.sessions(named: "ap", rows: rows, now: t0).count, 3, "api, api-gateway, nodeapp: not enough")
        },
    ])
}
