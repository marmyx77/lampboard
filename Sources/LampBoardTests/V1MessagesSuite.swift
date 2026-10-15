import LampBoardCore
import Foundation
import TestKit

/// The `v1` messages as JSON: what each side writes, what each side accepts.
enum V1MessagesSuite {

    private typealias F = V1Fixtures

    private static func json(_ bytes: [UInt8]) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] ?? [:]
    }

    private static func roundTrip(_ message: V1ServerMessage) -> V1ServerMessage? {
        guard let bytes = try? V1Codec.encode(message) else { return nil }
        return try? V1Codec.decodeReply(bytes)
    }

    static let suite = TestSuite("v1 messages", [

        TestCase("Every request comes back as itself") { t in
            let requests: [V1Request] = [
                .hello(protocol: 1, client: "LampBoard iOS 1.0"),
                .state,
                .events(since: nil, journal: nil, ping: nil),
                .events(since: 41, journal: "j1", ping: 15),
                .transcript(session: F.sid(1), limit: 20),
                .command(V1Command(action: .rename, session: F.sid(1), name: "Release")),
                .command(V1Command(action: .order, ids: [F.sid(2), F.sid(1)])),
                .pushRegister(V1PushRegistration(
                    capability: "cap", token: String(repeating: "ab", count: 32), environment: .sandbox,
                    envelopeKey: Data(repeating: 7, count: 32).base64EncodedString()
                )),
                .devices(V1DevicesRequest(action: .revoke, device: "phone-2")),
            ]
            for (n, request) in requests.enumerated() {
                let bytes = (try? V1Codec.encode(V1ClientMessage(id: n, request))) ?? []
                guard case .success(let back) = V1Codec.decodeRequest(bytes) else {
                    t.expect(false, "\(request.op) did not decode"); continue
                }
                t.expectEqual(back, V1ClientMessage(id: n, request), request.op)
                t.expectEqual(json(bytes)["op"] as? String, request.op, "op of \(request.op)")
            }
        },

        TestCase("Every reply comes back as itself") { t in
            let row = F.row(1)
            let replies: [V1Reply] = [
                .hello(V1Hello(version: "2.4.0", source: F.mac, startedAt: F.t0,
                               stateAge: V1StateAge(seq: 3, lastEventAt: F.t0, lastProbeAt: nil, at: F.t0.addingTimeInterval(12)),
                               relay: V1RelayHealth(outcome: "ok", at: F.t0), role: .read)),
                .state(V1State(journal: "j1", seq: 3, source: F.mac, rows: [row], rowsAt: F.t0, at: F.t0)),
                .state(V1State(journal: "j1", seq: 0, source: F.mac, rows: nil, rowsAt: nil, at: F.t0)),
                .events(V1EventsAck(journal: "j1", since: 2, replayed: 1, resync: false, ping: 15)),
                .event(V1Event(seq: 3, at: F.t0, change: .row(row))),
                .event(V1Event(seq: 4, at: F.t0, change: .gone(id: row.id))),
                .ping(V1Ping(seq: 4, at: F.t0)),
                .transcript(V1Transcript(session: row.id, messages: [.init(role: "assistant", text: "Done.", at: F.t0)], notSent: 7)),
                .result(V1Result(op: "cmd")),
                .devices([V1Device(id: "phone-1", name: "Phone", pairedAt: F.t0, lastSeenAt: nil)]),
                .error(V1Failure(.forbidden, "no")),
                .bye(reason: "stopping"),
            ]
            for reply in replies {
                let message = V1ServerMessage(re: reply.type == "event" ? nil : 9, reply)
                t.expectEqual(roundTrip(message), message, reply.type)
            }
        },

        TestCase("A row is one flat object: the snapshot's keys, the row's, side by side") { t in
            let bytes = (try? V1Codec.encode(V1ServerMessage(re: nil, .event(V1Event(seq: 1, at: F.t0, change: .row(F.row(1))))))) ?? []
            let row = json(bytes)["row"] as? [String: Any] ?? [:]
            t.expectEqual(row["id"] as? String, F.sid(1), "the snapshot's id")
            t.expectEqual(row["workspace"] as? String, "project-1", "the snapshot's folder")
            t.expectEqual((row["source"] as? [String: Any])?["kind"] as? String, "mac", "the source")
            t.expectEqual(row["owner"] as? String, "Example Mac", "the owner defaults to the source")
            t.expectEqual(row["cacheMinutes"] as? Int, 4, "an extra")
            t.expect(row["hidden"] != nil && row["heldByMac"] != nil, "the flags are always there")
            t.expect(row["session"] == nil && row["extras"] == nil, "no nesting")
        },

        TestCase("A state that has never known its rows says null, not an empty list") { t in
            // D21: a machine that could not be read is not a machine with no sessions.
            let state = V1State(journal: "j1", seq: 0, source: F.node, rows: nil, rowsAt: nil, at: F.t0)
            let bytes = (try? V1Codec.encode(V1ServerMessage(re: nil, .state(state)))) ?? []
            let object = json(bytes)
            t.expect(object.keys.contains("rows"), "the key is written")
            t.expect(object["rows"] is NSNull, "and it is null")
        },

        TestCase("A row from a source one version behind still reads") { t in
            // Without the flags the extras did not have yet.
            var object = json((try? V1Codec.encoder().encode(F.row(1))).map(Array.init) ?? [])
            for key in ["hidden", "folded", "heldByMac", "cacheMinutes", "terminal"] { object.removeValue(forKey: key) }
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let row = try? V1Codec.decoder().decode(V1Row.self, from: data)
            t.expectEqual(row?.extras.hidden, false, "hidden")
            t.expectEqual(row?.extras.heldByMac, false, "held")
            t.expectEqual(row?.id, F.sid(1), "the row")
        },

        TestCase("Something that is not a request is malformed, an unknown op is named") { t in
            guard case .failure(let garbage) = V1Codec.decodeRequest(Array("[1,2]".utf8)) else {
                t.expect(false, "an array is not a request"); return
            }
            t.expectEqual(garbage.failure.code, .malformed, "not an object")
            guard case .failure(let unknown) = V1Codec.decodeRequest(Array(#"{"op":"shell","id":4}"#.utf8)) else {
                t.expect(false, "shell is not an op"); return
            }
            t.expectEqual(unknown.failure.code, .unknownOp, "unknown op")
            t.expectEqual(unknown.id, 4, "the refusal goes back to its request")
            guard case .failure(let bad) = V1Codec.decodeRequest(Array(#"{"op":"transcript","id":5}"#.utf8)) else {
                t.expect(false, "a transcript without a session is not one"); return
            }
            t.expectEqual(bad.failure.code, .badRequest, "a known op with the wrong fields")
            t.expect(bad.failure.message.contains("session"), "and it says which: \(bad.failure.message)")
        },

        TestCase("A command not in the list of low-power actions does not decode") { t in
            // R4: nothing a phone sends through the read key can start, stop or answer anything.
            let attempt = Array(#"{"op":"cmd","action":"allow","session":"00000000-0000-4000-8000-000000000001"}"#.utf8)
            guard case .failure(let refusal) = V1Codec.decodeRequest(attempt) else {
                t.expect(false, "allow decoded as a command"); return
            }
            t.expectEqual(refusal.failure.code, .badRequest, "refused")
        },

        TestCase("Each action says what it lacks") { t in
            t.expectNil(V1Command(action: .markSeen, session: F.sid(1)).problem, "a good one")
            t.expectNotNil(V1Command(action: .markSeen).problem, "no session")
            t.expectNotNil(V1Command(action: .markSeen, session: "../../etc").problem, "not an id")
            t.expectNotNil(V1Command(action: .rename, session: F.sid(1)).problem, "a rename with no name")
            t.expectNotNil(V1Command(action: .rename, session: F.sid(1), name: "a\u{1b}[2J").problem, "a name with a control character")
            t.expectNotNil(V1Command(action: .rename, session: F.sid(1), name: String(repeating: "n", count: 121)).problem, "too long")
            t.expectNil(V1Command(action: .rename, session: F.sid(1), name: "").problem, "empty clears the name")
            t.expectNotNil(V1Command(action: .mute, session: F.sid(1)).problem, "mute needs on")
            t.expectNil(V1Command(action: .focus).problem, "focus is about the device")
            t.expectNotNil(V1Command(action: .order, ids: ["ok", "not ok"]).problem, "an id with a space")
        },

        TestCase("A name is bounded in bytes too, and an id is never a path") { t in
            // One character can be any number of bytes: a letter under two
            // thousand accents is one character and four kilobytes.
            let heavy = "e" + String(repeating: "\u{0301}", count: 2000)
            t.expectEqual(heavy.count, 1, "one character")
            t.expect(V1Command(action: .rename, session: V1Fixtures.sid(1), name: heavy).problem != nil, "refused")
            t.expect(V1Command(action: .rename, session: V1Fixtures.sid(1), name: "Résumé ✓").problem == nil, "a real name passes")
            for id in [".", "..", ".hidden"] {
                t.expect(!V1Validation.isSessionId(id), "\(id) is not an id")
            }
            t.expect(V1Validation.isSessionId(V1Fixtures.sid(1)), "a UUID is one")
        },

        TestCase("A push registration is checked before a source keeps it") { t in
            let key = Data(repeating: 1, count: 32).base64EncodedString()
            let token = String(repeating: "0f", count: 32)
            t.expectNil(V1PushRegistration(capability: "c", token: token, environment: .production, envelopeKey: key).problem, "good")
            t.expectNotNil(V1PushRegistration(capability: "c", token: "zz", environment: .production, envelopeKey: key).problem, "token")
            t.expectNotNil(V1PushRegistration(capability: "c", token: token, environment: .production,
                                              envelopeKey: Data(repeating: 1, count: 16).base64EncodedString()).problem, "short key")
            t.expectNotNil(V1PushRegistration(capability: "", token: token, environment: .production, envelopeKey: key).problem, "no capability")
        },

        TestCase("The state's age is counted from the newer of the event and the probe") { t in
            let age = V1StateAge(seq: 1, lastEventAt: F.t0, lastProbeAt: F.t0.addingTimeInterval(20), at: F.t0.addingTimeInterval(25.04))
            t.expectEqual(age.seconds, 5.0, "five seconds after the probe")
            t.expectNil(V1StateAge(seq: 0, lastEventAt: nil, lastProbeAt: nil, at: F.t0).seconds, "nothing done yet")
        },
    ])
}
