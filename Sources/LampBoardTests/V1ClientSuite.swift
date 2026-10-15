import LampBoardCore
import Foundation
import TestKit

/// The phone's side: what it holds, when it says that is old, and how it comes
/// back without a hole or a double (S-H v2, E13 of W0).
enum V1ClientSuite {

    private typealias F = V1Fixtures

    /// A client and a service joined by hand: what one writes the other reads,
    /// unless the test cuts the wire.
    private struct Pair {
        let source: V1MemorySource
        var service: V1Service
        var client: V1Client
        var connection = 0
        var now = F.t0

        init(source: V1MemorySource, ping: TimeInterval = 15) {
            self.source = source
            service = V1Service(source: source, peer: F.reader)
            client = V1Client(name: "test", pingInterval: ping, at: F.t0)
        }

        @discardableResult
        mutating func connect() -> [V1Client.Event] {
            service = V1Service(source: source, peer: F.reader)
            let (id, bytes) = client.connect(at: now)
            connection = id
            return client.receive(service.receive(bytes, at: now), on: id, at: now)
        }

        @discardableResult
        mutating func pump() -> [V1Client.Event] {
            client.receive(service.poll(at: now), on: connection, at: now)
        }
    }

    private static func reconnects(_ events: [V1Client.Event]) -> Bool {
        events.contains { if case .reconnect = $0 { return true }; return false }
    }

    static let suite = TestSuite("v1 client", [

        TestCase("A first connection gets every row, then the changes") { t in
            var pair = Pair(source: F.source(rows: 3))
            pair.connect()
            t.expectEqual(pair.client.rows.map(\.id), [F.sid(1), F.sid(2), F.sid(3)], "the rows")
            t.expectEqual(pair.client.lastSeq, 3, "at 3")
            pair.source.upsert(F.row(2, status: "ready"), at: F.t0)
            pair.source.remove(id: F.sid(1), at: F.t0)
            pair.pump()
            t.expectEqual(pair.client.rows.map(\.id), [F.sid(2), F.sid(3)], "one gone")
            t.expectEqual(pair.client.rows.first?.session.status, "ready", "one changed")
            t.expectEqual(pair.client.lastSeq, 5, "at 5")
        },

        TestCase("One lost ping lights nothing, two do (2 × interval + 5 s)") { t in
            // Measured in S-H v2: one ping lost leaves exactly 30.00 s of silence at
            // a 15 s interval, and a threshold of 2 × interval raised a false alarm.
            var pair = Pair(source: F.source())
            pair.connect()
            t.expectEqual(pair.client.staleAfter, 35, "35 s")
            t.expectEqual(pair.client.tick(at: F.t0.addingTimeInterval(30)), [], "30 s: one ping lost")
            t.expect(!pair.client.isStale, "not old")
            let events = pair.client.tick(at: F.t0.addingTimeInterval(35.1))
            guard case .stale(let silence)? = events.first else { t.expect(false, "35.1 s: not declared old"); return }
            t.expect(abs(silence - 35.1) < 0.01, "35.1 s of silence, said \(silence)")
            t.expect(reconnects(events), "and it starts again")
            t.expect(pair.client.isStale, "and says so")
        },

        TestCase("Pings held back by a suspension are not used") { t in
            // The kernel hands over, all at once, pings up to 45.7 s late (S-H v2).
            var pair = Pair(source: F.source())
            pair.connect()
            pair.source.upsert(F.row(9), at: F.t0)
            let late = pair.service.poll(at: F.t0.addingTimeInterval(1))
            let events = pair.client.receive(late, on: pair.connection, at: F.t0.addingTimeInterval(46))
            t.expect(events.contains(.stale(silence: 46)), "declared old first")
            t.expect(reconnects(events), "and dropped")
            t.expect(!pair.client.rows.contains { $0.id == F.sid(9) }, "the late event was not used")
        },

        TestCase("Bytes on a dropped connection are thrown away, never counted twice") { t in
            var pair = Pair(source: F.source())
            pair.connect()
            let old = pair.connection
            pair.source.upsert(F.row(5), at: F.t0)
            let inFlight = pair.service.poll(at: F.t0)
            pair.now = F.t0.addingTimeInterval(1)
            pair.connect()
            t.expectEqual(pair.client.lastSeq, 3, "the new connection replayed event 3")
            t.expectEqual(pair.client.receive(inFlight, on: old, at: pair.now), [], "the old one's bytes: nothing")
            t.expectEqual(pair.client.rows.filter { $0.id == F.sid(5) }.count, 1, "one row 5")
        },

        TestCase("Coming back asks for what came after, and gets exactly that") { t in
            var pair = Pair(source: F.source(rows: 2))
            pair.connect()
            // The network goes; the source goes on.
            for n in 3...12 { pair.source.upsert(F.row(n), at: F.t0) }
            pair.now = F.t0.addingTimeInterval(40)
            t.expect(reconnects(pair.client.tick(at: pair.now)), "noticed")
            let (id, bytes) = pair.client.connect(at: pair.now)
            let request = F.replies(bytes)
            t.expect(request.isEmpty, "the client writes requests, not replies")
            pair.service = V1Service(source: pair.source, peer: F.reader)
            let out = pair.service.receive(bytes, at: pair.now)
            let types = F.types(out)
            t.expectEqual(types.filter { $0 == "event" }.count, 10, "ten replayed")
            t.expect(!types.contains("state"), "no state: the journal reaches")
            _ = pair.client.receive(out, on: id, at: pair.now)
            t.expectEqual(pair.client.lastSeq, 12, "at 12")
            t.expectEqual(pair.client.rows.count, 12, "every row once")
            t.expect(!pair.client.isStale, "fresh again")
        },

        TestCase("A hole in the numbers starts the connection again") { t in
            var pair = Pair(source: F.source(rows: 2))
            pair.connect()
            let skipped = V1ServerMessage(re: nil, .event(V1Event(seq: 4, at: F.t0, change: .row(F.row(4)))))
            let bytes = V1Frame.encode((try? V1Codec.encode(skipped)) ?? [])
            let events = pair.client.receive(bytes, on: pair.connection, at: F.t0)
            t.expect(reconnects(events), "3 never came")
            t.expectEqual(pair.client.lastSeq, 2, "nothing past the hole was taken")
        },

        TestCase("A ping ahead of what the client holds is a hole too") { t in
            var pair = Pair(source: F.source(rows: 2))
            pair.connect()
            let ping = V1Frame.encode((try? V1Codec.encode(V1ServerMessage(re: nil, .ping(V1Ping(seq: 5, at: F.t0))))) ?? [])
            t.expect(reconnects(pair.client.receive(ping, on: pair.connection, at: F.t0)), "the source is at 5")
        },

        TestCase("A replay that overlaps what is held is not applied twice") { t in
            var pair = Pair(source: F.source(rows: 3))
            pair.connect()
            let again = V1ServerMessage(re: nil, .event(V1Event(seq: 2, at: F.t0, change: .gone(id: F.sid(2)))))
            _ = pair.client.receive(V1Frame.encode((try? V1Codec.encode(again)) ?? []), on: pair.connection, at: F.t0)
            t.expectEqual(pair.client.rows.count, 3, "event 2 is already held")
        },

        TestCase("A source that needs a newer app says so") { t in
            var client = V1Client(name: "test", at: F.t0)
            let (id, _) = client.connect(at: F.t0)
            let hello = V1Hello(protocol: 3, minClient: 2, version: "9", source: F.mac, startedAt: F.t0,
                                stateAge: V1StateAge(seq: 0, lastEventAt: nil, lastProbeAt: nil, at: F.t0), role: .read)
            let bytes = V1Frame.encode((try? V1Codec.encode(V1ServerMessage(re: 1, .hello(hello)))) ?? [])
            let events = client.receive(bytes, on: id, at: F.t0)
            t.expect(events.contains { if case .incompatible = $0 { return true }; return false }, "incompatible")
        },

        TestCase("A reply of a kind this app does not know is passed over, not a reason to start again") { t in
            // A source one version ahead may say more. An app that drops the
            // connection on what it cannot read reconnects, is told the same
            // thing, and reconnects again, for as long as it is not updated.
            var pair = Pair(source: F.source(rows: 2))
            pair.connect()
            let newer = V1Frame.encode(Array(#"{"type":"presence","at":"2025-10-09T08:53:20Z"}"#.utf8))
            t.expectEqual(pair.client.receive(newer, on: pair.connection, at: F.t0), [], "nothing to do")
            pair.source.upsert(F.row(7), at: F.t0)
            pair.pump()
            t.expectEqual(pair.client.lastSeq, 3, "and the stream goes on")
        },

        TestCase("An event of a kind this app does not know keeps the count") { t in
            var pair = Pair(source: F.source(rows: 2))
            pair.connect()
            let newer = V1Frame.encode(Array(#"{"type":"event","seq":3,"at":"2025-10-09T08:53:20Z","kind":"moved","id":"x"}"#.utf8))
            let events = pair.client.receive(newer, on: pair.connection, at: F.t0)
            t.expect(!reconnects(events), "no reconnection")
            t.expectEqual(pair.client.lastSeq, 3, "the number is held")
            let next = V1ServerMessage(re: nil, .event(V1Event(seq: 4, at: F.t0, change: .row(F.row(4)))))
            _ = pair.client.receive(V1Frame.encode((try? V1Codec.encode(next)) ?? []), on: pair.connection, at: F.t0)
            t.expectEqual(pair.client.lastSeq, 4, "so the next one is no hole")
        },

        TestCase("A refusal with a code this app does not know is still a refusal") { t in
            var pair = Pair(source: F.source(rows: 1))
            pair.connect()
            let newer = V1Frame.encode(Array(#"{"type":"error","re":9,"code":"slowDown","message":"too many requests"}"#.utf8))
            let events = pair.client.receive(newer, on: pair.connection, at: F.t0)
            t.expectEqual(events, [.refused(re: 9, V1Failure(.unavailable, "too many requests"))], "refused, with its words")
        },

        TestCase("A reply of a known kind that does not read is still out of step") { t in
            var pair = Pair(source: F.source(rows: 1))
            pair.connect()
            let broken = V1Frame.encode(Array(#"{"type":"event","seq":"two"}"#.utf8))
            t.expect(reconnects(pair.client.receive(broken, on: pair.connection, at: F.t0)), "dropped")
        },

        TestCase("A source that has never known its rows is not an empty column") { t in
            let source = V1MemorySource(identity: F.node, startedAt: F.t0, journal: "j", known: false)
            var pair = Pair(source: source)
            pair.connect()
            t.expect(!pair.client.rowsKnown, "unknown")
            t.expectEqual(pair.client.rows, [], "no rows to show")
        },

        TestCase("A thousand events, cut three times, arrive with no hole and no double") { t in
            // S-R's run in miniature: 1000 events, the wire cut in the middle of
            // three bursts, every cut noticed by the client's own clock.
            var pair = Pair(source: F.source(rows: 1), ping: 1)
            pair.connect()
            var cuts = 0
            for n in 2...1000 {
                pair.source.upsert(F.row(n % 50 + 1, status: n % 2 == 0 ? "working" : "ready"), at: F.t0)
                if n % 300 == 0 {
                    // Cut: nothing more reaches the client until its threshold.
                    pair.now = pair.now.addingTimeInterval(pair.client.staleAfter + 1)
                    if reconnects(pair.client.tick(at: pair.now)) { cuts += 1; pair.connect() }
                } else if n % 7 == 0 {
                    pair.now = pair.now.addingTimeInterval(0.5)
                    pair.pump()
                }
            }
            pair.pump()
            t.expectEqual(cuts, 3, "three cuts noticed")
            t.expectEqual(pair.client.lastSeq, pair.source.status(at: pair.now).seq, "every event")
            let expected = pair.source.snapshot(at: pair.now).rows?.map(\.id).sorted()
            t.expectEqual(pair.client.rows.map(\.id).sorted(), expected ?? [], "the same rows as the source")
            t.expectEqual(Set(pair.client.rows.map(\.id)).count, pair.client.rows.count, "none twice")
        },
    ])
}
