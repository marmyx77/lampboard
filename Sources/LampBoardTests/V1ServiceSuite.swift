import LampBoardCore
import Foundation
import TestKit

/// The source's side of a connection, over the reference source: the rules
/// `lampd` and the Mac keep because they run this code, not because each
/// remembered to.
enum V1ServiceSuite {

    private typealias F = V1Fixtures

    private static func events(_ bytes: [UInt8]) -> [V1Event] {
        F.replies(bytes).compactMap { if case .event(let event) = $0.reply { return event }; return nil }
    }

    private static func ack(_ bytes: [UInt8]) -> V1EventsAck? {
        for message in F.replies(bytes) { if case .events(let ack) = message.reply { return ack } }
        return nil
    }

    static let suite = TestSuite("v1 service", [

        TestCase("Hello first: anything before it is refused, and the connection stays") { t in
            var service = V1Service(source: F.source(), peer: F.reader)
            t.expectEqual(F.failure(service.receive(F.frame(.state, id: 1), at: F.t0))?.code, .helloFirst, "state before hello")
            let hello = F.replies(service.receive(F.hello(id: 2), at: F.t0))
            guard case .hello(let answer)? = hello.first?.reply else { t.expect(false, "no hello"); return }
            t.expectEqual(hello.first?.re, 2, "the answer names its request")
            t.expectEqual(answer.protocol, V1Protocol.version, "protocol")
            t.expectEqual(answer.source, F.mac, "who")
            t.expectEqual(answer.stateAge.seq, 2, "two rows, two events")
            t.expectEqual(answer.role, .read, "what the key may do, as the transport said")
        },

        TestCase("Hello says how old the state is") { t in
            let source = F.source()
            source.probed(at: F.t0.addingTimeInterval(30))
            var service = V1Service(source: source, peer: F.reader)
            guard case .hello(let hello)? = F.replies(service.receive(F.hello(), at: F.t0.addingTimeInterval(42))).first?.reply else {
                t.expect(false, "no hello"); return
            }
            t.expectEqual(hello.stateAge.seconds, 12, "twelve seconds since the probe")
            t.expectEqual(hello.stateAge.lastEventAt, F.t0, "the last event")
        },

        TestCase("A client older than minClient is told so and the connection ends") { t in
            var service = V1Service(source: F.source(), peer: F.reader)
            let out = service.receive(F.frame(.hello(protocol: 0, client: "old"), id: 1), at: F.t0)
            t.expectEqual(F.failure(out)?.code, .clientTooOld, "refused")
            t.expect(service.isClosed, "closed")
            t.expectEqual(service.receive(F.frame(.state), at: F.t0), [], "and silent after")
        },

        TestCase("A client holding nothing gets the state, then the live events") { t in
            let source = F.source()
            var service = F.greeted(source)
            let out = service.receive(F.frame(.events(since: nil, journal: nil, ping: 15), id: 3), at: F.t0)
            t.expectEqual(F.types(out), ["events", "state"], "acknowledged, then the state")
            t.expectEqual(ack(out)?.resync, true, "a resync")
            source.upsert(F.row(3), at: F.t0)
            let live = events(service.poll(at: F.t0))
            t.expectEqual(live.map(\.seq), [3], "the next event, numbered after the state")
        },

        TestCase("A client holding events gets exactly the ones after them, in order") { t in
            let source = F.source(rows: 5)
            var service = F.greeted(source)
            let out = service.receive(F.frame(.events(since: 2, journal: "j1", ping: nil)), at: F.t0)
            t.expectEqual(ack(out)?.replayed, 3, "three to replay")
            t.expectEqual(ack(out)?.resync, false, "no state")
            t.expectEqual(events(out).map(\.seq), [3, 4, 5], "3, 4, 5")
            t.expectEqual(events(service.poll(at: F.t0)), [], "nothing twice")
        },

        TestCase("Numbers from another journal are answered with a whole state") { t in
            // The source restarted and kept nothing: seq 2 there is not seq 2 here.
            var service = F.greeted(F.source(rows: 3, journal: "after-restart"))
            let out = service.receive(F.frame(.events(since: 2, journal: "before-restart", ping: nil)), at: F.t0)
            t.expectEqual(F.types(out), ["events", "state"], "a resync")
        },

        TestCase("Numbers the journal no longer reaches are answered with a whole state") { t in
            var service = F.greeted(F.source(rows: 10, retention: 3))
            let out = service.receive(F.frame(.events(since: 2, journal: "j1", ping: nil)), at: F.t0)
            t.expectEqual(ack(out)?.resync, true, "the journal starts at 8")
            t.expectEqual(F.types(out), ["events", "state"], "the state instead")
        },

        TestCase("Numbers from the future are not trusted") { t in
            var service = F.greeted(F.source(rows: 2))
            t.expectEqual(ack(service.receive(F.frame(.events(since: 9, journal: "j1", ping: nil)), at: F.t0))?.resync, true, "resync")
        },

        TestCase("A ping every interval, carrying the last number sent") { t in
            let source = F.source()
            var service = F.greeted(source)
            _ = service.receive(F.frame(.events(since: 2, journal: "j1", ping: 15)), at: F.t0)
            t.expectEqual(service.poll(at: F.t0.addingTimeInterval(14.9)), [], "not yet")
            let ping = F.replies(service.poll(at: F.t0.addingTimeInterval(15)))
            guard case .ping(let first)? = ping.first?.reply else { t.expect(false, "no ping at 15 s"); return }
            t.expectEqual(first.seq, 2, "the last number")
            t.expectEqual(service.poll(at: F.t0.addingTimeInterval(20)), [], "and not again before the next interval")
        },

        TestCase("The ping interval a client asks for is kept inside its range") { t in
            var service = F.greeted(F.source())
            t.expectEqual(ack(service.receive(F.frame(.events(since: nil, journal: nil, ping: 0.001)), at: F.t0))?.ping,
                          V1Protocol.pingRange.lowerBound, "no busy loop")
            t.expectEqual(ack(service.receive(F.frame(.events(since: nil, journal: nil, ping: 3600)), at: F.t0))?.ping,
                          V1Protocol.pingRange.upperBound, "no hour-long silence")
        },

        TestCase("A journal trimmed under a slow client sends the state again") { t in
            let source = F.source(rows: 1, retention: 2)
            var service = F.greeted(source)
            _ = service.receive(F.frame(.events(since: 1, journal: "j1", ping: nil)), at: F.t0)
            for n in 2...6 { source.upsert(F.row(n), at: F.t0) }
            t.expectEqual(F.types(service.poll(at: F.t0)), ["state"], "four events were lost to the trim")
        },

        TestCase("A command is validated before the source sees it") { t in
            let source = F.source()
            var service = F.greeted(source)
            let out = service.receive(F.frame(.command(V1Command(action: .rename, session: F.sid(1))), id: 7), at: F.t0)
            t.expectEqual(F.failure(out)?.code, .badRequest, "a rename with no name")
            t.expectEqual(source.performed.count, 0, "never reached the source")
            let ok = F.replies(service.receive(F.frame(.command(V1Command(action: .markSeen, session: F.sid(1))), id: 8), at: F.t0))
            t.expectEqual(ok.first?.reply, .result(V1Result(op: "cmd")), "done")
            t.expectEqual(ok.first?.re, 8, "answering 8")
            t.expectEqual(source.row(F.sid(1))?.extras.readAt, F.t0, "and read")
        },

        TestCase("A command for a row that is not there is not found") { t in
            var service = F.greeted(F.source())
            t.expectEqual(F.failure(service.receive(F.frame(.command(V1Command(action: .hide, session: F.sid(99), on: true))), at: F.t0))?.code,
                          .notFound, "no row 99")
        },

        TestCase("The devices need the action key") { t in
            let device = V1Device(id: "phone-2", name: "Old phone", pairedAt: F.t0, lastSeenAt: nil)
            let source = V1MemorySource(identity: F.mac, startedAt: F.t0, journal: "j1", devices: [device])
            var reader = F.greeted(source, peer: F.reader)
            t.expectEqual(F.failure(reader.receive(F.frame(.devices(V1DevicesRequest(action: .list))), at: F.t0))?.code,
                          .forbidden, "the read key")
            var actor = F.greeted(source, peer: F.actor)
            t.expectEqual(F.replies(actor.receive(F.frame(.devices(V1DevicesRequest(action: .list))), at: F.t0)).first?.reply,
                          .devices([device]), "the action key")
            t.expectEqual(F.replies(actor.receive(F.frame(.devices(V1DevicesRequest(action: .revoke, device: "phone-2"))), at: F.t0)).first?.reply,
                          .devices([]), "revoked")
        },

        TestCase("A transcript says how much it left out, and a bad id is refused") { t in
            let source = F.source()
            source.setTranscript(session: F.sid(1), messages: (1...30).map { .init(role: "assistant", text: "answer \($0)", at: nil) })
            var service = F.greeted(source)
            let out = F.replies(service.receive(F.frame(.transcript(session: F.sid(1), limit: 10)), at: F.t0))
            guard case .transcript(let transcript)? = out.first?.reply else { t.expect(false, "no transcript"); return }
            t.expectEqual(transcript.messages.count, 10, "the last ten")
            t.expectEqual(transcript.messages.last?.text, "answer 30", "the newest last")
            t.expectEqual(transcript.notSent, 20, "and twenty not sent")
            t.expectEqual(F.failure(service.receive(F.frame(.transcript(session: "../x", limit: nil)), at: F.t0))?.code, .badRequest, "a path")
            t.expectEqual(F.failure(service.receive(F.frame(.transcript(session: F.sid(2), limit: nil)), at: F.t0))?.code, .notFound, "none")
        },

        TestCase("A transcript never carries more than was asked, whatever the source hands over") { t in
            let source = OverGenerous(F.source())
            var service = F.greeted(source)
            let out = F.replies(service.receive(F.frame(.transcript(session: F.sid(1), limit: 5)), at: F.t0))
            guard case .transcript(let transcript)? = out.first?.reply else { t.expect(false, "no transcript"); return }
            t.expectEqual(transcript.messages.count, 5, "five, as asked")
            t.expectEqual(transcript.messages.last?.text, "answer 40", "the newest kept")
            t.expectEqual(transcript.notSent, 35, "and the rest counted as not sent")
        },

        TestCase("An unknown op is refused and the connection goes on") { t in
            var service = F.greeted(F.source())
            let out = service.receive(Array(V1Frame.encode(Array(#"{"op":"exec","id":5,"command":"ls"}"#.utf8))), at: F.t0)
            t.expectEqual(F.failure(out)?.code, .unknownOp, "refused")
            t.expectEqual(F.replies(out).first?.re, 5, "answering it")
            t.expectEqual(F.types(service.receive(F.frame(.state), at: F.t0)), ["state"], "still answering")
        },

        TestCase("Bytes out of step end the connection with a reason") { t in
            var service = F.greeted(F.source())
            let out = service.receive(Array("GET / HTTP/1.1\r\n".utf8), at: F.t0)
            t.expectEqual(F.failure(out)?.code, .badFrame, "said why")
            t.expect(service.isClosed, "and closed")
        },

        TestCase("An orderly stop says goodbye once, then nothing") { t in
            var service = F.greeted(F.source())
            _ = service.receive(F.frame(.events(since: nil, journal: nil, ping: 1)), at: F.t0)
            t.expectEqual(F.types(service.close(reason: "stopping")), ["bye"], "goodbye")
            t.expectEqual(service.close(reason: "again"), [], "once")
            t.expectEqual(service.poll(at: F.t0.addingTimeInterval(60)), [], "no ping after")
        },

        TestCase("Several requests in one write are answered in order") { t in
            var service = V1Service(source: F.source(), peer: F.reader)
            let out = F.replies(service.receive(F.hello(id: 1) + F.frame(.state, id: 2) + F.frame(.state, id: 3), at: F.t0))
            t.expectEqual(out.map(\.re), [1, 2, 3], "1, 2, 3")
        },
    ])
}

/// A source that ignores the limit it is given: forty messages, whatever is asked.
private final class OverGenerous: V1Source {
    let inner: V1MemorySource
    init(_ inner: V1MemorySource) { self.inner = inner }
    var identity: V1SourceIdentity { inner.identity }
    func status(at now: Date) -> V1SourceStatus { inner.status(at: now) }
    func snapshot(at now: Date) -> V1State { inner.snapshot(at: now) }
    func events(after seq: Int) -> V1Replay { inner.events(after: seq) }
    func transcript(session: String, limit: Int) -> V1Transcript? {
        V1Transcript(session: session, messages: (1...40).map { .init(role: "assistant", text: "answer \($0)", at: nil) }, notSent: 0)
    }
    func perform(_ command: V1Command, by peer: V1Peer, at now: Date) -> V1Failure? { inner.perform(command, by: peer, at: now) }
    func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> V1Failure? {
        inner.register(registration, by: peer, at: now)
    }
    func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure> {
        inner.devices(request, by: peer, at: now)
    }
}
